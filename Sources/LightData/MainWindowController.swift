import AppKit

final class DataCellTextField: NSTextField {
    var documentRow = 0
    var columnIndex = 0
    var rawValue = ""
}

final class DataCellButton: NSButton {
    var documentRow = 0
    var columnIndex = 0
    var rawValue = ""
}

final class DataCellPopupButton: NSPopUpButton {
    var documentRow = 0
    var columnIndex = 0
}

final class ColumnTypeMenuItem: NSMenuItem {
    var columnIndex = 0
    var columnType = ColumnType.text
}

final class ColumnMenuItem: NSMenuItem {
    var columnIndex = 0
}

final class DropView: NSView {
    weak var dropHandler: MainWindowController?

    override func draggingEntered(_ sender: NSDraggingInfo) -> NSDragOperation {
        dropHandler?.draggingEntered(sender) ?? []
    }

    override func performDragOperation(_ sender: NSDraggingInfo) -> Bool {
        dropHandler?.performDragOperation(sender) ?? false
    }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        needsDisplay = true
        dropHandler?.appearanceDidChange()
    }
}

final class DataTableHeaderView: NSTableHeaderView {
    weak var columnActionHandler: MainWindowController?

    override func menu(for event: NSEvent) -> NSMenu? {
        let point = convert(event.locationInWindow, from: nil)
        let column = column(at: point)
        columnActionHandler?.setContextColumnFromVisibleColumn(column)
        return columnActionHandler?.buildHeaderContextMenu(forVisibleColumn: column)
    }
}

final class MainWindowController: NSWindowController, NSTableViewDataSource, NSTableViewDelegate, NSTextFieldDelegate, NSSearchFieldDelegate, NSWindowDelegate, NSToolbarDelegate, NSDraggingDestination, NSMenuDelegate {
    private var tableDocument: TableDocument?
    private var visibleRows: [Int] = []
    private var activeFilter: TableFilter?
    private var metadata = ViewMetadata()
    private var schema = TableSchema()
    private var editLocked = true

    private let rootView = DropView()
    private let tableView = NSTableView()
    private let scrollView = NSScrollView()
    private let searchField = NSSearchField()
    private let statusLabel = NSTextField(labelWithString: "")
    private let statusBadge = NSVisualEffectView()
    private let fileLabel = NSTextField(labelWithString: "No file")
    private let columnPopup = NSPopUpButton()
    private let operatorPopup = NSPopUpButton()
    private let filterValueField = NSTextField()
    private let delimiterPopup = NSPopUpButton()
    private let saveButton = NSButton(title: "Save", target: nil, action: nil)
    private weak var editModeItem: NSToolbarItem?
    private weak var addRowItem: NSToolbarItem?
    private weak var deleteRowItem: NSToolbarItem?
    private weak var typeModeItem: NSToolbarItem?
    private weak var filterItem: NSToolbarItem?
    private var filterPanelVisible = false
    private var filterBar: NSView?
    private var contextColumnIndex: Int?
    private var didBuildInterface = false
    private var appearanceObservation: NSKeyValueObservation?

    convenience init() {
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 1180, height: 760),
            styleMask: [.titled, .closable, .miniaturizable, .resizable],
            backing: .buffered,
            defer: false
        )
        window.title = "LightData"
        window.minSize = NSSize(width: 860, height: 520)
        self.init(window: window)
        configureWindow()
        window.center()
    }

    override func windowDidLoad() {
        super.windowDidLoad()
        configureWindow()
    }

    func open(url: URL) {
        do {
            saveCurrentMetadata()
            let loaded = try TableDocument.load(url: url)
            tableDocument = loaded
            editLocked = true
            metadata = ViewMetadataStore.load(for: url)
            schema = metadata.schemaEnabled ? SchemaMetadataStore.load(for: url, headers: loaded.headers, rows: loaded.rows) : TableSchema()
            activeFilter = nil
            searchField.stringValue = ""
            filterValueField.stringValue = ""
            buildColumns()
            refreshFilterControls()
            refreshDelimiterControl()
            rebuildVisibleRows()
            updateStatus()
            updateToolbarState()
            window?.title = "LightData - \(url.lastPathComponent)"
        } catch {
            showError(error)
        }
    }

    func saveDocument() {
        guard var current = tableDocument else { return }
        do {
            try current.save()
            tableDocument = current
            saveCurrentMetadata()
            saveCurrentSchema()
            updateStatus()
            updateToolbarState()
        } catch {
            showError(error)
        }
    }

    func numberOfRows(in tableView: NSTableView) -> Int {
        visibleRows.count
    }

    func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
        guard let tableColumn,
              let tableDocument,
              visibleRows.indices.contains(row) else {
            return nil
        }

        if tableColumn.identifier.rawValue == "rowNumber" {
            let id = NSUserInterfaceItemIdentifier("RowNumberCell")
            let cell = tableView.makeView(withIdentifier: id, owner: self) as? NSTableCellView ?? makeCellView(identifier: id)
            cell.textField?.stringValue = String(visibleRows[row] + 1)
            cell.textField?.isEditable = false
            cell.textField?.textColor = .secondaryLabelColor
            return cell
        }

        guard let columnIndex = Int(tableColumn.identifier.rawValue) else {
            return nil
        }

        let documentRow = visibleRows[row]
        let value = columnIndex < tableDocument.rows[documentRow].count ? tableDocument.rows[documentRow][columnIndex] : ""
        let columnSchema = metadata.schemaEnabled ? schema.schema(for: tableDocument.headers[columnIndex]) : ColumnSchema(type: .text)

        switch columnSchema.type {
        case .checkbox:
            return checkboxCell(value: value, schema: columnSchema, documentRow: documentRow, columnIndex: columnIndex)
        case .select, .status:
            return popupCell(value: value, schema: columnSchema, documentRow: documentRow, columnIndex: columnIndex)
        case .multiSelect:
            return multiSelectCell(value: value, schema: columnSchema, documentRow: documentRow, columnIndex: columnIndex)
        case .url:
            return urlCell(value: value, documentRow: documentRow, columnIndex: columnIndex)
        default:
            let id = NSUserInterfaceItemIdentifier("DataCell")
            let cell = tableView.makeView(withIdentifier: id, owner: self) as? NSTableCellView ?? makeCellView(identifier: id)
            if let textField = cell.textField as? DataCellTextField {
                configure(textField: textField, value: value, schema: columnSchema)
                textField.isEditable = isEditingEnabled
                textField.documentRow = documentRow
                textField.columnIndex = columnIndex
                textField.rawValue = value
            }
            return cell
        }
    }

    func tableView(_ tableView: NSTableView, sortDescriptorsDidChange oldDescriptors: [NSSortDescriptor]) {
        rebuildVisibleRows()
    }

    func tableViewColumnDidResize(_ notification: Notification) {
        captureMetadata()
    }

    func tableViewSelectionDidChange(_ notification: Notification) {
        updateToolbarState()
    }

    func controlTextDidEndEditing(_ obj: Notification) {
        guard let textField = obj.object as? DataCellTextField else { return }
        let newValue = rawValueForEditedText(textField.stringValue, textField: textField)
        if newValue != textField.rawValue {
            tableDocument?.setValue(newValue, row: textField.documentRow, column: textField.columnIndex)
        }
        updateStatus()
    }

    func controlTextDidChange(_ obj: Notification) {
        if obj.object as? NSSearchField === searchField {
            rebuildVisibleRows()
        }
    }

    func windowWillClose(_ notification: Notification) {
        saveCurrentMetadata()
    }

    func validateMenuItem(_ menuItem: NSMenuItem) -> Bool {
        switch menuItem.action {
        case #selector(copy(_:)):
            return !tableView.selectedRowIndexes.isEmpty
        case #selector(paste(_:)):
            return isEditingEnabled
        case #selector(addRowClicked(_:)):
            return isEditingEnabled
        case #selector(deleteRowsClicked(_:)):
            return isEditingEnabled && !tableView.selectedRowIndexes.isEmpty
        case #selector(renameColumnClicked(_:)), #selector(deleteColumnClicked(_:)):
            return isEditingEnabled && activeColumnIndex() != nil
        case #selector(setColumnTypeFromMenu(_:)):
            return metadata.schemaEnabled && activeColumnIndex() != nil
        case #selector(manageColumnOptionsClicked(_:)):
            guard metadata.schemaEnabled else { return false }
            guard let columnIndex = activeColumnIndex(),
                  let tableDocument,
                  tableDocument.headers.indices.contains(columnIndex) else { return false }
            let type = schema.schema(for: tableDocument.headers[columnIndex]).type
            return type == .select || type == .multiSelect || type == .status
        case #selector(toggleEditModeClicked(_:)):
            return tableDocument?.canEditFormat == true
        default:
            return true
        }
    }

    func toolbarAllowedItemIdentifiers(_ toolbar: NSToolbar) -> [NSToolbarItem.Identifier] {
        [.openFile, .saveFile, .toggleEdit, .toggleTypes, .filterPanel, .addRow, .deleteRow, .fileInfo, .flexibleSpace, .searchField]
    }

    func toolbarDefaultItemIdentifiers(_ toolbar: NSToolbar) -> [NSToolbarItem.Identifier] {
        [.openFile, .saveFile, .toggleEdit, .toggleTypes, .filterPanel, .addRow, .deleteRow, .fileInfo, .flexibleSpace, .searchField]
    }

    func toolbar(_ toolbar: NSToolbar, itemForItemIdentifier itemIdentifier: NSToolbarItem.Identifier, willBeInsertedIntoToolbar flag: Bool) -> NSToolbarItem? {
        switch itemIdentifier {
        case .openFile:
            let item = NSToolbarItem(itemIdentifier: itemIdentifier)
            item.label = "Open"
            item.paletteLabel = "Open"
            item.toolTip = "Open a local data file"
            item.image = NSImage(systemSymbolName: "folder", accessibilityDescription: "Open")
            item.target = self
            item.action = #selector(openClicked(_:))
            return item
        case .saveFile:
            let item = NSToolbarItem(itemIdentifier: itemIdentifier)
            item.label = "Save"
            item.paletteLabel = "Save"
            item.toolTip = "Save changes"
            item.image = NSImage(systemSymbolName: "square.and.arrow.down", accessibilityDescription: "Save")
            item.target = self
            item.action = #selector(saveClicked(_:))
            return item
        case .fileInfo:
            let item = NSToolbarItem(itemIdentifier: itemIdentifier)
            item.label = "Info"
            item.paletteLabel = "Info"
            item.toolTip = "Show file parsing information"
            item.image = NSImage(systemSymbolName: "info.circle", accessibilityDescription: "Info")
            item.target = self
            item.action = #selector(showFileInfoClicked(_:))
            return item
        case .toggleEdit:
            let item = NSToolbarItem(itemIdentifier: itemIdentifier)
            item.label = "Edit"
            item.paletteLabel = "Edit"
            item.toolTip = "Toggle read-only lock"
            item.image = NSImage(systemSymbolName: "lock", accessibilityDescription: "Edit")
            item.target = self
            item.action = #selector(toggleEditModeClicked(_:))
            editModeItem = item
            return item
        case .toggleTypes:
            let item = NSToolbarItem(itemIdentifier: itemIdentifier)
            item.label = "Types"
            item.paletteLabel = "Types"
            item.toolTip = "Toggle typed column display"
            item.image = NSImage(systemSymbolName: "tag", accessibilityDescription: "Types")
            item.target = self
            item.action = #selector(toggleTypesClicked(_:))
            typeModeItem = item
            return item
        case .filterPanel:
            let item = NSToolbarItem(itemIdentifier: itemIdentifier)
            item.label = "Filter"
            item.paletteLabel = "Filter"
            item.toolTip = "Show or hide filters"
            item.image = NSImage(systemSymbolName: "line.3.horizontal.decrease.circle", accessibilityDescription: "Filter")
            item.target = self
            item.action = #selector(toggleFilterPanelClicked(_:))
            filterItem = item
            return item
        case .addRow:
            let item = NSToolbarItem(itemIdentifier: itemIdentifier)
            item.label = "Add Row"
            item.paletteLabel = "Add Row"
            item.toolTip = "Add a new row"
            item.image = NSImage(systemSymbolName: "plus", accessibilityDescription: "Add Row")
            item.target = self
            item.action = #selector(addRowClicked(_:))
            addRowItem = item
            return item
        case .deleteRow:
            let item = NSToolbarItem(itemIdentifier: itemIdentifier)
            item.label = "Delete"
            item.paletteLabel = "Delete Row"
            item.toolTip = "Delete selected rows"
            item.image = NSImage(systemSymbolName: "trash", accessibilityDescription: "Delete")
            item.target = self
            item.action = #selector(deleteRowsClicked(_:))
            deleteRowItem = item
            return item
        case .searchField:
            searchField.placeholderString = "Search all columns"
            searchField.delegate = self
            searchField.frame = NSRect(x: 0, y: 0, width: 260, height: 28)
            searchField.widthAnchor.constraint(greaterThanOrEqualToConstant: 220).isActive = true
            searchField.widthAnchor.constraint(lessThanOrEqualToConstant: 360).isActive = true

            let item = NSToolbarItem(itemIdentifier: itemIdentifier)
            item.label = "Search"
            item.paletteLabel = "Search"
            item.view = searchField
            return item
        default:
            return nil
        }
    }

    func draggingEntered(_ sender: NSDraggingInfo) -> NSDragOperation {
        firstSupportedFileURL(from: sender.draggingPasteboard) == nil ? [] : .copy
    }

    func performDragOperation(_ sender: NSDraggingInfo) -> Bool {
        guard let url = firstSupportedFileURL(from: sender.draggingPasteboard) else { return false }
        open(url: url)
        return true
    }

    func appearanceDidChange() {
        scrollView.backgroundColor = .textBackgroundColor
        statusLabel.textColor = .secondaryLabelColor
        tableView.reloadData()
        tableView.needsDisplay = true
        tableView.headerView?.needsDisplay = true
        updateToolbarState()
    }

    func menuWillOpen(_ menu: NSMenu) {
        if contextColumnIndex == nil {
            contextColumnIndex = columnIndexForCurrentMouseLocation()
        }
    }

    func setContextColumnFromVisibleColumn(_ visibleColumn: Int) {
        guard visibleColumn >= 0,
              tableView.tableColumns.indices.contains(visibleColumn) else {
            contextColumnIndex = nil
            return
        }
        contextColumnIndex = Int(tableView.tableColumns[visibleColumn].identifier.rawValue)
    }

    @objc private func openClicked(_ sender: Any?) {
        NSApp.sendAction(#selector(AppDelegate.openDocument(_:)), to: NSApp.delegate, from: sender)
    }

    @objc private func saveClicked(_ sender: Any?) {
        saveDocument()
    }

    @objc private func showFileInfoClicked(_ sender: Any?) {
        guard let tableDocument else { return }
        let info = tableDocument.openInfo
        let alert = NSAlert()
        alert.messageText = tableDocument.url.lastPathComponent
        alert.informativeText = [
            "Format: \(tableDocument.format.displayName)",
            "Rows: \(tableDocument.rowCount)",
            "Columns: \(tableDocument.columnCount)",
            "Encoding: \(info.encoding?.displayName ?? "-")",
            "Line endings: \(info.lineEnding?.displayName ?? "-")",
            "Delimiter: \(info.delimiter.displayName)",
            "Mode: \(modeDescription(for: tableDocument))",
            "Types: \(metadata.schemaEnabled ? "On" : "Off")",
            "Typed columns: \(schema.columns.count)",
            "Reason: \(info.readOnlyReason ?? "-")"
        ].joined(separator: "\n")
        alert.addButton(withTitle: "OK")
        alert.runModal()
    }

    @objc private func toggleEditModeClicked(_ sender: Any?) {
        guard let tableDocument else { return }
        guard tableDocument.canEditFormat else {
            showError(TableDocumentError.saveUnsupported(tableDocument.openInfo.readOnlyReason ?? "\(tableDocument.format.displayName) is read-only."))
            return
        }
        editLocked.toggle()
        tableView.reloadData()
        updateStatus()
        updateToolbarState()
    }

    @objc private func toggleTypesClicked(_ sender: Any?) {
        guard let tableDocument else { return }
        metadata.schemaEnabled.toggle()
        if metadata.schemaEnabled {
            schema = SchemaMetadataStore.load(for: tableDocument.url, headers: tableDocument.headers, rows: tableDocument.rows)
        } else {
            schema = TableSchema()
        }
        saveCurrentMetadata()
        buildColumns()
        refreshFilterControls()
        tableView.reloadData()
        updateStatus()
        updateToolbarState()
    }

    @objc private func toggleFilterPanelClicked(_ sender: Any?) {
        filterPanelVisible.toggle()
        filterBar?.isHidden = !filterPanelVisible
        updateToolbarState()
    }

    @objc private func addRowClicked(_ sender: Any?) {
        guard isEditingEnabled else { return }
        let selectedDocumentRows = selectedDocumentRowIndexes()
        let insertionRow = selectedDocumentRows.max()
        tableDocument?.addRow(after: insertionRow)
        rebuildVisibleRows()
        updateStatus()
        updateToolbarState()
    }

    @objc private func deleteRowsClicked(_ sender: Any?) {
        guard isEditingEnabled else { return }
        let selectedRows = selectedDocumentRowIndexes()
        guard !selectedRows.isEmpty else { return }
        tableDocument?.deleteRows(selectedRows)
        rebuildVisibleRows()
        updateStatus()
        updateToolbarState()
    }

    @objc private func renameColumnClicked(_ sender: Any?) {
        guard isEditingEnabled,
              let columnIndex = columnIndex(from: sender),
              let tableDocument else {
            return
        }

        let alert = NSAlert()
        alert.messageText = "Rename Column"
        alert.informativeText = tableDocument.headers[columnIndex]
        let input = NSTextField(frame: NSRect(x: 0, y: 0, width: 260, height: 24))
        input.stringValue = tableDocument.headers[columnIndex]
        alert.accessoryView = input
        alert.addButton(withTitle: "Rename")
        alert.addButton(withTitle: "Cancel")

        if alert.runModal() == .alertFirstButtonReturn {
            let oldHeader = tableDocument.headers[columnIndex]
            let oldSchema = schema.schema(for: oldHeader)
            self.tableDocument?.renameColumn(at: columnIndex, to: input.stringValue)
            if let updatedHeader = self.tableDocument?.headers[columnIndex] {
                schema.columns.removeValue(forKey: oldHeader)
                schema.columns[updatedHeader] = oldSchema
                saveCurrentSchema()
            }
            buildColumns()
            refreshFilterControls()
            rebuildVisibleRows()
            updateStatus()
        }
    }

    @objc private func deleteColumnClicked(_ sender: Any?) {
        guard isEditingEnabled,
              let columnIndex = columnIndex(from: sender) else {
            return
        }
        tableDocument?.deleteColumn(at: columnIndex)
        if let tableDocument {
            schema.removeMissingColumns(validHeaders: tableDocument.headers)
            saveCurrentSchema()
        }
        buildColumns()
        refreshFilterControls()
        rebuildVisibleRows()
        updateStatus()
    }

    @objc func copy(_ sender: Any?) {
        let text = selectedTabDelimitedText()
        guard !text.isEmpty else { return }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
    }

    @objc func paste(_ sender: Any?) {
        guard isEditingEnabled,
              let text = NSPasteboard.general.string(forType: .string),
              !text.isEmpty else {
            return
        }

        let startRow = selectedDocumentRowIndexes().min() ?? tableDocument?.rows.count ?? 0
        let startColumn = selectedDataColumnIndex() ?? 0
        let pastedRows = DelimitedTextParser.parse(text, delimiter: "\t")
        guard !pastedRows.isEmpty else { return }

        tableDocument?.pasteRows(pastedRows, startingAt: startRow, column: startColumn)
        rebuildVisibleRows()
        updateStatus()
    }

    @objc private func checkboxClicked(_ sender: DataCellButton) {
        guard isEditingEnabled,
              let tableDocument,
              tableDocument.headers.indices.contains(sender.columnIndex) else {
            return
        }
        let columnSchema = schema.schema(for: tableDocument.headers[sender.columnIndex])
        let nextValue = boolValue(sender.rawValue, schema: columnSchema) ? "false" : "true"
        self.tableDocument?.setValue(nextValue, row: sender.documentRow, column: sender.columnIndex)
        tableView.reloadData()
        updateStatus()
    }

    @objc private func popupChanged(_ sender: DataCellPopupButton) {
        guard isEditingEnabled else { return }
        let value = sender.titleOfSelectedItem ?? ""
        tableDocument?.setValue(value, row: sender.documentRow, column: sender.columnIndex)
        updateStatus()
    }

    @objc private func multiSelectClicked(_ sender: DataCellButton) {
        guard isEditingEnabled,
              var tableDocument,
              tableDocument.headers.indices.contains(sender.columnIndex) else {
            return
        }
        let header = tableDocument.headers[sender.columnIndex]
        let columnSchema = schema.schema(for: header)
        let alert = NSAlert()
        alert.messageText = "Edit Multi-select"
        alert.informativeText = "Separate values with \(columnSchema.multiSelectSeparator)"
        let input = NSTextField(frame: NSRect(x: 0, y: 0, width: 320, height: 24))
        input.stringValue = sender.rawValue
        alert.accessoryView = input
        alert.addButton(withTitle: "Save")
        alert.addButton(withTitle: "Cancel")

        if alert.runModal() == .alertFirstButtonReturn {
            tableDocument.setValue(input.stringValue, row: sender.documentRow, column: sender.columnIndex)
            self.tableDocument = tableDocument
            let values = tableDocument.rows.compactMap { row in
                sender.columnIndex < row.count ? row[sender.columnIndex] : nil
            }
            schema.setType(.multiSelect, for: header, sampleValues: values)
            saveCurrentSchema()
            tableView.reloadData()
            updateStatus()
        }
    }

    @objc private func urlClicked(_ sender: DataCellButton) {
        guard let url = URL(string: sender.rawValue),
              url.scheme?.hasPrefix("http") == true else {
            return
        }
        NSWorkspace.shared.open(url)
    }

    @objc private func setColumnTypeFromMenu(_ sender: NSMenuItem) {
        guard metadata.schemaEnabled,
              let type = (sender as? ColumnTypeMenuItem)?.columnType ?? sender.representedObject as? ColumnType,
              let columnIndex = columnIndex(from: sender),
              let tableDocument,
              tableDocument.headers.indices.contains(columnIndex) else {
            return
        }

        let header = tableDocument.headers[columnIndex]
        let sample = tableDocument.rows.compactMap { row in
            columnIndex < row.count ? row[columnIndex] : nil
        }
        schema.setType(type, for: header, sampleValues: sample)
        saveCurrentSchema()
        buildColumns()
        tableView.reloadData()
        updateStatus()
    }

    @objc private func manageColumnOptionsClicked(_ sender: Any?) {
        guard let columnIndex = columnIndex(from: sender),
              let tableDocument,
              tableDocument.headers.indices.contains(columnIndex) else {
            return
        }
        let header = tableDocument.headers[columnIndex]
        var columnSchema = schema.schema(for: header)
        guard columnSchema.type == .select || columnSchema.type == .multiSelect || columnSchema.type == .status else {
            return
        }

        let alert = NSAlert()
        alert.messageText = "Manage Options"
        alert.informativeText = "Enter options separated by commas."
        let input = NSTextField(frame: NSRect(x: 0, y: 0, width: 360, height: 24))
        input.stringValue = columnSchema.options.map(\.name).joined(separator: ", ")
        alert.accessoryView = input
        alert.addButton(withTitle: "Save")
        alert.addButton(withTitle: "Cancel")
        if alert.runModal() == .alertFirstButtonReturn {
            let palette = ["gray", "blue", "green", "yellow", "red", "purple", "pink", "orange"]
            let names = input.stringValue.split(separator: ",").map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }.filter { !$0.isEmpty }
            columnSchema.options = names.enumerated().map { index, name in
                SelectOption(name: name, color: palette[index % palette.count])
            }
            schema.columns[header] = columnSchema
            saveCurrentSchema()
            tableView.reloadData()
        }
    }

    @objc private func applyFilterClicked(_ sender: Any?) {
        guard let tableDocument, columnPopup.indexOfSelectedItem >= 0 else { return }
        let columnIndex = columnPopup.indexOfSelectedItem
        let operation = FilterOperator.allCases[operatorPopup.indexOfSelectedItem]
        let value = filterValueField.stringValue

        if operation == .contains || operation == .equals {
            guard !value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                activeFilter = nil
                rebuildVisibleRows()
                return
            }
        }

        guard tableDocument.headers.indices.contains(columnIndex) else { return }
        activeFilter = TableFilter(columnIndex: columnIndex, operation: operation, value: value)
        rebuildVisibleRows()
    }

    @objc private func clearFilterClicked(_ sender: Any?) {
        activeFilter = nil
        filterValueField.stringValue = ""
        rebuildVisibleRows()
    }

    @objc private func delimiterChanged(_ sender: Any?) {
        guard let tableDocument else { return }
        if tableDocument.dirty {
            showError(TableDocumentError.saveUnsupported("Save or reopen the file before changing delimiter."))
            refreshDelimiterControl()
            return
        }
        guard let delimiter = selectedDelimiterOverride() else {
            open(url: tableDocument.url)
            return
        }
        do {
            saveCurrentMetadata()
            let loaded = try TableDocument.load(url: tableDocument.url, delimiterOverride: delimiter)
            self.tableDocument = loaded
            metadata = ViewMetadataStore.load(for: loaded.url)
            schema = metadata.schemaEnabled ? SchemaMetadataStore.load(for: loaded.url, headers: loaded.headers, rows: loaded.rows) : TableSchema()
            activeFilter = nil
            filterValueField.stringValue = ""
            buildColumns()
            refreshFilterControls()
            refreshDelimiterControl()
            rebuildVisibleRows()
            updateStatus()
        } catch {
            showError(error)
        }
    }

    private func buildInterface() {
        guard let window else { return }
        rootView.dropHandler = self
        rootView.wantsLayer = false
        window.contentView = rootView
        rootView.registerForDraggedTypes([.fileURL])

        let filterBar = buildFilterBar()
        self.filterBar = filterBar
        filterBar.isHidden = !filterPanelVisible

        scrollView.documentView = tableView
        scrollView.hasVerticalScroller = true
        scrollView.hasHorizontalScroller = true
        scrollView.drawsBackground = true
        scrollView.backgroundColor = .textBackgroundColor

        tableView.usesAlternatingRowBackgroundColors = true
        tableView.allowsColumnReordering = true
        tableView.allowsColumnResizing = true
        tableView.allowsMultipleSelection = true
        tableView.gridStyleMask = [.solidHorizontalGridLineMask, .solidVerticalGridLineMask]
        tableView.rowHeight = 28
        let headerView = DataTableHeaderView()
        headerView.columnActionHandler = self
        tableView.headerView = headerView
        tableView.dataSource = self
        tableView.delegate = self
        tableView.cornerView = NSView()
        tableView.menu = buildTableContextMenu()

        configureStatusBadge()

        let stack = NSStackView(views: [filterBar, scrollView])
        stack.orientation = .vertical
        stack.spacing = 0
        stack.translatesAutoresizingMaskIntoConstraints = false
        rootView.addSubview(stack)
        rootView.addSubview(statusBadge)

        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: rootView.leadingAnchor),
            stack.trailingAnchor.constraint(equalTo: rootView.trailingAnchor),
            stack.topAnchor.constraint(equalTo: rootView.topAnchor),
            stack.bottomAnchor.constraint(equalTo: rootView.bottomAnchor),

            statusBadge.trailingAnchor.constraint(equalTo: scrollView.trailingAnchor, constant: -16),
            statusBadge.bottomAnchor.constraint(equalTo: scrollView.bottomAnchor, constant: -16)
        ])

        buildColumns()
        refreshFilterControls()
        updateToolbarState()
    }

    private func configureWindow() {
        guard !didBuildInterface else { return }
        didBuildInterface = true
        window?.delegate = self
        appearanceObservation = window?.observe(\.effectiveAppearance, options: [.new]) { [weak self] _, _ in
            self?.appearanceDidChange()
        }
        configureToolbar()
        buildInterface()
        rebuildVisibleRows()
    }

    private func configureToolbar() {
        fileLabel.font = .systemFont(ofSize: 13, weight: .medium)
        fileLabel.lineBreakMode = .byTruncatingMiddle
        let toolbar = NSToolbar(identifier: "LightDataMainToolbar")
        toolbar.displayMode = .iconAndLabel
        toolbar.allowsUserCustomization = true
        toolbar.delegate = self
        window?.toolbar = toolbar
        window?.toolbarStyle = .unified
        window?.titleVisibility = .visible
    }

    private func configureStatusBadge() {
        statusBadge.translatesAutoresizingMaskIntoConstraints = false
        statusBadge.material = .underWindowBackground
        statusBadge.blendingMode = .withinWindow
        statusBadge.state = .active
        statusBadge.wantsLayer = true
        statusBadge.layer?.cornerRadius = 8
        statusBadge.layer?.masksToBounds = true

        statusLabel.textColor = .labelColor
        statusLabel.font = .systemFont(ofSize: 12, weight: .medium)
        statusLabel.alignment = .center
        statusLabel.translatesAutoresizingMaskIntoConstraints = false

        statusBadge.addSubview(statusLabel)
        NSLayoutConstraint.activate([
            statusLabel.leadingAnchor.constraint(equalTo: statusBadge.leadingAnchor, constant: 10),
            statusLabel.trailingAnchor.constraint(equalTo: statusBadge.trailingAnchor, constant: -10),
            statusLabel.topAnchor.constraint(equalTo: statusBadge.topAnchor, constant: 5),
            statusLabel.bottomAnchor.constraint(equalTo: statusBadge.bottomAnchor, constant: -5)
        ])
    }

    private func buildFilterBar() -> NSView {
        delimiterPopup.removeAllItems()
        delimiterPopup.addItems(withTitles: ["Auto", "Comma", "Tab", "Semicolon", "Pipe"])
        delimiterPopup.target = self
        delimiterPopup.action = #selector(delimiterChanged(_:))
        delimiterPopup.widthAnchor.constraint(equalToConstant: 120).isActive = true

        columnPopup.widthAnchor.constraint(equalToConstant: 180).isActive = true
        operatorPopup.removeAllItems()
        operatorPopup.addItems(withTitles: FilterOperator.allCases.map(\.rawValue))
        operatorPopup.widthAnchor.constraint(equalToConstant: 120).isActive = true

        filterValueField.placeholderString = "Filter value"
        filterValueField.widthAnchor.constraint(equalToConstant: 220).isActive = true

        let applyButton = NSButton(title: "Apply Filter", target: self, action: #selector(applyFilterClicked(_:)))
        let clearButton = NSButton(title: "Clear", target: self, action: #selector(clearFilterClicked(_:)))

        let stack = NSStackView(views: [
            NSTextField(labelWithString: "Delimiter"),
            delimiterPopup,
            NSTextField(labelWithString: "Filter"),
            columnPopup,
            operatorPopup,
            filterValueField,
            applyButton,
            clearButton
        ])
        stack.orientation = .horizontal
        stack.alignment = .centerY
        stack.spacing = 8
        stack.edgeInsets = NSEdgeInsets(top: 0, left: 12, bottom: 10, right: 12)
        return stack
    }

    private func makeCellView(identifier: NSUserInterfaceItemIdentifier) -> NSTableCellView {
        let cell = NSTableCellView()
        cell.identifier = identifier

        let textField = DataCellTextField()
        textField.isBordered = false
        textField.drawsBackground = false
        textField.lineBreakMode = .byTruncatingTail
        textField.font = .systemFont(ofSize: 13)
        textField.delegate = self
        textField.translatesAutoresizingMaskIntoConstraints = false

        cell.addSubview(textField)
        cell.textField = textField
        NSLayoutConstraint.activate([
            textField.leadingAnchor.constraint(equalTo: cell.leadingAnchor, constant: 8),
            textField.trailingAnchor.constraint(equalTo: cell.trailingAnchor, constant: -8),
            textField.centerYAnchor.constraint(equalTo: cell.centerYAnchor)
        ])
        return cell
    }

    private func checkboxCell(value: String, schema: ColumnSchema, documentRow: Int, columnIndex: Int) -> NSView {
        let id = NSUserInterfaceItemIdentifier("CheckboxCell")
        let cell = tableView.makeView(withIdentifier: id, owner: self) as? NSTableCellView ?? makeButtonCell(identifier: id)
        guard let button = cell.subviews.first as? DataCellButton else { return cell }
        button.setButtonType(.switch)
        button.title = ""
        button.contentTintColor = nil
        button.state = boolValue(value, schema: schema) ? .on : .off
        button.isEnabled = isEditingEnabled
        button.target = self
        button.action = #selector(checkboxClicked(_:))
        button.documentRow = documentRow
        button.columnIndex = columnIndex
        button.rawValue = value
        return cell
    }

    private func popupCell(value: String, schema: ColumnSchema, documentRow: Int, columnIndex: Int) -> NSView {
        let id = NSUserInterfaceItemIdentifier("PopupCell")
        let cell = tableView.makeView(withIdentifier: id, owner: self) as? NSTableCellView ?? makePopupCell(identifier: id)
        guard let popup = cell.subviews.first as? DataCellPopupButton else { return cell }
        popup.removeAllItems()
        let options = schema.options.map(\.name)
        popup.addItems(withTitles: options.isEmpty ? [""] : options)
        if !value.isEmpty, !options.contains(value) {
            popup.addItem(withTitle: value)
        }
        popup.selectItem(withTitle: value)
        popup.isEnabled = isEditingEnabled
        popup.target = self
        popup.action = #selector(popupChanged(_:))
        popup.documentRow = documentRow
        popup.columnIndex = columnIndex
        return cell
    }

    private func multiSelectCell(value: String, schema: ColumnSchema, documentRow: Int, columnIndex: Int) -> NSView {
        let id = NSUserInterfaceItemIdentifier("MultiSelectCell")
        let cell = tableView.makeView(withIdentifier: id, owner: self) as? NSTableCellView ?? makeButtonCell(identifier: id)
        guard let button = cell.subviews.first as? DataCellButton else { return cell }
        button.setButtonType(.momentaryPushIn)
        button.bezelStyle = .rounded
        button.contentTintColor = nil
        button.title = displayValue(value, schema: schema).isEmpty ? " " : displayValue(value, schema: schema)
        button.isEnabled = isEditingEnabled
        button.target = self
        button.action = #selector(multiSelectClicked(_:))
        button.documentRow = documentRow
        button.columnIndex = columnIndex
        button.rawValue = value
        return cell
    }

    private func urlCell(value: String, documentRow: Int, columnIndex: Int) -> NSView {
        let id = NSUserInterfaceItemIdentifier("URLCell")
        let cell = tableView.makeView(withIdentifier: id, owner: self) as? NSTableCellView ?? makeButtonCell(identifier: id)
        guard let button = cell.subviews.first as? DataCellButton else { return cell }
        button.setButtonType(.momentaryChange)
        button.bezelStyle = .inline
        button.title = value
        button.contentTintColor = .linkColor
        button.alignment = .left
        button.isEnabled = !value.isEmpty
        button.target = self
        button.action = #selector(urlClicked(_:))
        button.documentRow = documentRow
        button.columnIndex = columnIndex
        button.rawValue = value
        return cell
    }

    private func makeButtonCell(identifier: NSUserInterfaceItemIdentifier) -> NSTableCellView {
        let cell = NSTableCellView()
        cell.identifier = identifier
        let button = DataCellButton()
        button.translatesAutoresizingMaskIntoConstraints = false
        cell.addSubview(button)
        NSLayoutConstraint.activate([
            button.leadingAnchor.constraint(equalTo: cell.leadingAnchor, constant: 8),
            button.trailingAnchor.constraint(lessThanOrEqualTo: cell.trailingAnchor, constant: -8),
            button.centerYAnchor.constraint(equalTo: cell.centerYAnchor)
        ])
        return cell
    }

    private func makePopupCell(identifier: NSUserInterfaceItemIdentifier) -> NSTableCellView {
        let cell = NSTableCellView()
        cell.identifier = identifier
        let popup = DataCellPopupButton()
        popup.translatesAutoresizingMaskIntoConstraints = false
        cell.addSubview(popup)
        NSLayoutConstraint.activate([
            popup.leadingAnchor.constraint(equalTo: cell.leadingAnchor, constant: 6),
            popup.trailingAnchor.constraint(equalTo: cell.trailingAnchor, constant: -6),
            popup.centerYAnchor.constraint(equalTo: cell.centerYAnchor)
        ])
        return cell
    }

    private func buildTableContextMenu() -> NSMenu {
        let menu = NSMenu()
        menu.delegate = self
        menu.addItem(contextMenuItem(title: "Copy", action: #selector(copy(_:))))
        menu.addItem(contextMenuItem(title: "Paste", action: #selector(paste(_:))))
        menu.addItem(.separator())
        menu.addItem(contextMenuItem(title: "Add Row", action: #selector(addRowClicked(_:))))
        menu.addItem(contextMenuItem(title: "Delete Selected Rows", action: #selector(deleteRowsClicked(_:))))
        return menu
    }

    func buildHeaderContextMenu(forVisibleColumn visibleColumn: Int) -> NSMenu? {
        setContextColumnFromVisibleColumn(visibleColumn)
        guard let columnIndex = contextColumnIndex else { return nil }
        let menu = NSMenu()
        menu.addItem(columnMenuItem(title: "Rename Column", action: #selector(renameColumnClicked(_:)), columnIndex: columnIndex))
        menu.addItem(columnMenuItem(title: "Delete Column", action: #selector(deleteColumnClicked(_:)), columnIndex: columnIndex))
        if metadata.schemaEnabled {
            menu.addItem(.separator())
            menu.addItem(typeMenuItem(columnIndex: columnIndex))
            menu.addItem(columnMenuItem(title: "Manage Options", action: #selector(manageColumnOptionsClicked(_:)), columnIndex: columnIndex))
        }
        return menu
    }

    private func contextMenuItem(title: String, action: Selector) -> NSMenuItem {
        let item = NSMenuItem(title: title, action: action, keyEquivalent: "")
        item.target = self
        return item
    }

    private func columnMenuItem(title: String, action: Selector, columnIndex: Int) -> NSMenuItem {
        let item = ColumnMenuItem(title: title, action: action, keyEquivalent: "")
        item.columnIndex = columnIndex
        item.target = self
        return item
    }

    private func typeMenuItem(columnIndex: Int? = nil) -> NSMenuItem {
        let item = NSMenuItem(title: "Set Type", action: nil, keyEquivalent: "")
        let submenu = NSMenu()
        for type in ColumnType.allCases {
            let typeItem = ColumnTypeMenuItem(title: type.displayName, action: #selector(setColumnTypeFromMenu(_:)), keyEquivalent: "")
            typeItem.representedObject = type
            typeItem.columnIndex = columnIndex ?? activeColumnIndex() ?? 0
            typeItem.columnType = type
            typeItem.target = self
            submenu.addItem(typeItem)
        }
        item.submenu = submenu
        return item
    }

    private func buildColumns() {
        tableView.tableColumns.forEach { tableView.removeTableColumn($0) }
        guard let tableDocument else { return }

        let rowNumberColumn = NSTableColumn(identifier: NSUserInterfaceItemIdentifier("rowNumber"))
        rowNumberColumn.title = "#"
        rowNumberColumn.width = 56
        rowNumberColumn.minWidth = 48
        rowNumberColumn.maxWidth = 72
        tableView.addTableColumn(rowNumberColumn)

        for (index, header) in tableDocument.headers.enumerated() {
            let identifier = NSUserInterfaceItemIdentifier(String(index))
            let column = NSTableColumn(identifier: identifier)
            let type = metadata.schemaEnabled ? schema.schema(for: header).type : .text
            column.title = metadata.schemaEnabled ? "\(header)  \(type.displayName)" : header
            column.minWidth = 80
            column.width = metadata.columnWidths[header] ?? max(120, min(260, CGFloat(header.count * 10 + 44)))
            column.sortDescriptorPrototype = NSSortDescriptor(key: String(index), ascending: true)
            tableView.addTableColumn(column)
        }
    }

    private func refreshFilterControls() {
        columnPopup.removeAllItems()
        if let tableDocument {
            columnPopup.addItems(withTitles: tableDocument.headers)
        }
        saveButton.isEnabled = tableDocument?.readOnly == false
    }

    private func refreshDelimiterControl() {
        guard let tableDocument else {
            delimiterPopup.isEnabled = false
            delimiterPopup.selectItem(withTitle: "Auto")
            return
        }
        delimiterPopup.isEnabled = tableDocument.format == .csv || tableDocument.format == .tsv
        switch tableDocument.openInfo.delimiter {
        case .comma: delimiterPopup.selectItem(withTitle: "Comma")
        case .tab: delimiterPopup.selectItem(withTitle: "Tab")
        case .semicolon: delimiterPopup.selectItem(withTitle: "Semicolon")
        case .pipe: delimiterPopup.selectItem(withTitle: "Pipe")
        default: delimiterPopup.selectItem(withTitle: "Auto")
        }
    }

    private func selectedDelimiterOverride() -> Character? {
        switch delimiterPopup.titleOfSelectedItem {
        case "Comma": ","
        case "Tab": "\t"
        case "Semicolon": ";"
        case "Pipe": "|"
        default: nil
        }
    }

    private func rebuildVisibleRows() {
        visibleRows = TableQueryEngine.visibleRows(
            in: tableDocument,
            search: searchField.stringValue,
            filter: activeFilter,
            sortDescriptor: tableView.sortDescriptors.first
        )
        tableView.reloadData()
        updateStatus()
    }

    private func updateStatus() {
        guard let tableDocument else {
            fileLabel.stringValue = "No file"
            statusLabel.stringValue = ""
            statusBadge.isHidden = true
            saveButton.isEnabled = false
            return
        }

        fileLabel.stringValue = tableDocument.url.lastPathComponent
        let dirty = tableDocument.dirty ? " *" : ""
        statusLabel.stringValue = "\(visibleRows.count)/\(tableDocument.rowCount) rows · \(tableDocument.columnCount) cols\(dirty)"
        statusBadge.isHidden = false
        saveButton.isEnabled = tableDocument.canEditFormat && tableDocument.dirty
    }

    private var isEditingEnabled: Bool {
        tableDocument?.canEditFormat == true && !editLocked
    }

    private func modeDescription(for document: TableDocument) -> String {
        if document.readOnly {
            return "format read-only"
        }
        return editLocked ? "locked read-only" : "edit mode"
    }

    private func updateToolbarState() {
        let canEditFormat = tableDocument?.canEditFormat == true
        editModeItem?.isEnabled = canEditFormat
        editModeItem?.label = isEditingEnabled ? "Lock" : "Edit"
        editModeItem?.image = NSImage(
            systemSymbolName: isEditingEnabled ? "lock.open" : "lock",
            accessibilityDescription: isEditingEnabled ? "Lock" : "Edit"
        )
        addRowItem?.isEnabled = isEditingEnabled
        deleteRowItem?.isEnabled = isEditingEnabled && !tableView.selectedRowIndexes.isEmpty
        typeModeItem?.isEnabled = tableDocument != nil
        typeModeItem?.label = metadata.schemaEnabled ? "Types On" : "Types Off"
        typeModeItem?.image = NSImage(
            systemSymbolName: metadata.schemaEnabled ? "tag.fill" : "tag",
            accessibilityDescription: metadata.schemaEnabled ? "Types On" : "Types Off"
        )
        filterItem?.label = filterPanelVisible ? "Hide Filter" : "Filter"
        filterItem?.image = NSImage(
            systemSymbolName: filterPanelVisible ? "line.3.horizontal.decrease.circle.fill" : "line.3.horizontal.decrease.circle",
            accessibilityDescription: filterPanelVisible ? "Hide Filter" : "Filter"
        )
        saveButton.isEnabled = tableDocument?.canEditFormat == true && tableDocument?.dirty == true
    }

    private func selectedDocumentRowIndexes() -> IndexSet {
        var indexes = IndexSet()
        for visibleIndex in tableView.selectedRowIndexes where visibleRows.indices.contains(visibleIndex) {
            indexes.insert(visibleRows[visibleIndex])
        }
        return indexes
    }

    private func selectedDataColumnIndex() -> Int? {
        let selectedColumn = tableView.selectedColumn
        guard selectedColumn >= 0,
              tableView.tableColumns.indices.contains(selectedColumn) else {
            return nil
        }
        return Int(tableView.tableColumns[selectedColumn].identifier.rawValue)
    }

    private func activeColumnIndex() -> Int? {
        contextColumnIndex ?? selectedDataColumnIndex()
    }

    private func columnIndex(from sender: Any?) -> Int? {
        if let item = sender as? ColumnTypeMenuItem {
            return item.columnIndex
        }
        if let item = sender as? ColumnMenuItem {
            return item.columnIndex
        }
        return activeColumnIndex()
    }

    private func columnIndexForCurrentMouseLocation() -> Int? {
        guard let window else { return nil }
        let windowPoint = window.mouseLocationOutsideOfEventStream
        let tablePoint = tableView.convert(windowPoint, from: nil)
        let visibleColumn = tableView.column(at: tablePoint)
        guard visibleColumn >= 0,
              tableView.tableColumns.indices.contains(visibleColumn) else {
            return nil
        }
        return Int(tableView.tableColumns[visibleColumn].identifier.rawValue)
    }

    private func selectedTabDelimitedText() -> String {
        guard let tableDocument else { return "" }
        let selectedRows = tableView.selectedRowIndexes
        let selectedColumns = tableView.selectedColumnIndexes
        guard !selectedRows.isEmpty else { return "" }

        let dataColumns: [Int]
        if selectedColumns.isEmpty {
            dataColumns = Array(tableDocument.headers.indices)
        } else {
            dataColumns = selectedColumns.compactMap { visibleColumn -> Int? in
                guard tableView.tableColumns.indices.contains(visibleColumn) else { return nil }
                return Int(tableView.tableColumns[visibleColumn].identifier.rawValue)
            }
        }

        guard !dataColumns.isEmpty else { return "" }
        return selectedRows.compactMap { visibleRow -> String? in
            guard visibleRows.indices.contains(visibleRow) else { return nil }
            let documentRow = visibleRows[visibleRow]
            return dataColumns.map { columnIndex in
                columnIndex < tableDocument.rows[documentRow].count ? tableDocument.rows[documentRow][columnIndex] : ""
            }.joined(separator: "\t")
        }.joined(separator: "\n")
    }

    private func captureMetadata() {
        guard let tableDocument else { return }
        var widths: [String: Double] = [:]
        for column in tableView.tableColumns {
            guard let index = Int(column.identifier.rawValue),
                  tableDocument.headers.indices.contains(index) else {
                continue
            }
            widths[tableDocument.headers[index]] = Double(column.width)
        }
        metadata.columnWidths = widths
    }

    private func saveCurrentMetadata() {
        guard let tableDocument else { return }
        captureMetadata()
        ViewMetadataStore.save(metadata, for: tableDocument.url)
    }

    private func saveCurrentSchema() {
        guard let tableDocument else { return }
        SchemaMetadataStore.save(schema, for: tableDocument.url)
    }

    private func configure(textField: DataCellTextField, value: String, schema: ColumnSchema) {
        textField.alignment = schema.type == .number ? .right : .left
        textField.textColor = .labelColor
        textField.backgroundColor = .clear
        textField.stringValue = displayValue(value, schema: schema)

        switch schema.type {
        case .url:
            textField.textColor = .linkColor
        case .select, .multiSelect, .status:
            textField.textColor = colorForTag(value, schema: schema)
        case .checkbox:
            textField.alignment = .center
        default:
            break
        }
    }

    private func rawValueForEditedText(_ text: String, textField: DataCellTextField) -> String {
        guard let tableDocument,
              tableDocument.headers.indices.contains(textField.columnIndex) else {
            return text
        }
        let columnSchema = schema.schema(for: tableDocument.headers[textField.columnIndex])
        if text == displayValue(textField.rawValue, schema: columnSchema) {
            return textField.rawValue
        }
        if columnSchema.type == .checkbox {
            let normalized = text.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
            if normalized == "✓" || normalized == "true" || normalized == "yes" || normalized == "1" {
                return "true"
            }
            return "false"
        }
        return text
    }

    private func displayValue(_ value: String, schema: ColumnSchema) -> String {
        switch schema.type {
        case .checkbox:
            return boolValue(value, schema: schema) ? "✓" : ""
        case .multiSelect:
            return value
                .split(separator: Character(schema.multiSelectSeparator))
                .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
                .filter { !$0.isEmpty }
                .joined(separator: "  ")
        default:
            return value
        }
    }

    private func boolValue(_ value: String, schema: ColumnSchema) -> Bool {
        schema.trueValues.contains(value.trimmingCharacters(in: .whitespacesAndNewlines).lowercased())
    }

    private func colorForTag(_ value: String, schema: ColumnSchema) -> NSColor {
        let name = value.split(separator: Character(schema.multiSelectSeparator)).first.map { String($0).trimmingCharacters(in: .whitespacesAndNewlines) } ?? value
        let colorName = schema.options.first { $0.name == name }?.color ?? "gray"
        switch colorName {
        case "blue": return .systemBlue
        case "green": return .systemGreen
        case "yellow": return .systemYellow
        case "red": return .systemRed
        case "purple": return .systemPurple
        case "pink": return .systemPink
        case "orange": return .systemOrange
        default: return .secondaryLabelColor
        }
    }

    private func showError(_ error: Error) {
        let alert = NSAlert(error: error)
        alert.runModal()
    }

    private func firstSupportedFileURL(from pasteboard: NSPasteboard) -> URL? {
        guard let items = pasteboard.pasteboardItems else { return nil }
        for item in items {
            guard let string = item.string(forType: .fileURL),
                  let url = URL(string: string) else {
                continue
            }
            let ext = url.pathExtension.lowercased()
            if ["csv", "tsv", "tab", "json", "jsonl", "ndjson", "xlsx"].contains(ext) {
                return url
            }
        }
        return nil
    }
}

private extension NSToolbarItem.Identifier {
    static let openFile = NSToolbarItem.Identifier("LightDataOpenFile")
    static let saveFile = NSToolbarItem.Identifier("LightDataSaveFile")
    static let fileInfo = NSToolbarItem.Identifier("LightDataFileInfo")
    static let toggleEdit = NSToolbarItem.Identifier("LightDataToggleEdit")
    static let toggleTypes = NSToolbarItem.Identifier("LightDataToggleTypes")
    static let filterPanel = NSToolbarItem.Identifier("LightDataFilterPanel")
    static let addRow = NSToolbarItem.Identifier("LightDataAddRow")
    static let deleteRow = NSToolbarItem.Identifier("LightDataDeleteRow")
    static let searchField = NSToolbarItem.Identifier("LightDataSearchField")
}
