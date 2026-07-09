import AppKit
import LightDataCore
import UniformTypeIdentifiers

extension NSMenu {
    /// Recursively finds the first menu item with the given action.
    func findItem(withAction action: Selector) -> NSMenuItem? {
        for item in items {
            if item.action == action { return item }
            if let found = item.submenu?.findItem(withAction: action) { return found }
        }
        return nil
    }
}

protocol DataCellMouseHandling: AnyObject {
    func dataCellControlShouldHandleMouseDown(visibleRow: Int, columnIndex: Int, event: NSEvent) -> Bool
    func dataCellRequestsTagPicker(documentRow: Int, columnIndex: Int, multi: Bool, sourceView: NSView)
}

final class DataCellTextField: NSTextField {
    weak var mouseHandler: DataCellMouseHandling?
    var visibleRow = 0
    var documentRow = 0
    var columnIndex = 0
    var rawValue = ""

    override func resetCursorRects() {
        addCursorRect(bounds, cursor: .arrow)
    }

    // Let mouse events fall through to the table view so row-number clicks/drags
    // are handled in one place (selection + reorder).
    override func hitTest(_ point: NSPoint) -> NSView? {
        nil
    }

    override func mouseDown(with event: NSEvent) {
        _ = mouseHandler?.dataCellControlShouldHandleMouseDown(visibleRow: visibleRow, columnIndex: columnIndex, event: event)
    }
}

final class DataTextCellView: NSView {
    var visibleRow = 0
    var documentRow = 0
    var columnIndex = 0
    var rawValue = ""
    var displayString = "" {
        didSet { needsDisplay = true }
    }
    var textColor = NSColor.labelColor {
        didSet { needsDisplay = true }
    }
    var alignment = NSTextAlignment.left {
        didSet { needsDisplay = true }
    }
    var font = NSFont.systemFont(ofSize: 13) {
        didSet { needsDisplay = true }
    }
    var selectionFill: NSColor? {
        didSet { needsDisplay = true }
    }

    override var isFlipped: Bool { true }
    override var acceptsFirstResponder: Bool { false }

    var textRect: NSRect {
        bounds.insetBy(dx: 8, dy: 0)
    }

    override func hitTest(_ point: NSPoint) -> NSView? {
        nil
    }

    override func draw(_ dirtyRect: NSRect) {
        super.draw(dirtyRect)
        if let selectionFill {
            selectionFill.setFill()
            NSBezierPath(rect: bounds).fill()
        }
        drawDisplayString(color: textColor, clippedTo: nil)
    }

    func drawDisplayString(color: NSColor, clippedTo clipRect: NSRect?) {
        guard !displayString.isEmpty else { return }
        let attributes = textAttributes(color: color)
        let string = displayString as NSString
        let size = string.size(withAttributes: attributes)
        let rect = textDrawRect(textWidth: size.width, textHeight: size.height)

        NSGraphicsContext.saveGraphicsState()
        if let clipRect {
            NSBezierPath(rect: clipRect).addClip()
        }
        string.draw(in: rect, withAttributes: attributes)
        NSGraphicsContext.restoreGraphicsState()
    }

    func xPosition(forUTF16Index index: Int) -> CGFloat {
        guard !displayString.isEmpty else { return textDrawOriginX(textWidth: 0) }
        let boundedIndex = max(0, min(index, (displayString as NSString).length))
        let prefix = (displayString as NSString).substring(to: boundedIndex) as NSString
        let width = prefix.size(withAttributes: textAttributes(color: textColor)).width
        let textWidth = (displayString as NSString).size(withAttributes: textAttributes(color: textColor)).width
        return textDrawOriginX(textWidth: textWidth) + width
    }

    func insertionIndex(for point: NSPoint) -> Int {
        let string = displayString as NSString
        let length = string.length
        guard length > 0 else { return 0 }

        let attributes = textAttributes(color: textColor)
        let textWidth = string.size(withAttributes: attributes).width
        let originX = textDrawOriginX(textWidth: textWidth)
        if point.x <= originX {
            return 0
        }
        if point.x >= originX + textWidth {
            return length
        }

        var low = 0
        var high = length
        while low < high {
            let mid = (low + high) / 2
            let prefixWidth = string.substring(to: mid) as NSString
            if originX + prefixWidth.size(withAttributes: attributes).width < point.x {
                low = mid + 1
            } else {
                high = mid
            }
        }

        let previous = max(0, low - 1)
        let previousX = originX + (string.substring(to: previous) as NSString).size(withAttributes: attributes).width
        let currentX = originX + (string.substring(to: low) as NSString).size(withAttributes: attributes).width
        return abs(point.x - previousX) < abs(currentX - point.x) ? previous : low
    }

    func containsText(at point: NSPoint) -> Bool {
        guard !displayString.isEmpty else { return false }
        let string = displayString as NSString
        let textSize = string.size(withAttributes: textAttributes(color: textColor))
        let textBounds = NSRect(
            x: textDrawOriginX(textWidth: textSize.width),
            y: max(0, (bounds.height - textSize.height) / 2),
            width: min(textSize.width, textRect.width),
            height: textSize.height
        ).insetBy(dx: -3, dy: -5)
        return textBounds.contains(point)
    }

    private func textAttributes(color: NSColor) -> [NSAttributedString.Key: Any] {
        let paragraph = NSMutableParagraphStyle()
        paragraph.alignment = alignment
        paragraph.lineBreakMode = .byTruncatingTail
        return [
            .font: font,
            .foregroundColor: color,
            .paragraphStyle: paragraph
        ]
    }

    private func textDrawRect(textWidth: CGFloat, textHeight: CGFloat) -> NSRect {
        NSRect(
            x: textRect.minX,
            y: max(0, (bounds.height - textHeight) / 2),
            width: textRect.width,
            height: textHeight
        )
    }

    private func textDrawOriginX(textWidth: CGFloat) -> CGFloat {
        switch alignment {
        case .right:
            return textWidth < textRect.width ? textRect.maxX - textWidth : textRect.minX
        case .center:
            return textRect.minX + max(0, (textRect.width - textWidth) / 2)
        default:
            return textRect.minX
        }
    }
}

final class DataCellButton: NSButton {
    weak var mouseHandler: DataCellMouseHandling?
    var visibleRow = 0
    var documentRow = 0
    var columnIndex = 0
    var rawValue = ""

    override func mouseDown(with event: NSEvent) {
        if mouseHandler?.dataCellControlShouldHandleMouseDown(visibleRow: visibleRow, columnIndex: columnIndex, event: event) == true {
            super.mouseDown(with: event)
        }
    }
}

/// Display-only cell for select/multiSelect/status: draws Notion-style colored, rounded
/// "pill" tags. Self-drawn because AppKit has no native colored-tag control, and the
/// native alternatives (NSPopUpButton/NSTokenField) dim in read-only mode and can't be
/// cleanly colored. Editing is delegated to native pickers via the mouse handler; this
/// view only renders. Colors come from appearance-adaptive NSColor.system* values.
final class PillCellView: NSView {
    var visibleRow = 0
    var documentRow = 0
    var columnIndex = 0
    var rawValue = ""
    var tokens: [(text: String, color: NSColor)] = [] { didSet { needsDisplay = true } }
    var selectionFill: NSColor? { didSet { needsDisplay = true } }

    private static let pillFont = NSFont.systemFont(ofSize: 12)
    private static let pillHeight: CGFloat = 18

    override var isFlipped: Bool { true }
    override var acceptsFirstResponder: Bool { false }

    override func draw(_ dirtyRect: NSRect) {
        if let selectionFill {
            selectionFill.setFill()
            NSBezierPath(rect: bounds).fill()
        }
        let height = Self.pillHeight
        let top = (bounds.height - height) / 2
        var x: CGFloat = 8
        let paragraph = NSMutableParagraphStyle()
        paragraph.lineBreakMode = .byTruncatingTail
        for token in tokens {
            guard x < bounds.width - 12 else { break }
            // Blend toward labelColor at 0.7 so the text reads clearly on the tinted
            // fill in both light and dark mode while still showing the tag color.
            let textColor = token.color.blended(withFraction: 0.7, of: .labelColor) ?? token.color
            let attributes: [NSAttributedString.Key: Any] = [.font: Self.pillFont, .foregroundColor: textColor, .paragraphStyle: paragraph]
            let text = token.text as NSString
            let textSize = text.size(withAttributes: attributes)
            let pillWidth = min(textSize.width, bounds.width - x - 12) + 14
            let pillRect = NSRect(x: x, y: top, width: pillWidth, height: height)
            let path = NSBezierPath(roundedRect: pillRect, xRadius: 3, yRadius: 3)
            token.color.withAlphaComponent(0.16).setFill()
            path.fill()
            let textRect = NSRect(x: x + 7, y: top + (height - textSize.height) / 2, width: pillWidth - 12, height: textSize.height)
            text.draw(in: textRect, withAttributes: attributes)
            x += pillWidth + 4
        }
    }

    // Pass mouse events through to the table view so cell selection and drag-select work
    // uniformly; the picker opens via the activation path (double-click / Enter).
    override func hitTest(_ point: NSPoint) -> NSView? { nil }
}

/// Display-only cell for url-typed columns: renders the link as plain text (no button
/// chrome) with the host in label color and the path/query dimmed, both underlined and
/// the path middle-truncated. Opens via the activation path (double-click / Enter), and
/// passes mouse events through so selection and drag-select work uniformly.
final class URLCellView: NSView {
    var documentRow = 0
    var columnIndex = 0
    var rawValue = "" { didSet { needsDisplay = true } }
    var selectionFill: NSColor? { didSet { needsDisplay = true } }

    override var isFlipped: Bool { true }
    override var acceptsFirstResponder: Bool { false }
    override func hitTest(_ point: NSPoint) -> NSView? { nil }

    override func draw(_ dirtyRect: NSRect) {
        if let selectionFill {
            selectionFill.setFill()
            NSBezierPath(rect: bounds).fill()
        }
        let (host, rest) = URLCellView.split(rawValue)
        guard !host.isEmpty || !rest.isEmpty else { return }
        let font = NSFont.systemFont(ofSize: 13)
        let inset = bounds.insetBy(dx: 8, dy: 0)

        let hostParagraph = NSMutableParagraphStyle()
        hostParagraph.lineBreakMode = .byTruncatingTail
        let hostAttrs: [NSAttributedString.Key: Any] = [
            .font: font,
            .foregroundColor: NSColor.labelColor,
            .underlineStyle: NSUnderlineStyle.single.rawValue,
            .underlineColor: NSColor.tertiaryLabelColor,
            .paragraphStyle: hostParagraph
        ]
        let hostSize = (host as NSString).size(withAttributes: hostAttrs)
        let textHeight = hostSize.height
        let y = max(0, (bounds.height - textHeight) / 2)
        let hostWidth = min(hostSize.width, inset.width)
        (host as NSString).draw(in: NSRect(x: inset.minX, y: y, width: hostWidth, height: textHeight), withAttributes: hostAttrs)

        let restX = inset.minX + hostSize.width
        if !rest.isEmpty, restX < inset.maxX {
            let restParagraph = NSMutableParagraphStyle()
            restParagraph.lineBreakMode = .byTruncatingMiddle
            let restAttrs: [NSAttributedString.Key: Any] = [
                .font: font,
                .foregroundColor: NSColor.secondaryLabelColor,
                .underlineStyle: NSUnderlineStyle.single.rawValue,
                .underlineColor: NSColor.tertiaryLabelColor,
                .paragraphStyle: restParagraph
            ]
            (rest as NSString).draw(in: NSRect(x: restX, y: y, width: inset.maxX - restX, height: textHeight), withAttributes: restAttrs)
        }
    }

    /// Splits a URL into (host, path+query) for display, dropping the scheme and a leading
    /// "www." — e.g. https://www.foo.com/bar?x → ("foo.com", "/bar?x").
    static func split(_ raw: String) -> (host: String, rest: String) {
        var string = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        if let schemeRange = string.range(of: "://") {
            string = String(string[schemeRange.upperBound...])
        }
        if string.lowercased().hasPrefix("www.") {
            string = String(string.dropFirst(4))
        }
        if let slash = string.firstIndex(of: "/") {
            return (String(string[..<slash]), String(string[slash...]))
        }
        return (string, "")
    }
}

/// A cell view whose value can be edited in the shared inline text editor. The editor
/// anchors to the view's frame, opens with `editingString`, and writes the result back
/// through documentRow/columnIndex on commit.
protocol InlineEditableCellView: NSView {
    var documentRow: Int { get }
    var columnIndex: Int { get }
    var rawValue: String { get }
    /// The text the editor opens with (what the user sees and edits).
    var editingString: String { get }
    var font: NSFont { get }
    var alignment: NSTextAlignment { get }
    /// UTF-16 caret index in `editingString` for an activation click at `point`
    /// (in the cell's coordinate space).
    func insertionIndex(for point: NSPoint) -> Int
}

extension DataTextCellView: InlineEditableCellView {
    var editingString: String { displayString }
}

extension URLCellView: InlineEditableCellView {
    var editingString: String { rawValue }
    var font: NSFont { .systemFont(ofSize: 13) }
    var alignment: NSTextAlignment { .left }
    // The rendered text (scheme/www stripped) doesn't map 1:1 onto the raw URL, so a
    // click position can't be translated; put the caret at the end instead.
    func insertionIndex(for point: NSPoint) -> Int {
        (rawValue as NSString).length
    }
}

final class ColumnTypeMenuItem: NSMenuItem {
    var columnIndex = 0
    var columnType = ColumnType.text
}

final class ColumnMenuItem: NSMenuItem {
    var columnIndex = 0
}

/// Menu item carrying the context to set a single-select cell's value.
final class TagMenuItem: NSMenuItem {
    var documentRow = 0
    var columnIndex = 0
    var optionName = ""
}

/// Menu item carrying the context to recolor a tag option.
final class TagColorMenuItem: NSMenuItem {
    var columnIndex = 0
    var optionName = ""
    var colorName = ""
}

/// Checkbox in the multi-select popover, carrying its option name.
final class MultiTagCheckbox: NSButton {
    var optionName = ""
}

private enum TableSelectionMode {
    case cells
    case rows
    case columns
    case all
}

private struct TableSelectionRange {
    var mode = TableSelectionMode.cells
    var rows = IndexSet()
    var columns = IndexSet()

    var isEmpty: Bool {
        rows.isEmpty || columns.isEmpty
    }
}

protocol DataTableSelectionHandling: AnyObject {
    func selectCellRange(from start: (row: Int, column: Int), to end: (row: Int, column: Int))
    func selectRowRange(from startRow: Int, to endRow: Int)
    func selectColumnRange(from startColumn: Int, to endColumn: Int)
    func beginTextSelection(in cell: DataTextCellView, anchorEvent: NSEvent, firstDragEvent: NSEvent)
    func activateSelectedCellTextInteraction(initialText: String?, activationEvent: NSEvent?)
    func editSelectedCell(initialText: String?)
    func openLink(atVisibleRow row: Int, visibleColumn column: Int) -> Bool
    func moveSelectedCell(rowDelta: Int, columnDelta: Int)
    func endActiveCellTextInteraction(commit: Bool)
    func clearSelection()
    func canReorderRows() -> Bool
    func showRowDropIndicator(atVisibleIndex index: Int)
    func hideRowDropIndicator()
    func moveSelectedRows(toVisibleIndex index: Int)
}

protocol InlineCellEditorHandling: AnyObject {
    func inlineCellEditorDidCommit(_ editor: InlineCellEditor)
    func inlineCellEditorDidCancel(_ editor: InlineCellEditor)
}

final class InlineCellEditor: NSTextView {
    weak var editHandler: InlineCellEditorHandling?
    var commitsChanges = false

    override var acceptsFirstResponder: Bool { true }

    override func cancelOperation(_ sender: Any?) {
        editHandler?.inlineCellEditorDidCancel(self)
    }

    override func keyDown(with event: NSEvent) {
        if event.modifierFlags.intersection([.command, .control, .option]).isEmpty {
            if event.keyCode == 36 || event.keyCode == 76 {
                editHandler?.inlineCellEditorDidCommit(self)
                return
            }
            if event.keyCode == 53 {
                editHandler?.inlineCellEditorDidCancel(self)
                return
            }
        }
        super.keyDown(with: event)
    }
}

final class SelectionOverlayView: NSView {
    weak var tableView: NSTableView?
    fileprivate var selectionRange = TableSelectionRange() {
        didSet {
            needsDisplay = true
        }
    }

    override var isFlipped: Bool { true }

    override func hitTest(_ point: NSPoint) -> NSView? {
        nil
    }

    override func draw(_ dirtyRect: NSRect) {
        super.draw(dirtyRect)
        guard let tableView else { return }

        guard selectionRange.mode == .cells,
              !selectionRange.isEmpty,
              let firstRow = selectionRange.rows.min(),
              let lastRow = selectionRange.rows.max(),
              let firstColumn = selectionRange.columns.min(),
              let lastColumn = selectionRange.columns.max(),
              firstRow >= 0,
              lastRow < tableView.numberOfRows,
              firstColumn >= 0,
              lastColumn < tableView.numberOfColumns else {
            return
        }

        let rowRect = tableView.rect(ofRow: firstRow).union(tableView.rect(ofRow: lastRow))
        let columnRect = tableView.rect(ofColumn: firstColumn).union(tableView.rect(ofColumn: lastColumn))
        let tableRect = rowRect.intersection(columnRect)
        guard !tableRect.isNull, !tableRect.isEmpty else { return }

        let overlayRect = tableView.convert(tableRect, to: self).insetBy(dx: 1, dy: 1)
        let path = NSBezierPath(rect: overlayRect)
        path.lineWidth = 2
        NSColor.controlAccentColor.setStroke()
        path.stroke()
    }
}

final class CellTextSelectionOverlay: NSView {
    private let cellView: DataTextCellView
    private(set) var selectedRange = NSRange(location: 0, length: 0) {
        didSet { needsDisplay = true }
    }

    var selectedText: String? {
        guard selectedRange.length > 0,
              let range = Range(selectedRange, in: cellView.displayString) else {
            return nil
        }
        return String(cellView.displayString[range])
    }

    init(cellView: DataTextCellView, frame: NSRect) {
        self.cellView = cellView
        super.init(frame: frame)
        wantsLayer = false
    }

    required init?(coder: NSCoder) {
        nil
    }

    override var isFlipped: Bool { true }
    override var acceptsFirstResponder: Bool { false }

    override func hitTest(_ point: NSPoint) -> NSView? {
        nil
    }

    override func draw(_ dirtyRect: NSRect) {
        super.draw(dirtyRect)
        guard selectedRange.length > 0 else {
            cellView.drawDisplayString(color: cellView.textColor, clippedTo: nil)
            return
        }

        let lowerX = cellView.xPosition(forUTF16Index: selectedRange.location)
        let upperX = cellView.xPosition(forUTF16Index: selectedRange.location + selectedRange.length)
        let selectionRect = NSRect(
            x: max(0, min(lowerX, upperX)),
            y: max(2, (bounds.height - cellView.font.boundingRectForFont.height) / 2 - 2),
            width: min(bounds.width, abs(upperX - lowerX)),
            height: min(bounds.height - 4, cellView.font.boundingRectForFont.height + 4)
        )

        NSColor.selectedTextBackgroundColor.setFill()
        NSBezierPath(roundedRect: selectionRect, xRadius: 3, yRadius: 3).fill()
        cellView.drawDisplayString(color: cellView.textColor, clippedTo: nil)
        cellView.drawDisplayString(color: .selectedTextColor, clippedTo: selectionRect)
    }

    func beginSelection(anchorEvent: NSEvent, firstDragEvent: NSEvent) {
        guard let window else { return }
        let anchor = insertionIndex(for: anchorEvent)
        selectedRange = range(from: anchor, to: insertionIndex(for: firstDragEvent))

        while true {
            guard let nextEvent = window.nextEvent(matching: [.leftMouseDragged, .leftMouseUp]) else {
                break
            }
            selectedRange = range(from: anchor, to: insertionIndex(for: nextEvent))
            if nextEvent.type == .leftMouseUp {
                break
            }
        }
    }

    private func insertionIndex(for event: NSEvent) -> Int {
        let point = convert(event.locationInWindow, from: nil)
        return cellView.insertionIndex(for: point)
    }

    private func range(from anchor: Int, to current: Int) -> NSRange {
        let lower = min(anchor, current)
        let upper = max(anchor, current)
        return NSRange(location: lower, length: upper - lower)
    }
}

final class DataTableView: NSTableView {
    weak var selectionHandler: DataTableSelectionHandling?
    private var dragStartCell: (row: Int, column: Int)?
    private var dragStartRow: Int?

    override var acceptsFirstResponder: Bool { true }

    override func mouseDown(with event: NSEvent) {
        let point = convert(event.locationInWindow, from: nil)
        let row = self.row(at: point)
        let column = self.column(at: point)
        guard row >= 0, column >= 0 else {
            // Click in the empty area (below rows / right of the last column) clears
            // the current selection.
            selectionHandler?.endActiveCellTextInteraction(commit: true)
            selectionHandler?.clearSelection()
            window?.makeFirstResponder(self)
            super.mouseDown(with: event)
            return
        }

        if tableColumns[column].identifier.rawValue == "rowNumber" {
            selectionHandler?.selectRowRange(from: row, to: row)
            if selectionHandler?.canReorderRows() == true {
                trackRowReorderDrag(from: row, initialEvent: event)
            } else {
                dragStartRow = row
                trackSelectionDrag(kind: .rows)
            }
        } else {
            selectionHandler?.selectCellRange(from: (row, column), to: (row, column))
            // Cmd+click on a URL-typed cell (Types On) opens the link instead of
            // starting a drag/edit interaction.
            if event.modifierFlags.contains(.command),
               selectionHandler?.openLink(atVisibleRow: row, visibleColumn: column) == true {
                return
            }
            if event.clickCount >= 2 {
                DispatchQueue.main.async { [weak self] in
                    self?.selectionHandler?.activateSelectedCellTextInteraction(initialText: nil, activationEvent: event)
                }
                return
            }
            trackDataCellMouseDown(event, start: (row, column))
        }
    }

    // NSTableView draws vertical grid lines between columns but not on the trailing
    // edge of the last column; add it so the rightmost column has the same divider.

    override func keyDown(with event: NSEvent) {
        let modifierMask = event.modifierFlags.intersection([.command, .control, .option])
        if modifierMask.isEmpty,
           event.keyCode == 36 || event.keyCode == 76 {
            selectionHandler?.editSelectedCell(initialText: nil)
            return
        }

        if modifierMask.isEmpty {
            switch event.keyCode {
            case 123: selectionHandler?.moveSelectedCell(rowDelta: 0, columnDelta: -1); return
            case 124: selectionHandler?.moveSelectedCell(rowDelta: 0, columnDelta: 1); return
            case 125: selectionHandler?.moveSelectedCell(rowDelta: 1, columnDelta: 0); return
            case 126: selectionHandler?.moveSelectedCell(rowDelta: -1, columnDelta: 0); return
            default: break
            }
        }

        if modifierMask.isEmpty,
           let text = event.charactersIgnoringModifiers,
           text.count == 1,
           text.unicodeScalars.allSatisfy({ $0.value >= 32 && $0.value != 127 }) {
            selectionHandler?.editSelectedCell(initialText: text)
            return
        }

        super.keyDown(with: event)
    }

    func trackCellSelectionDrag(from start: (row: Int, column: Int)) {
        dragStartCell = start
        trackSelectionDrag(kind: .cells)
    }

    private func trackRowReorderDrag(from startRow: Int, initialEvent: NSEvent) {
        guard let window else { return }
        let startPoint = initialEvent.locationInWindow
        var dragging = false

        while true {
            guard let event = window.nextEvent(matching: [.leftMouseDragged, .leftMouseUp]) else { break }
            if event.type == .leftMouseUp {
                if dragging {
                    selectionHandler?.moveSelectedRows(toVisibleIndex: rowDropIndex(for: event))
                }
                break
            }
            let distance = hypot(event.locationInWindow.x - startPoint.x, event.locationInWindow.y - startPoint.y)
            if !dragging, distance < 4 { continue }
            dragging = true
            selectionHandler?.showRowDropIndicator(atVisibleIndex: rowDropIndex(for: event))
        }
        selectionHandler?.hideRowDropIndicator()
    }

    private func rowDropIndex(for event: NSEvent) -> Int {
        let point = convert(event.locationInWindow, from: nil)
        let r = row(at: point)
        guard r >= 0 else {
            return point.y <= 0 ? 0 : numberOfRows
        }
        let rect = rect(ofRow: r)
        return point.y < rect.midY ? r : r + 1
    }

    func trackRowSelectionDrag(from startRow: Int) {
        dragStartRow = startRow
        trackSelectionDrag(kind: .rows)
    }

    private func trackDataCellMouseDown(_ event: NSEvent, start: (row: Int, column: Int)) {
        guard let window else { return }
        let textCell = view(atColumn: start.column, row: start.row, makeIfNecessary: false) as? DataTextCellView
        let startsOnText: Bool
        if let textCell {
            startsOnText = textCell.containsText(at: textCell.convert(event.locationInWindow, from: nil))
        } else {
            startsOnText = false
        }
        let startPoint = event.locationInWindow

        while true {
            guard let nextEvent = window.nextEvent(matching: [.leftMouseDragged, .leftMouseUp]) else { return }
            if nextEvent.type == .leftMouseUp {
                return
            }

            let distance = hypot(nextEvent.locationInWindow.x - startPoint.x, nextEvent.locationInWindow.y - startPoint.y)
            guard distance >= 3 else { continue }

            if startsOnText, let textCell {
                selectionHandler?.beginTextSelection(in: textCell, anchorEvent: event, firstDragEvent: nextEvent)
                return
            }

            dragStartCell = start
            handleSelectionDragEvent(kind: .cells, event: nextEvent)
            trackSelectionDrag(kind: .cells)
            return
        }
    }

    private func trackSelectionDrag(kind: TableSelectionMode) {
        guard let window else { return }
        while true {
            guard let event = window.nextEvent(matching: [.leftMouseDragged, .leftMouseUp]) else { return }
            if event.type == .leftMouseUp {
                break
            }
            handleSelectionDragEvent(kind: kind, event: event)
        }
        dragStartCell = nil
        dragStartRow = nil
    }

    private func handleSelectionDragEvent(kind: TableSelectionMode, event: NSEvent) {
        let point = convert(event.locationInWindow, from: nil)
        let row = self.row(at: point)
        let column = self.column(at: point)

        switch kind {
        case .cells:
            guard let dragStartCell,
                  row >= 0,
                  column >= 0,
                  tableColumns.indices.contains(column),
                  tableColumns[column].identifier.rawValue != "rowNumber" else { return }
            selectionHandler?.selectCellRange(from: dragStartCell, to: (row, column))
        case .rows:
            guard let dragStartRow, row >= 0 else { return }
            selectionHandler?.selectRowRange(from: dragStartRow, to: row)
        case .columns, .all:
            break
        }
    }

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

final class CornerSelectButton: NSView {
    var onClick: (() -> Void)?

    override func mouseDown(with event: NSEvent) {
        onClick?()
    }
}

final class SelectableHeaderCell: NSTableHeaderCell {
    var isHighlightedColumn = false
    // The real column rect (in column x-space). The last header cell gets stretched
    // to fill trailing space, so we clip the highlight to the actual column rect to
    // match the body tint and avoid bleeding past the column.
    var highlightColumnRect: NSRect = .zero

    override func draw(withFrame cellFrame: NSRect, in controlView: NSView) {
        guard isHighlightedColumn else {
            super.draw(withFrame: cellFrame, in: controlView)
            return
        }
        let frame: NSRect
        if highlightColumnRect.width > 0 {
            let clip = NSRect(x: highlightColumnRect.minX, y: cellFrame.minY,
                              width: highlightColumnRect.width, height: cellFrame.height)
            frame = cellFrame.intersection(clip)
        } else {
            frame = cellFrame
        }
        guard !frame.isEmpty else { return }

        NSColor.controlAccentColor.setFill()
        frame.fill()

        let style = NSMutableParagraphStyle()
        style.alignment = alignment
        style.lineBreakMode = .byTruncatingTail
        let attrs: [NSAttributedString.Key: Any] = [
            .font: font ?? NSFont.systemFont(ofSize: NSFont.smallSystemFontSize),
            .foregroundColor: NSColor.white,
            .paragraphStyle: style
        ]
        let title = stringValue as NSString
        let size = title.size(withAttributes: attrs)
        let textRect = frame.insetBy(dx: 6, dy: 0)
        let drawRect = NSRect(x: textRect.minX, y: frame.midY - size.height / 2, width: textRect.width, height: size.height)
        title.draw(in: drawRect, withAttributes: attrs)
    }
}

final class DataTableHeaderView: NSTableHeaderView {
    weak var columnActionHandler: MainWindowController?
    weak var selectionHandler: DataTableSelectionHandling?
    var highlightedColumns = IndexSet() {
        didSet { needsDisplay = true }
    }
    var activeSortColumn: Int?
    var activeSortAscending = true

    override func menu(for event: NSEvent) -> NSMenu? {
        let point = convert(event.locationInWindow, from: nil)
        let column = column(at: point)
        columnActionHandler?.setContextColumnFromVisibleColumn(column)
        return columnActionHandler?.buildHeaderContextMenu(forVisibleColumn: column)
    }

    override func mouseDown(with event: NSEvent) {
        let point = convert(event.locationInWindow, from: nil)
        let column = self.column(at: point)
        guard column >= 0 else {
            trackingNativeHeaderDrag { super.mouseDown(with: event) }
            return
        }

        // The top-left "#" header is the row-number column: clicking it selects the whole table.
        if tableView?.tableColumns[column].identifier.rawValue == "rowNumber" {
            columnActionHandler?.selectAllCells()
            return
        }

        if sortButtonRect(forColumn: column).contains(point) {
            columnActionHandler?.toggleSort(forVisibleColumn: column)
            return
        }

        columnActionHandler?.clearSortForHeaderSelection()
        // Tint the column (header + body) immediately on press so it doesn't flash the
        // native gray pressed state and the body highlight follows the header right
        // away. This avoids first-responder / reload, so it won't cancel the native
        // column drag-reorder tracking that super.mouseDown runs.
        columnActionHandler?.previewColumnSelection(column)
        // Let NSTableHeaderView run its native click + column drag-reorder tracking
        // first (it blocks until mouse-up). Doing our own selection / first-responder
        // work before this previously cancelled the drag. Sync selection afterwards,
        // using the column reference so we follow it to its new position if reordered.
        let draggedColumn = tableView?.tableColumns[column]
        trackingNativeHeaderDrag { super.mouseDown(with: event) }
        if let draggedColumn, let newIndex = tableView?.tableColumns.firstIndex(of: draggedColumn) {
            selectionHandler?.selectColumnRange(from: newIndex, to: newIndex)
            // One drag = one undo step: the column ended at newIndex after starting at
            // `column`, so register an undo that moves it back (which itself registers redo).
            if newIndex != column {
                columnActionHandler?.registerColumnDragUndo(originalIndex: column, newIndex: newIndex)
            }
        }
    }

    /// NSTableHeaderView's native mouseDown blocks in a modal tracking loop for the whole
    /// column resize/reorder drag, and on this macOS no delegate callback or notification
    /// fires until mouse-up. A timer in .common run-loop modes still fires inside that
    /// tracking loop, so poll the controller from it to keep drag-dependent chrome (the
    /// trailing grid line) in sync live.
    private func trackingNativeHeaderDrag(_ body: () -> Void) {
        let timer = Timer(timeInterval: 1.0 / 60.0, repeats: true) { [weak self] _ in
            self?.columnActionHandler?.headerDragTick()
        }
        RunLoop.current.add(timer, forMode: .common)
        defer {
            timer.invalidate()
            columnActionHandler?.headerDragTick()
        }
        body()
    }

    override func draw(_ dirtyRect: NSRect) {
        if let tableView {
            for column in 0..<tableView.numberOfColumns {
                guard let cell = tableView.tableColumns[column].headerCell as? SelectableHeaderCell else { continue }
                cell.isHighlightedColumn = highlightedColumns.contains(column)
                cell.highlightColumnRect = tableView.rect(ofColumn: column)
            }
        }
        super.draw(dirtyRect)

        drawSortButtons()
    }

    private func sortButtonRect(forColumn column: Int) -> NSRect {
        let headerRect = headerRect(ofColumn: column)
        return NSRect(
            x: headerRect.maxX - 24,
            y: headerRect.minY,
            width: 22,
            height: headerRect.height
        ).insetBy(dx: 2, dy: 4)
    }

    private func drawSortButtons() {
        guard let tableView else { return }
        for column in 0..<tableView.numberOfColumns {
            guard tableView.tableColumns[column].identifier.rawValue != "rowNumber" else { continue }
            let buttonRect = sortButtonRect(forColumn: column)
            let isActive = activeSortColumn == column
            let onHighlighted = highlightedColumns.contains(column)
            let color = onHighlighted ? NSColor.white
                : (isActive ? NSColor.controlAccentColor : NSColor.tertiaryLabelColor)
            color.setFill()

            let centerX = buttonRect.midX
            let centerY = buttonRect.midY
            let path = NSBezierPath()
            if isActive && !activeSortAscending {
                path.move(to: NSPoint(x: centerX - 4, y: centerY - 2))
                path.line(to: NSPoint(x: centerX + 4, y: centerY - 2))
                path.line(to: NSPoint(x: centerX, y: centerY + 3))
            } else {
                path.move(to: NSPoint(x: centerX - 4, y: centerY + 2))
                path.line(to: NSPoint(x: centerX + 4, y: centerY + 2))
                path.line(to: NSPoint(x: centerX, y: centerY - 3))
            }
            path.close()
            path.fill()
        }
    }
}

final class MainWindowController: NSWindowController, NSTableViewDataSource, NSTableViewDelegate, NSTextFieldDelegate, NSTextViewDelegate, NSSearchFieldDelegate, NSWindowDelegate, NSToolbarDelegate, NSDraggingDestination, NSMenuDelegate, DataTableSelectionHandling, DataCellMouseHandling, InlineCellEditorHandling {
    var onClose: ((MainWindowController) -> Void)?
    var hasLoadedDocument: Bool {
        tableDocument != nil
    }

    private var tableDocument: TableDocument?
    private var visibleRows: [Int] = []
    private var activeFilter: TableFilter?
    private var metadata = ViewMetadata()
    private var schema = TableSchema()
    private var editLocked = true
    private var documentColumnOrderDirty = false
    private let documentUndoManager = UndoManager()
    /// Set while programmatically restoring sort from metadata to avoid double-undo
    /// registration or prematurely writing the restored sort back to metadata.
    private var suppressSortPersistence = false
    /// Debounces metadata writes during continuous column-width drags.
    private var metadataPersistWorkItem: DispatchWorkItem?

    private let rootView = DropView()
    private let tableView = DataTableView()
    private let scrollView = NSScrollView()
    private let selectionOverlayView = SelectionOverlayView()
    /// The vertical grid line after the last column, positioned by frame via
    /// updateTrailingGridLine(). During a column-resize drag no notification fires, so
    /// DataTableHeaderView polls headerDragTick() to keep it (and the selection overlay)
    /// tracking the live column geometry.
    private let trailingGridLine = NSView()
    private lazy var rowDropIndicator: NSView = {
        let view = NSView()
        view.wantsLayer = true
        view.layer?.backgroundColor = NSColor.controlAccentColor.cgColor
        view.isHidden = true
        return view
    }()
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
    private var selectionMode = TableSelectionMode.cells
    private var selectionRange = TableSelectionRange()
    private var activeTextSelectionView: CellTextSelectionOverlay?
    private weak var activeTextSelectionSource: DataTextCellView?
    private var activeCellEditor: InlineCellEditor?
    private weak var activeCellEditorSource: (any InlineEditableCellView)?
    private var didBuildInterface = false
    private var appearanceRefreshScheduled = false
    private var appearanceObservation: NSKeyValueObservation?
    private var titlebarClickMonitor: Any?
    private var fileWatchSource: DispatchSourceFileSystemObject?
    private var fileWatchDescriptor: CInt = -1
    private var isHandlingExternalChange = false
    private weak var saveAsPanel: NSSavePanel?
    private var saveAsFormats: [TableFileFormat] = []
    private var searchDebounceWorkItem: DispatchWorkItem?
    private let searchDebounceInterval: TimeInterval = 0.2
    /// Non-nil when the current document is served lazily (paged) from DuckDB
    /// instead of fully loaded into `tableDocument.rows`. Read-only.
    private var lazyController: LazyTableController?
    private var isLazy: Bool { lazyController != nil }

    convenience init() {
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 1180, height: 760),
            styleMask: [.titled, .closable, .miniaturizable, .resizable],
            backing: .buffered,
            defer: false
        )
        window.title = "LightData"
        window.minSize = NSSize(width: 860, height: 520)
        window.tabbingMode = .preferred
        window.tabbingIdentifier = "LightDataDocumentWindow"
        self.init(window: window)
        configureWindow()
        window.center()
    }

    override func windowDidLoad() {
        super.windowDidLoad()
        configureWindow()
    }

    deinit {
        if let titlebarClickMonitor {
            NSEvent.removeMonitor(titlebarClickMonitor)
        }
        stopWatchingFile()
        NotificationCenter.default.removeObserver(self)
    }

    func windowDidBecomeKey(_ notification: Notification) {
        checkForExternalChanges()
    }

    @objc private func appDidBecomeActive(_ notification: Notification) {
        checkForExternalChanges()
    }

    func open(url: URL) {
        do {
            removeActiveTextSelectionView()
            removeActiveCellEditor(commit: true)
            saveCurrentMetadata()
            tearDownLazyController()
            // Load view memory first so the remembered "first row is header" choice can
            // be applied at parse time.
            let savedMetadata = ViewMetadataStore.load(for: url)
            var loaded: TableDocument
            let ext = url.pathExtension.lowercased()
            if ext == "parquet" || ext == "pq" {
                loaded = try openLazyParquet(url: url)
            } else {
                loaded = try TableDocument.load(url: url, firstRowIsHeader: savedMetadata.hasHeaderRow ?? true)
            }
            // Headerless file with remembered custom column names: apply them (display only).
            if !loaded.hasHeaderRow,
               let names = savedMetadata.headerlessColumnNames,
               names.count == loaded.headers.count {
                loaded.headers = names
            }
            tableDocument = loaded
            editLocked = true
            documentColumnOrderDirty = false
            documentUndoManager.removeAllActions()
            metadata = savedMetadata
            schema = metadata.schemaEnabled ? SchemaMetadataStore.load(for: url, headers: loaded.headers, rows: loaded.rows) : TableSchema()
            activeFilter = nil
            searchDebounceWorkItem?.cancel()
            searchField.stringValue = ""
            filterValueField.stringValue = ""
            buildColumns()
            restoreSortFromMetadata(for: loaded)
            refreshFilterControls()
            refreshDelimiterControl()
            rebuildVisibleRows()
            updateStatus()
            updateToolbarState()
            window?.title = url.lastPathComponent
            window?.representedURL = url
            startWatchingFile(url)
            if isLazy {
                DispatchQueue.main.async { [weak self] in self?.updateLazyViewport() }
            }
        } catch {
            showError(error)
        }
    }

    /// Sets up the lazy/paged DuckDB controller for a Parquet file and returns a
    /// header-only document to drive the rest of the UI.
    private func openLazyParquet(url: URL) throws -> TableDocument {
        let source = try DuckDBTableSource(parquetURL: url)
        let controller = LazyTableController(source: source)
        controller.onRowCountChanged = { [weak self] _ in
            guard let self else { return }
            self.tableView.reloadData()
            self.updateStatus()
            self.updateLazyViewport()
        }
        controller.onRowsLoaded = { [weak self] rows in
            guard let self else { return }
            // Only reload the on-screen columns. Reloading all columns (e.g. 184 on a
            // wide file) rebuilds ~rows×184 cells per page load and freezes the UI;
            // off-screen columns aren't visible anyway and reload lazily when scrolled to.
            let visibleRows = self.tableView.rows(in: self.tableView.visibleRect)
            let visibleColumns = self.tableView.columnIndexes(in: self.tableView.visibleRect)
            let rowsToReload: IndexSet
            if visibleRows.length > 0 {
                let visibleSet = IndexSet(integersIn: visibleRows.location..<(visibleRows.location + visibleRows.length))
                rowsToReload = rows.intersection(visibleSet)
            } else {
                rowsToReload = []
            }
            guard !rowsToReload.isEmpty, !visibleColumns.isEmpty else { return }
            self.tableView.reloadData(forRowIndexes: rowsToReload, columnIndexes: visibleColumns)
        }
        lazyController = controller
        controller.start()
        return TableDocument.lazyHeaderOnly(url: url, format: .parquet, headers: source.headers, readOnlyReason: "Parquet read-only")
    }

    private func tearDownLazyController() {
        lazyController = nil
    }

    // MARK: - External file change detection

    /// Starts a live filesystem watch on the open file. Re-establishes the watch after
    /// atomic saves (write-temp-then-rename, which most editors use) by re-watching the
    /// path when the original fd reports rename/delete.
    private func startWatchingFile(_ url: URL) {
        stopWatchingFile()
        let fd = Darwin.open(url.path, O_EVTONLY)
        guard fd >= 0 else { return }
        let source = DispatchSource.makeFileSystemObjectSource(
            fileDescriptor: fd,
            eventMask: [.write, .extend, .rename, .delete, .attrib],
            queue: .main
        )
        source.setEventHandler { [weak self] in
            guard let self else { return }
            let flags = source.data
            if flags.contains(.rename) || flags.contains(.delete) {
                // The file was replaced/moved (atomic save); the fd is now stale.
                self.stopWatchingFile()
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.15) { [weak self] in
                    guard let self, let current = self.tableDocument?.url else { return }
                    self.startWatchingFile(current)
                    self.checkForExternalChanges()
                }
            } else {
                self.checkForExternalChanges()
            }
        }
        source.setCancelHandler { Darwin.close(fd) }
        fileWatchSource = source
        fileWatchDescriptor = fd
        source.resume()
    }

    private func stopWatchingFile() {
        fileWatchSource?.cancel()   // cancel handler closes the descriptor
        fileWatchSource = nil
        fileWatchDescriptor = -1
    }

    /// Compares the open file's on-disk modification date to the loaded one. If it
    /// changed: reload automatically when there are no unsaved edits, otherwise prompt.
    private func checkForExternalChanges() {
        guard !isHandlingExternalChange, let doc = tableDocument else { return }
        let url = doc.url
        let fm = FileManager.default
        guard fm.fileExists(atPath: url.path),
              let diskDate = (try? fm.attributesOfItem(atPath: url.path)[.modificationDate]) as? Date,
              let loadedDate = doc.loadedModificationDate,
              abs(diskDate.timeIntervalSince(loadedDate)) > 0.5 else { return }

        if doc.dirty {
            isHandlingExternalChange = true
            let alert = NSAlert()
            alert.messageText = "“\(url.lastPathComponent)” was changed by another program"
            alert.informativeText = "You have unsaved changes. Reload from disk (discarding your changes), or keep your version?"
            alert.addButton(withTitle: "Reload")
            alert.addButton(withTitle: "Keep Mine")
            let finish: (NSApplication.ModalResponse) -> Void = { [weak self] response in
                guard let self else { return }
                self.isHandlingExternalChange = false
                if response == .alertFirstButtonReturn {
                    self.open(url: url)
                } else {
                    // Keep mine: adopt the disk date so we stop prompting; a later Save
                    // will overwrite the external change.
                    self.tableDocument?.loadedModificationDate = diskDate
                }
            }
            if let window {
                alert.beginSheetModal(for: window, completionHandler: finish)
            } else {
                finish(alert.runModal())
            }
        } else {
            open(url: url)   // reloads from disk, restoring view memory
        }
    }

    /// Reports the currently visible block (rows × data columns) to the lazy
    /// controller so it fetches exactly what's on screen, as one coherent unit.
    private func updateLazyViewport() {
        guard let lazyController else { return }
        let rect = tableView.visibleRect
        let rowRange = tableView.rows(in: rect)
        let rows: Range<Int>
        if rowRange.length > 0 {
            rows = rowRange.location..<(rowRange.location + rowRange.length)
        } else {
            rows = 0..<min(lazyController.rowCount, 1)
        }

        let visibleColumns = tableView.columnIndexes(in: rect)
        var dataColumns: [Int] = []
        for visibleColumn in visibleColumns where tableView.tableColumns.indices.contains(visibleColumn) {
            if let index = Int(tableView.tableColumns[visibleColumn].identifier.rawValue) {
                dataColumns.append(index)
            }
        }
        lazyController.updateViewport(rows: rows, columns: dataColumns)
    }

    // MARK: - Mode-aware display access

    /// Number of rows the table view should show (filtered result count in lazy mode).
    private var displayRowCount: Int {
        isLazy ? (lazyController?.rowCount ?? 0) : visibleRows.count
    }

    /// Maps a visible row to its document row. In lazy mode rows map to themselves
    /// (DuckDB already returns the filtered/sorted result), without materialising an array.
    private func documentRow(forVisible visibleRow: Int) -> Int? {
        if isLazy {
            return (0..<displayRowCount).contains(visibleRow) ? visibleRow : nil
        }
        return visibleRows.indices.contains(visibleRow) ? visibleRows[visibleRow] : nil
    }

    /// Display string for a cell, regardless of backing. In lazy mode a not-yet-loaded
    /// page returns a placeholder while the page is fetched in the background.
    private func cellString(visibleRow: Int, columnIndex: Int) -> String {
        if isLazy {
            return lazyController?.value(row: visibleRow, column: columnIndex) ?? "…"
        }
        guard let tableDocument,
              let documentRow = documentRow(forVisible: visibleRow),
              tableDocument.rows.indices.contains(documentRow) else { return "" }
        let row = tableDocument.rows[documentRow]
        return columnIndex < row.count ? row[columnIndex] : ""
    }

    /// Builds a query spec from the current search/filter/sort UI state for lazy mode.
    private func currentQuerySpec() -> TableQuerySpec {
        // Lazy Parquet is browse-only: search, filter, and sort each require a
        // full-table scan/sort across every column, which on wide many-row files
        // balloons memory and randomly freezes the UI. So the spec stays identity
        // and the fast file_row_number paging path is always used.
        return TableQuerySpec()
    }

    /// After creating a new file, ensure it shows a few empty rows for editing even if
    /// the on-disk file round-tripped to zero rows (delimited readers drop empty rows).
    /// Treated as clean (not dirty) since the file was just created.
    func seedBlankRowsForNewFile() {
        guard var doc = tableDocument, !doc.readOnly else { return }
        let target = TableDocument.blankRowCount
        guard doc.rows.count < target else { return }
        while doc.rows.count < target {
            doc.rows.append(Array(repeating: "", count: doc.headers.count))
        }
        doc.dirty = false
        tableDocument = doc
        rebuildVisibleRows()
        updateStatus()
    }

    /// Bakes the active sort into the row order so Save persists it (edit mode only).
    /// Sorts ALL rows by the descriptor — filter/search are view-only and never drop
    /// rows from the saved file.
    private func bakeActiveSortIfNeeded(into doc: inout TableDocument) {
        guard isEditingEnabled, !doc.readOnly,
              let descriptor = tableView.sortDescriptors.first,
              descriptor.key != nil else { return }
        let order = TableQueryEngine.visibleRows(in: doc, search: "", filter: nil, sortDescriptor: descriptor)
        guard order.count == doc.rows.count, order != Array(doc.rows.indices) else { return }
        doc.rows = order.map { doc.rows[$0] }
    }

    func saveDocument() {
        guard var current = tableDocument else { return }
        do {
            bakeActiveSortIfNeeded(into: &current)
            if documentColumnOrderDirty,
               let order = currentVisibleDataColumnOrder(in: current),
               order != Array(current.headers.indices) {
                current.reorderColumns(to: order)
            }
            try current.save()
            tableDocument = current
            documentColumnOrderDirty = false
            metadata.columnOrder = current.headers
            buildColumns()
            refreshFilterControls()
            rebuildVisibleRows()
            saveCurrentMetadata()
            saveCurrentSchema()
            updateStatus()
            updateToolbarState()
        } catch {
            showError(error)
        }
    }

    /// "Save As": writes the current contents to a new file/format, then re-points this
    /// window at the new file (the original file is left untouched). Saving a read-only
    /// document (XLSX/Parquet) to an editable format is how it becomes editable.
    func saveDocumentAs() {
        guard var current = tableDocument, let window else { return }
        removeActiveTextSelectionView()
        removeActiveCellEditor(commit: true)

        // Apply any pending visual column reorder so the written file matches what's shown.
        if documentColumnOrderDirty,
           let order = currentVisibleDataColumnOrder(in: current),
           order != Array(current.headers.indices) {
            current.reorderColumns(to: order)
        }

        let formats = TableFileFormat.writableFormats
        let defaultFormat = formats.contains(current.format) ? current.format : .csv

        let popup = NSPopUpButton(frame: NSRect(x: 80, y: 11, width: 220, height: 25))
        for format in formats {
            popup.addItem(withTitle: "\(format.displayName) (.\(format.fileExtension))")
        }
        popup.selectItem(at: formats.firstIndex(of: defaultFormat) ?? 0)
        popup.target = self
        popup.action = #selector(saveAsFormatChanged(_:))

        let label = NSTextField(labelWithString: "Format:")
        label.frame = NSRect(x: 16, y: 14, width: 60, height: 22)
        let accessory = NSView(frame: NSRect(x: 0, y: 0, width: 320, height: 50))
        accessory.addSubview(label)
        accessory.addSubview(popup)

        let panel = NSSavePanel()
        panel.canCreateDirectories = true
        panel.title = "Save As"
        panel.accessoryView = accessory
        panel.allowedContentTypes = [utType(for: defaultFormat)]
        panel.nameFieldStringValue = "\(current.url.deletingPathExtension().lastPathComponent).\(defaultFormat.fileExtension)"

        saveAsPanel = panel
        saveAsFormats = formats

        panel.beginSheetModal(for: window) { [weak self] response in
            guard let self else { return }
            self.saveAsPanel = nil
            guard response == .OK, var targetURL = panel.url else { return }
            let format = formats[popup.indexOfSelectedItem]
            if targetURL.pathExtension.lowercased() != format.fileExtension {
                targetURL.deletePathExtension()
                targetURL.appendPathExtension(format.fileExtension)
            }
            do {
                try current.write(to: targetURL, as: format)
                self.open(url: targetURL)
                NSDocumentController.shared.noteNewRecentDocumentURL(targetURL)
            } catch {
                self.showError(error)
            }
        }
    }

    @objc private func saveAsFormatChanged(_ sender: NSPopUpButton) {
        guard let panel = saveAsPanel,
              saveAsFormats.indices.contains(sender.indexOfSelectedItem) else { return }
        let format = saveAsFormats[sender.indexOfSelectedItem]
        panel.allowedContentTypes = [utType(for: format)]
        let base = (panel.nameFieldStringValue as NSString).deletingPathExtension
        panel.nameFieldStringValue = "\(base).\(format.fileExtension)"
    }

    private func utType(for format: TableFileFormat) -> UTType {
        switch format {
        case .csv: return .commaSeparatedText
        case .tsv: return UTType(filenameExtension: "tsv") ?? .tabSeparatedText
        case .json: return .json
        case .jsonl: return UTType(filenameExtension: "jsonl") ?? .text
        case .xlsx: return UTType(filenameExtension: "xlsx") ?? .data
        case .xls: return UTType(filenameExtension: "xls") ?? .data
        case .parquet: return UTType(filenameExtension: "parquet") ?? .data
        }
    }

    func numberOfRows(in tableView: NSTableView) -> Int {
        displayRowCount
    }

    func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
        guard let tableColumn,
              let tableDocument,
              let documentRow = documentRow(forVisible: row) else {
            return nil
        }
        let visibleColumn = tableView.tableColumns.firstIndex { $0 === tableColumn } ?? -1

        if tableColumn.identifier.rawValue == "rowNumber" {
            let id = NSUserInterfaceItemIdentifier("RowNumberCell")
            let cell = tableView.makeView(withIdentifier: id, owner: self) as? NSTableCellView ?? makeCellView(identifier: id)
            cell.textField?.stringValue = String(documentRow + 1)
            cell.textField?.isEditable = false
            cell.textField?.isSelectable = false
            cell.textField?.alignment = .center
            cell.textField?.textColor = .secondaryLabelColor
            if let textField = cell.textField as? DataCellTextField {
                textField.mouseHandler = self
                textField.visibleRow = row
                textField.columnIndex = -1
                textField.documentRow = documentRow
                textField.rawValue = cell.textField?.stringValue ?? ""
            }
            applySelectionStyle(to: cell, visibleRow: row, visibleColumn: visibleColumn)
            return cell
        }

        guard let columnIndex = Int(tableColumn.identifier.rawValue) else {
            return nil
        }

        let value = cellString(visibleRow: row, columnIndex: columnIndex)
        // Lazy (Parquet) rows are plain read-only text; schema cell types apply only
        // to the in-memory editable path.
        let columnSchema = (!isLazy && metadata.schemaEnabled) ? schema.schema(for: tableDocument.headers[columnIndex]) : ColumnSchema(type: .text)
        // Graceful degradation: a cell whose value doesn't conform to its column's
        // format type renders as plain text rather than a broken widget (the safety
        // net behind the assignment gate and input enforcement).
        let degraded = columnSchema.type.isFormatType && !ColumnTypeValidator.matches(value, type: columnSchema.type)
        let effectiveType: ColumnType = degraded ? .text : columnSchema.type

        switch effectiveType {
        case .checkbox:
            return checkboxCell(value: value, schema: columnSchema, visibleRow: row, documentRow: documentRow, columnIndex: columnIndex)
        case .select, .status:
            return pillCell(value: value, schema: columnSchema, visibleRow: row, documentRow: documentRow, columnIndex: columnIndex, multi: false)
        case .multiSelect:
            return pillCell(value: value, schema: columnSchema, visibleRow: row, documentRow: documentRow, columnIndex: columnIndex, multi: true)
        case .url:
            return urlCell(value: value, visibleRow: row, documentRow: documentRow, columnIndex: columnIndex)
        default:
            let id = NSUserInterfaceItemIdentifier("DataCell")
            let cell = tableView.makeView(withIdentifier: id, owner: self) as? DataTextCellView ?? makeDataTextCell(identifier: id)
            configure(textCell: cell, value: value, schema: degraded ? ColumnSchema(type: .text) : columnSchema)
            cell.visibleRow = row
            cell.documentRow = documentRow
            cell.columnIndex = columnIndex
            cell.rawValue = value
            cell.selectionFill = isBodyCell(visibleRow: row, visibleColumn: visibleColumn)
                ? NSColor.controlAccentColor.withAlphaComponent(0.10) : nil
            return cell
        }
    }

    func tableView(_ tableView: NSTableView, sortDescriptorsDidChange oldDescriptors: [NSSortDescriptor]) {
        // Sort is a view operation; make it ⌘Z-undoable by restoring the previous
        // descriptors. The restore re-fires this delegate, which registers the redo.
        if !suppressSortPersistence, tableView.sortDescriptors != oldDescriptors {
            documentUndoManager.registerUndo(withTarget: self) { target in
                target.tableView.sortDescriptors = oldDescriptors
            }
            documentUndoManager.setActionName("Sort")
        }
        rebuildVisibleRows()
        if !suppressSortPersistence {
            persistViewMetadata()
        }
        // In edit mode an active sort will be baked into the file on save, so mark the
        // document dirty to enable Save. (Read-only sort is view-only, never saved.)
        if isEditingEnabled, !tableView.sortDescriptors.isEmpty {
            tableDocument?.dirty = true
            updateStatus()
            updateToolbarState()
        }
    }

    func tableViewColumnDidResize(_ notification: Notification) {
        updateActiveCellEditorFrame()
        updateTrailingGridLine()
        selectionOverlayView.needsDisplay = true   // selection rect position may change
        // Live resize fires this many times per drag; debounce the disk write.
        captureMetadata()
        metadataPersistWorkItem?.cancel()
        let work = DispatchWorkItem { [weak self] in self?.persistViewMetadata() }
        metadataPersistWorkItem = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.3, execute: work)
    }

    func tableViewColumnDidMove(_ notification: Notification) {
        removeActiveCellEditor(commit: true)
        captureMetadata()
        if isEditingEnabled,
           let current = tableDocument,
           let order = currentVisibleDataColumnOrder(in: current) {
            documentColumnOrderDirty = (order != Array(current.headers.indices))
            if documentColumnOrderDirty {
                tableDocument?.dirty = true
            }
        }
        refreshVisibleSelectionAppearance()
        updateHeaderSortState()
        updateStatus()
        updateToolbarState()
        persistViewMetadata()
    }

    /// Registers undo for a completed column drag (column went `originalIndex` →
    /// `newIndex`). Undo moves it back; that move re-registers the redo, so the whole
    /// drag is a single ⌘Z — consistent with row reordering.
    func registerColumnDragUndo(originalIndex: Int, newIndex: Int) {
        documentUndoManager.registerUndo(withTarget: self) { target in
            target.performColumnMove(from: newIndex, to: originalIndex)
        }
        documentUndoManager.setActionName("Move Column")
    }

    private func performColumnMove(from: Int, to: Int) {
        guard tableView.tableColumns.indices.contains(from),
              tableView.tableColumns.indices.contains(to) else { return }
        removeActiveCellEditor(commit: true)
        // Visual move; tableViewColumnDidMove updates the dirty/order state. Saving
        // later applies the order to the file (same as a manual drag).
        tableView.moveColumn(from, toColumn: to)
        documentUndoManager.registerUndo(withTarget: self) { target in
            target.performColumnMove(from: to, to: from)
        }
        documentUndoManager.setActionName("Move Column")
        if isDataVisibleColumn(to) {
            selectColumnRange(from: to, to: to)
        }
    }

    func tableView(_ tableView: NSTableView, shouldReorderColumn columnIndex: Int, toColumn newColumnIndex: Int) -> Bool {
        // newColumnIndex == -1 is AppKit's initial "can this column be dragged at all"
        // query — must allow it or the drag never starts. Only forbid dropping at 0
        // (the row-number column's slot). Column reorder is a view operation, so it
        // works in both read-only and edit mode (edit-mode Save bakes it into the file).
        isDataVisibleColumn(columnIndex) && newColumnIndex != 0
    }

    func tableViewSelectionDidChange(_ notification: Notification) {
        refreshVisibleSelectionAppearance()
        updateToolbarState()
    }

    func dataCellControlShouldHandleMouseDown(visibleRow: Int, columnIndex: Int, event: NSEvent) -> Bool {
        removeActiveTextSelectionView()
        if columnIndex < 0 {
            selectRowRange(from: visibleRow, to: visibleRow)
            return false
        }

        guard let visibleColumn = visibleColumn(forDataColumn: columnIndex),
              (0..<displayRowCount).contains(visibleRow) else {
            return false
        }
        let alreadySelectedCell = singleSelectedCell.map { $0 == (visibleRow, visibleColumn) } ?? false

        if alreadySelectedCell {
            return true
        }

        selectCellRange(from: (visibleRow, visibleColumn), to: (visibleRow, visibleColumn))
        return false
    }

    func selectCellRange(from start: (row: Int, column: Int), to end: (row: Int, column: Int)) {
        removeActiveTextSelectionView()
        removeActiveCellEditor(commit: true)
        guard (0..<displayRowCount).contains(start.row),
              (0..<displayRowCount).contains(end.row),
              isDataVisibleColumn(start.column),
              isDataVisibleColumn(end.column) else {
            return
        }
        selectionMode = .cells
        selectionRange = TableSelectionRange(mode: .cells, rows: indexSet(from: start.row, to: end.row), columns: indexSet(from: start.column, to: end.column))
        applyNativeRowSelection(selectionRange.rows)
        window?.makeFirstResponder(tableView)
        refreshVisibleSelectionAppearance()
        updateToolbarState()
    }

    func selectRowRange(from startRow: Int, to endRow: Int) {
        removeActiveTextSelectionView()
        removeActiveCellEditor(commit: true)
        guard (0..<displayRowCount).contains(startRow),
              (0..<displayRowCount).contains(endRow) else {
            return
        }
        selectionMode = .rows
        selectionRange = TableSelectionRange(mode: .rows, rows: indexSet(from: startRow, to: endRow), columns: dataVisibleColumnIndexes())
        applyNativeRowSelection(selectionRange.rows)
        window?.makeFirstResponder(tableView)
        refreshVisibleSelectionAppearance()
        updateToolbarState()
    }

    /// Applies native NSTableView row selection. In lazy mode a column/all selection
    /// can span millions of rows; pushing them all into NSTableView's native selection
    /// is O(rows) and freezes the main thread. We draw selection ourselves from
    /// `selectionRange`, so natively we only need the visible window.
    private func applyNativeRowSelection(_ rows: IndexSet) {
        guard isLazy, rows.count > 10_000 else {
            tableView.selectRowIndexes(rows, byExtendingSelection: false)
            return
        }
        let visible = tableView.rows(in: tableView.visibleRect)
        let clamped: IndexSet
        if visible.length > 0 {
            let upper = min(visible.location + visible.length, tableView.numberOfRows)
            clamped = IndexSet(integersIn: visible.location..<upper)
        } else {
            clamped = IndexSet()
        }
        tableView.selectRowIndexes(clamped, byExtendingSelection: false)
    }

    func selectColumnRange(from startColumn: Int, to endColumn: Int) {
        removeActiveTextSelectionView()
        removeActiveCellEditor(commit: true)
        guard isDataVisibleColumn(startColumn),
              isDataVisibleColumn(endColumn) else {
            return
        }
        selectionMode = .columns
        let selectedRows = displayRowCount == 0 ? IndexSet() : IndexSet(integersIn: 0..<displayRowCount)
        selectionRange = TableSelectionRange(mode: .columns, rows: selectedRows, columns: indexSet(from: startColumn, to: endColumn))
        applyNativeRowSelection(displayRowCount == 0 ? IndexSet() : selectedRows)
        setContextColumnFromVisibleColumn(startColumn)
        window?.makeFirstResponder(tableView)
        refreshVisibleSelectionAppearance()
        updateToolbarState()
    }

    /// Immediately tints the pressed column (header + body) on mouse-down, without
    /// touching first responder or reloading, so it's safe to call before
    /// NSTableHeaderView's native drag tracking (which would otherwise be cancelled).
    /// The full selection (first responder etc.) is finalized after the drag.
    func previewColumnSelection(_ visibleColumn: Int) {
        guard isDataVisibleColumn(visibleColumn) else { return }
        selectionMode = .columns
        let rows = displayRowCount == 0 ? IndexSet() : IndexSet(integersIn: 0..<displayRowCount)
        selectionRange = TableSelectionRange(mode: .columns, rows: rows, columns: indexSet(from: visibleColumn, to: visibleColumn))
        refreshVisibleSelectionAppearance()
    }

    func clearSelection() {
        removeActiveTextSelectionView()
        removeActiveCellEditor(commit: true)
        guard !selectionRange.isEmpty || selectionMode != .cells else { return }
        selectionMode = .cells
        selectionRange = TableSelectionRange()
        tableView.selectRowIndexes(IndexSet(), byExtendingSelection: false)
        refreshVisibleSelectionAppearance()
        updateToolbarState()
    }

    func selectAllCells() {
        removeActiveTextSelectionView()
        removeActiveCellEditor(commit: true)
        guard displayRowCount > 0 else { return }
        let dataColumns = dataVisibleColumnIndexes()
        guard !dataColumns.isEmpty else { return }
        selectionMode = .all
        selectionRange = TableSelectionRange(
            mode: .all,
            rows: IndexSet(integersIn: 0..<displayRowCount),
            columns: dataColumns
        )
        applyNativeRowSelection(selectionRange.rows)
        window?.makeFirstResponder(tableView)
        refreshVisibleSelectionAppearance()
        updateToolbarState()
    }

    // Row reorder is only meaningful when the visible order matches the document
    // order (no sort / filter / search), otherwise dragging rows is ambiguous.
    func canReorderRows() -> Bool {
        guard isEditingEnabled, let document = tableDocument else { return false }
        return visibleRows == Array(0..<document.rowCount)
    }

    func showRowDropIndicator(atVisibleIndex index: Int) {
        if rowDropIndicator.superview !== tableView {
            tableView.addSubview(rowDropIndicator)
        }
        let rowCount = tableView.numberOfRows
        let y: CGFloat
        if index >= rowCount {
            y = rowCount > 0 ? tableView.rect(ofRow: rowCount - 1).maxY : 0
        } else {
            y = tableView.rect(ofRow: index).minY
        }
        rowDropIndicator.frame = NSRect(x: 0, y: y - 1, width: tableView.bounds.width, height: 2)
        rowDropIndicator.isHidden = false
        tableView.addSubview(rowDropIndicator, positioned: .above, relativeTo: nil)
    }

    func hideRowDropIndicator() {
        rowDropIndicator.isHidden = true
    }

    func moveSelectedRows(toVisibleIndex index: Int) {
        guard canReorderRows() else { return }
        let sorted = selectionRange.rows.sorted()
        guard !sorted.isEmpty else { return }
        // This is called from inside the drag's manual nextEvent loop; registering undo
        // there corrupts UndoManager's per-event grouping. Defer to a clean run-loop turn.
        DispatchQueue.main.async { [weak self] in
            self?.performUndoableMoveRows(IndexSet(sorted), to: index, actionName: "Move Rows")
        }
    }

    func beginTextSelection(in cell: DataTextCellView, anchorEvent: NSEvent, firstDragEvent: NSEvent) {
        showTextSelectionOverlay(for: cell, anchorEvent: anchorEvent, firstDragEvent: firstDragEvent)
    }

    @objc func editSelectedCellClicked(_ sender: Any?) {
        editSelectedCell(initialText: nil)
    }

    func activateSelectedCellTextInteraction(initialText: String?, activationEvent: NSEvent?) {
        guard isEditingEnabled, let (visibleRow, visibleColumn) = singleSelectedCell else { return }

        // Select/multiSelect/status cells open a native picker instead of a text editor.
        if !isLazy, metadata.schemaEnabled,
           tableView.tableColumns.indices.contains(visibleColumn),
           let dataColumn = Int(tableView.tableColumns[visibleColumn].identifier.rawValue),
           let tableDocument, tableDocument.headers.indices.contains(dataColumn) {
            let type = schema.schema(for: tableDocument.headers[dataColumn]).type
            if type == .select || type == .status || type == .multiSelect,
               let pill = tableView.view(atColumn: visibleColumn, row: visibleRow, makeIfNecessary: true) as? PillCellView {
                dataCellRequestsTagPicker(documentRow: pill.documentRow, columnIndex: dataColumn, multi: type == .multiSelect, sourceView: pill)
                return
            }
            // URL cells fall through to the generic editing path below (they conform to
            // InlineEditableCellView and edit their raw value like a text cell); opening
            // the link is Cmd+click only (openLink).
        }

        guard let cell = tableView.view(atColumn: visibleColumn, row: visibleRow, makeIfNecessary: true) as? InlineEditableCellView else {
            return
        }
        removeActiveTextSelectionView()
        removeActiveCellEditor(commit: true)
        showInlineCellEditor(for: cell, initialText: initialText, activationEvent: activationEvent)
    }

    /// Cmd+click on a URL-typed cell opens the link in the default browser; returns
    /// whether the click was consumed. A URLCellView only exists when Types are on and
    /// the value conforms (http/https), so checking the view type covers the gating.
    /// Deliberately not gated on edit mode — opening a link is navigation, not editing.
    func openLink(atVisibleRow row: Int, visibleColumn column: Int) -> Bool {
        guard let urlView = tableView.view(atColumn: column, row: row, makeIfNecessary: false) as? URLCellView,
              let url = URL(string: urlView.rawValue.trimmingCharacters(in: .whitespacesAndNewlines)),
              url.scheme?.hasPrefix("http") == true else {
            return false
        }
        NSWorkspace.shared.open(url)
        return true
    }

    func moveSelectedCell(rowDelta: Int, columnDelta: Int) {
        endActiveCellTextInteraction(commit: true)
        guard displayRowCount > 0 else { return }
        let dataColumns = (0..<tableView.numberOfColumns).filter { isDataVisibleColumn($0) }
        guard let firstDataColumn = dataColumns.first else { return }

        let current = singleSelectedCell
        let currentRow = current?.visibleRow ?? 0
        let currentColumn = current?.visibleColumn ?? firstDataColumn

        let newRow = min(max(currentRow + rowDelta, 0), displayRowCount - 1)
        var newColumn = currentColumn
        if columnDelta != 0 {
            if let index = dataColumns.firstIndex(of: currentColumn) {
                let newIndex = min(max(index + columnDelta, 0), dataColumns.count - 1)
                newColumn = dataColumns[newIndex]
            } else {
                newColumn = firstDataColumn
            }
        }

        selectCellRange(from: (newRow, newColumn), to: (newRow, newColumn))
        tableView.scrollRowToVisible(newRow)
        tableView.scrollColumnToVisible(newColumn)
    }

    func editSelectedCell(initialText: String?) {
        guard isEditingEnabled, singleSelectedCell != nil else {
            return
        }

        activateSelectedCellTextInteraction(initialText: initialText, activationEvent: nil)
    }

    func endActiveCellTextInteraction(commit: Bool) {
        removeActiveTextSelectionView()
        removeActiveCellEditor(commit: commit)
    }

    func controlTextDidEndEditing(_ obj: Notification) {}

    func textView(_ textView: NSTextView, doCommandBy commandSelector: Selector) -> Bool {
        if let editor = textView as? InlineCellEditor,
           editor === activeCellEditor {
            if commandSelector == #selector(NSResponder.insertNewline(_:)) {
                commitActiveCellEditor(value: editor.string)
                return true
            }
            if commandSelector == #selector(NSResponder.cancelOperation(_:)) {
                cancelActiveCellEditor()
                return true
            }
        }
        return false
    }

    func controlTextDidChange(_ obj: Notification) {
        if obj.object as? NSSearchField === searchField {
            // Debounce: a full-table scan per keystroke is costly on large files.
            // Coalesce rapid typing into one rebuild once the user pauses.
            searchDebounceWorkItem?.cancel()
            let workItem = DispatchWorkItem { [weak self] in
                self?.rebuildVisibleRows()
            }
            searchDebounceWorkItem = workItem
            DispatchQueue.main.asyncAfter(deadline: .now() + searchDebounceInterval, execute: workItem)
        }
    }

    func textDidEndEditing(_ notification: Notification) {
        guard notification.object as? InlineCellEditor === activeCellEditor else { return }
        commitActiveCellEditor()
    }

    func inlineCellEditorDidCommit(_ editor: InlineCellEditor) {
        guard editor === activeCellEditor else { return }
        commitActiveCellEditor(value: editor.string)
    }

    func inlineCellEditorDidCancel(_ editor: InlineCellEditor) {
        guard editor === activeCellEditor else { return }
        cancelActiveCellEditor()
    }

    func windowWillClose(_ notification: Notification) {
        saveCurrentMetadata()
        onClose?(self)
    }

    func windowWillReturnUndoManager(_ window: NSWindow) -> UndoManager? {
        documentUndoManager
    }

    func validateMenuItem(_ menuItem: NSMenuItem) -> Bool {
        switch menuItem.action {
        case #selector(copy(_:)):
            return hasCopyableSelection
        case #selector(paste(_:)):
            return isEditingEnabled
        case #selector(editSelectedCellClicked(_:)):
            return canEditSelectedCell
        case #selector(addRowClicked(_:)):
            return isEditingEnabled
        case #selector(deleteRowsClicked(_:)):
            return isEditingEnabled && selectionMode == .rows && !tableView.selectedRowIndexes.isEmpty
        case #selector(renameColumnClicked(_:)), #selector(deleteColumnClicked(_:)):
            return isEditingEnabled && activeColumnIndex() != nil
        case #selector(setColumnTypeFromMenu(_:)):
            guard metadata.schemaEnabled, let tableDocument else { return false }
            guard let typeItem = menuItem as? ColumnTypeMenuItem,
                  tableDocument.headers.indices.contains(typeItem.columnIndex) else {
                return activeColumnIndex() != nil
            }
            let header = tableDocument.headers[typeItem.columnIndex]
            menuItem.state = (typeItem.columnType == schema.schema(for: header).type) ? .on : .off
            // Gate: a format type is selectable only if the whole column conforms to it.
            // Text and intent types (select/multiSelect/status) are always selectable.
            guard typeItem.columnType.isFormatType else { return true }
            return ColumnTypeValidator.columnConforms(columnValues(typeItem.columnIndex, in: tableDocument), to: typeItem.columnType)
        case #selector(manageColumnOptionsClicked(_:)):
            guard metadata.schemaEnabled else { return false }
            guard let columnIndex = activeColumnIndex(),
                  let tableDocument,
                  tableDocument.headers.indices.contains(columnIndex) else { return false }
            let type = schema.schema(for: tableDocument.headers[columnIndex]).type
            return type == .select || type == .multiSelect || type == .status
        case #selector(toggleEditModeClicked(_:)):
            return tableDocument?.canEditFormat == true
        case #selector(toggleFirstRowHeaderClicked(_:)):
            menuItem.state = (tableDocument?.hasHeaderRow == true) ? .on : .off
            return supportsHeaderToggle
        case #selector(writeHeadersToFileClicked(_:)):
            return isDelimitedDocument && tableDocument?.readOnly == false && tableDocument?.hasHeaderRow == false
        default:
            return true
        }
    }

    func toolbarAllowedItemIdentifiers(_ toolbar: NSToolbar) -> [NSToolbarItem.Identifier] {
        [.newTab, .openFile, .saveFile, .toggleEdit, .toggleTypes, .filterPanel, .addRow, .deleteRow, .fileInfo, .flexibleSpace, .searchField]
    }

    func toolbarDefaultItemIdentifiers(_ toolbar: NSToolbar) -> [NSToolbarItem.Identifier] {
        [.newTab, .openFile, .saveFile, .toggleEdit, .toggleTypes, .filterPanel, .addRow, .deleteRow, .fileInfo, .flexibleSpace, .searchField]
    }

    func toolbar(_ toolbar: NSToolbar, itemForItemIdentifier itemIdentifier: NSToolbarItem.Identifier, willBeInsertedIntoToolbar flag: Bool) -> NSToolbarItem? {
        switch itemIdentifier {
        case .newTab:
            let item = NSToolbarItem(itemIdentifier: itemIdentifier)
            item.label = "New Tab"
            item.paletteLabel = "New Tab"
            item.toolTip = "Open a new tab"
            item.image = NSImage(systemSymbolName: "plus", accessibilityDescription: "New Tab")
            item.target = self
            item.action = #selector(newWindowForTab(_:))
            return item
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
            item.autovalidates = false
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
            item.autovalidates = false
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
            item.autovalidates = false
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
            item.autovalidates = false
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
            item.autovalidates = false
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
            item.autovalidates = false
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
        if let appDelegate = NSApp.delegate as? AppDelegate {
            appDelegate.openFileInTab(url: url)
        } else {
            open(url: url)
        }
        return true
    }

    func appearanceDidChange() {
        // Fired from both the window's effectiveAppearance KVO and DropView; coalesce to
        // one refresh, and defer it off the appearance-transition tick.
        guard !appearanceRefreshScheduled else { return }
        appearanceRefreshScheduled = true
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            self.appearanceRefreshScheduled = false
            self.scrollView.backgroundColor = .textBackgroundColor
            self.statusLabel.textColor = .secondaryLabelColor
            self.tableView.reloadData()
            self.tableView.needsDisplay = true
            self.tableView.headerView?.needsDisplay = true
            self.updateTrailingGridLineColor()
            self.updateToolbarState()
            self.refreshWindowChrome()
        }
    }

    /// Works around a macOS "Liquid Glass" toolbar bug: on a live light/dark toggle the
    /// window and its titlebar *container* re-resolve to the new appearance, but the
    /// `NSTitlebarView` / `NSToolbarView` subtree keeps an explicitly-pinned vibrant
    /// appearance (e.g. VibrantLight) and never recomputes — so the toolbar band stays
    /// stuck on the previous appearance (white in dark mode). `needsDisplay` and a
    /// theme-frame rebuild don't help because the stale value is the pinned `appearance`,
    /// not the drawing. Clearing that pin lets the views re-derive the correct vibrant
    /// variant from their (already-updated) parent. We walk only the window chrome, never
    /// the content view's subtree.
    private func refreshWindowChrome() {
        guard let window, let frameView = window.contentView?.superview else { return }
        let contentView = window.contentView
        func clearPinnedVibrant(_ v: NSView) {
            if let name = v.appearance?.name, name == .vibrantLight || name == .vibrantDark {
                v.appearance = nil
            }
            for sub in v.subviews where sub !== contentView {
                clearPinnedVibrant(sub)
            }
        }
        clearPinnedVibrant(frameView)
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

    func toggleSort(forVisibleColumn visibleColumn: Int) {
        // Sorting a lazy Parquet re-sorts the whole table per page (huge cost/memory
        // on wide files); disabled in lazy mode along with search/filter.
        guard !isLazy else { return }
        guard isDataVisibleColumn(visibleColumn),
              let columnIndex = Int(tableView.tableColumns[visibleColumn].identifier.rawValue) else {
            return
        }

        let current = tableView.sortDescriptors.first
        let ascending: Bool
        if current?.key == String(columnIndex) {
            ascending = !(current?.ascending ?? true)
        } else {
            ascending = true
        }

        tableView.sortDescriptors = [
            NSSortDescriptor(key: String(columnIndex), ascending: ascending)
        ]
        updateHeaderSortState()
    }

    func clearSortForHeaderSelection() {
        guard !tableView.sortDescriptors.isEmpty else {
            updateHeaderSortState()
            return
        }
        tableView.sortDescriptors = []
        updateHeaderSortState()
    }

    @objc private func openClicked(_ sender: Any?) {
        NSApp.sendAction(#selector(AppDelegate.openDocument(_:)), to: NSApp.delegate, from: sender)
    }

    override func newWindowForTab(_ sender: Any?) {
        NSApp.sendAction(#selector(AppDelegate.newWindowForTab(_:)), to: NSApp.delegate, from: sender)
    }

    @objc private func saveClicked(_ sender: Any?) {
        saveDocument()
    }

    @objc func showFileInfoClicked(_ sender: Any?) {
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

    @objc func toggleEditModeClicked(_ sender: Any?) {
        guard let tableDocument else { return }
        guard tableDocument.canEditFormat else {
            showError(TableDocumentError.saveUnsupported(tableDocument.openInfo.readOnlyReason ?? "\(tableDocument.format.displayName) is read-only."))
            return
        }
        removeActiveTextSelectionView()
        removeActiveCellEditor(commit: true)
        editLocked.toggle()
        tableView.reloadData()
        updateStatus()
        updateToolbarState()
    }

    @objc func toggleTypesClicked(_ sender: Any?) {
        guard let tableDocument else { return }
        metadata.schemaEnabled.toggle()
        if metadata.schemaEnabled {
            schema = SchemaMetadataStore.load(for: tableDocument.url, headers: tableDocument.headers, rows: tableDocument.rows)
            // Self-heal: drop any saved format type whose column no longer conforms
            // (e.g. the user edited values to non-numbers while types were off).
            schema.demoteNonConforming(headers: tableDocument.headers, rows: tableDocument.rows)
            saveCurrentSchema()
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

    @objc func toggleFilterPanelClicked(_ sender: Any?) {
        guard !isLazy else { return }
        filterPanelVisible.toggle()
        filterBar?.isHidden = !filterPanelVisible
        updateToolbarState()
    }

    // MARK: - Undoable edits (strategy B: incremental inverse, memory-light)

    private func reloadEditedDocumentRow(_ documentRow: Int) {
        if let visibleRow = visibleRows.firstIndex(of: documentRow) {
            tableView.reloadData(
                forRowIndexes: IndexSet(integer: visibleRow),
                columnIndexes: IndexSet(integersIn: 0..<tableView.numberOfColumns)
            )
            refreshVisibleSelectionAppearance()
        } else {
            tableView.reloadData()
        }
        updateStatus()
        updateToolbarState()
    }

    private func performUndoableCellValue(_ value: String, documentRow: Int, column: Int, actionName: String) {
        guard let doc = tableDocument, !doc.readOnly,
              doc.rows.indices.contains(documentRow),
              doc.headers.indices.contains(column) else { return }
        let current = column < doc.rows[documentRow].count ? doc.rows[documentRow][column] : ""
        guard current != value else { return }
        documentUndoManager.registerUndo(withTarget: self) { target in
            target.performUndoableCellValue(current, documentRow: documentRow, column: column, actionName: actionName)
        }
        documentUndoManager.setActionName(actionName)
        tableDocument?.setValue(value, row: documentRow, column: column)
        reloadEditedDocumentRow(documentRow)
    }

    private func performUndoableInsertRows(_ rowsByIndex: [Int: [String]], actionName: String) {
        guard let doc = tableDocument, !doc.readOnly, !rowsByIndex.isEmpty else { return }
        let indices = rowsByIndex.keys.sorted()
        documentUndoManager.registerUndo(withTarget: self) { target in
            target.performUndoableDeleteRows(IndexSet(indices), actionName: actionName)
        }
        documentUndoManager.setActionName(actionName)
        tableDocument?.insertRows(rowsByIndex)
        rebuildVisibleRows()
        updateToolbarState()
    }

    private func performUndoableDeleteRows(_ indices: IndexSet, actionName: String) {
        guard let doc = tableDocument, !doc.readOnly else { return }
        let valid = indices.filter { doc.rows.indices.contains($0) }
        guard !valid.isEmpty else { return }
        var captured: [Int: [String]] = [:]
        for index in valid { captured[index] = doc.rows[index] }
        documentUndoManager.registerUndo(withTarget: self) { target in
            target.performUndoableInsertRows(captured, actionName: actionName)
        }
        documentUndoManager.setActionName(actionName)
        tableDocument?.deleteRows(IndexSet(valid))
        rebuildVisibleRows()
        updateToolbarState()
    }

    private func performUndoableMoveRows(_ indices: IndexSet, to target: Int, actionName: String) {
        guard let doc = tableDocument, !doc.readOnly else { return }
        let sorted = indices.sorted().filter { doc.rows.indices.contains($0) }
        guard !sorted.isEmpty else { return }
        let count = sorted.count
        let removedBefore = sorted.filter { $0 < target }.count
        let landedStart = min(max(target - removedBefore, 0), max(0, doc.rows.count - count))
        // Inverse: move the landed contiguous block back to its original start.
        // moveRows interprets `target` in the pre-removal index space, so the offset is
        // asymmetric: when the inverse moves the block DOWN (original start below where it
        // landed) we must add `count`; when it moves UP, the start index is used as-is.
        let inverseIndices = IndexSet(integersIn: landedStart..<(landedStart + count))
        let inverseFinalStart = sorted.first ?? 0
        let inverseTarget = inverseFinalStart > landedStart ? inverseFinalStart + count : inverseFinalStart
        documentUndoManager.registerUndo(withTarget: self) { target in
            target.performUndoableMoveRows(inverseIndices, to: inverseTarget, actionName: actionName)
        }
        documentUndoManager.setActionName(actionName)
        tableDocument?.moveRows(IndexSet(sorted), to: target)
        rebuildVisibleRows()
        if visibleRows.indices.contains(landedStart) {
            selectRowRange(from: landedStart, to: min(landedStart + count - 1, visibleRows.count - 1))
        }
        updateToolbarState()
    }

    private func performUndoablePaste(_ pastedRows: [[String]], startRow: Int, startColumn: Int, actionName: String) {
        guard let doc = tableDocument, !doc.readOnly, !pastedRows.isEmpty else { return }
        let oldRowCount = doc.rows.count
        let endRow = startRow + pastedRows.count - 1
        // Capture old contents of rows the paste will overwrite (existing ones only).
        var captured: [Int: [String]] = [:]
        for index in startRow...endRow where index < oldRowCount {
            captured[index] = doc.rows[index]
        }
        documentUndoManager.registerUndo(withTarget: self) { target in
            target.performUndoablePasteRestore(captured, removeRowsFrom: oldRowCount, actionName: actionName)
        }
        documentUndoManager.setActionName(actionName)
        tableDocument?.pasteRows(pastedRows, startingAt: startRow, column: startColumn)
        rebuildVisibleRows()
        updateToolbarState()
    }

    private func performUndoablePasteRestore(_ oldRows: [Int: [String]], removeRowsFrom oldRowCount: Int, actionName: String) {
        guard let doc = tableDocument, !doc.readOnly else { return }
        // Redo info: snapshot what we're about to overwrite/remove so redo re-applies.
        let currentCount = doc.rows.count
        var redoCaptured: [Int: [String]] = [:]
        for index in oldRows.keys where index < currentCount {
            redoCaptured[index] = doc.rows[index]
        }
        let appended = Array((max(oldRowCount, 0))..<currentCount).filter { $0 < currentCount }
        let redoAppendedRows = appended.map { doc.rows[$0] }
        documentUndoManager.registerUndo(withTarget: self) { target in
            target.performUndoablePasteReapply(redoCaptured, appendedRows: redoAppendedRows, fromIndex: oldRowCount, actionName: actionName)
        }
        documentUndoManager.setActionName(actionName)
        // Remove appended rows, then restore overwritten ones.
        if currentCount > oldRowCount {
            tableDocument?.deleteRows(IndexSet(integersIn: oldRowCount..<currentCount))
        }
        for (index, row) in oldRows {
            for column in row.indices {
                tableDocument?.setValue(row[column], row: index, column: column)
            }
        }
        rebuildVisibleRows()
        updateToolbarState()
    }

    private func performUndoablePasteReapply(_ overwritten: [Int: [String]], appendedRows: [[String]], fromIndex: Int, actionName: String) {
        guard let doc = tableDocument, !doc.readOnly else { return }
        var redoOld: [Int: [String]] = [:]
        for index in overwritten.keys where index < doc.rows.count {
            redoOld[index] = doc.rows[index]
        }
        documentUndoManager.registerUndo(withTarget: self) { target in
            target.performUndoablePasteRestore(redoOld, removeRowsFrom: fromIndex, actionName: actionName)
        }
        documentUndoManager.setActionName(actionName)
        for (index, row) in overwritten {
            for column in row.indices {
                tableDocument?.setValue(row[column], row: index, column: column)
            }
        }
        if !appendedRows.isEmpty {
            var byIndex: [Int: [String]] = [:]
            for (offset, row) in appendedRows.enumerated() { byIndex[fromIndex + offset] = row }
            tableDocument?.insertRows(byIndex)
        }
        rebuildVisibleRows()
        updateToolbarState()
    }

    @objc func addRowClicked(_ sender: Any?) {
        guard isEditingEnabled, let doc = tableDocument else { return }
        let insertionRow = selectedDocumentRowIndexes().max()
        let insertedIndex: Int
        if let insertionRow, doc.rows.indices.contains(insertionRow) {
            insertedIndex = insertionRow + 1
        } else {
            insertedIndex = doc.rows.count
        }
        let emptyRow = Array(repeating: "", count: doc.headers.count)
        performUndoableInsertRows([insertedIndex: emptyRow], actionName: "Add Row")
    }

    @objc func deleteRowsClicked(_ sender: Any?) {
        guard isEditingEnabled, selectionMode == .rows else { return }
        let selectedRows = selectedDocumentRowIndexes()
        guard !selectedRows.isEmpty else { return }
        performUndoableDeleteRows(selectedRows, actionName: "Delete Rows")
    }

    @objc func renameColumnClicked(_ sender: Any?) {
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
            // For a headerless file, the (display-only) names live in view memory, so
            // persist the rename there since it isn't written to the data file.
            if let doc = self.tableDocument, !doc.hasHeaderRow {
                metadata.headerlessColumnNames = doc.headers
                ViewMetadataStore.save(metadata, for: doc.url)
            }
            buildColumns()
            refreshFilterControls()
            rebuildVisibleRows()
            updateStatus()
        }
    }

    @objc func deleteColumnClicked(_ sender: Any?) {
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
        if let selectedText = activeSelectedText(), !selectedText.isEmpty {
            NSPasteboard.general.clearContents()
            NSPasteboard.general.setString(selectedText, forType: .string)
            return
        }

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

        performUndoablePaste(pastedRows, startRow: startRow, startColumn: startColumn, actionName: "Paste")
    }

    @objc private func checkboxClicked(_ sender: DataCellButton) {
        guard isEditingEnabled,
              let tableDocument,
              tableDocument.headers.indices.contains(sender.columnIndex) else {
            return
        }
        let columnSchema = schema.schema(for: tableDocument.headers[sender.columnIndex])
        let nextValue = boolValue(sender.rawValue, schema: columnSchema) ? "false" : "true"
        performUndoableCellValue(nextValue, documentRow: sender.documentRow, column: sender.columnIndex, actionName: "Toggle Checkbox")
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
        let sample = columnValues(columnIndex, in: tableDocument)
        // Safety net behind the menu gate: never let a format type be set on a column
        // whose data doesn't conform (the menu item should already be disabled).
        guard ColumnTypeValidator.columnConforms(sample, to: type) else {
            NSSound.beep()
            return
        }
        schema.setType(type, for: header, sampleValues: sample)
        saveCurrentSchema()
        buildColumns()
        tableView.reloadData()
        updateStatus()
    }

    /// All raw values in a data column (used by the type gate to test column conformance).
    private func columnValues(_ columnIndex: Int, in document: TableDocument) -> [String] {
        document.rows.compactMap { columnIndex < $0.count ? $0[columnIndex] : nil }
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
            let existingColors = Dictionary(columnSchema.options.map { ($0.name, $0.color) }, uniquingKeysWith: { first, _ in first })
            let names = input.stringValue.split(separator: ",").map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }.filter { !$0.isEmpty }
            columnSchema.options = names.enumerated().map { index, name in
                // Keep any previously chosen color; auto-assign a system color to new ones.
                SelectOption(name: name, color: existingColors[name] ?? TagPalette.color(at: index))
            }
            schema.columns[header] = columnSchema
            saveCurrentSchema()
            tableView.reloadData()
        }
    }

    @objc private func applyFilterClicked(_ sender: Any?) {
        guard !isLazy else { return }
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

    @objc func clearFilterClicked(_ sender: Any?) {
        activeFilter = nil
        filterValueField.stringValue = ""
        rebuildVisibleRows()
    }

    @objc func clearSortClicked(_ sender: Any?) {
        tableView.sortDescriptors = []
        rebuildVisibleRows()
        updateHeaderSortState()
    }

    @objc func reloadFileClicked(_ sender: Any?) {
        guard let url = tableDocument?.url else { return }
        open(url: url)
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
            documentColumnOrderDirty = false
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
        scrollView.contentView.postsBoundsChangedNotifications = true
        scrollView.drawsBackground = true
        scrollView.backgroundColor = .textBackgroundColor

        tableView.usesAlternatingRowBackgroundColors = true
        tableView.selectionHighlightStyle = .none
        tableView.allowsColumnReordering = true
        tableView.allowsColumnSelection = false
        tableView.allowsEmptySelection = true
        tableView.allowsColumnResizing = true
        tableView.allowsMultipleSelection = true
        tableView.selectionHandler = self
        tableView.style = .plain
        // Keep every column at its set width; don't auto-stretch the last column to
        // fill the view (which made the rightmost column look huge).
        tableView.columnAutoresizingStyle = .noColumnAutoresizing
        tableView.gridStyleMask = [.solidHorizontalGridLineMask, .solidVerticalGridLineMask]
        tableView.intercellSpacing = NSSize(width: 0, height: 0)
        tableView.rowHeight = 28
        let headerView = DataTableHeaderView()
        headerView.columnActionHandler = self
        headerView.selectionHandler = self
        tableView.headerView = headerView
        tableView.dataSource = self
        tableView.delegate = self
        let corner = CornerSelectButton()
        corner.onClick = { [weak self] in self?.selectAllCells() }
        tableView.cornerView = corner
        tableView.menu = buildTableContextMenu()
        configureSelectionOverlay()

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
        // Clicking the titlebar / toolbar background (above the content) clears the
        // cell selection. Returns the event unconsumed so toolbar items still work.
        titlebarClickMonitor = NSEvent.addLocalMonitorForEvents(matching: .leftMouseDown) { [weak self] event in
            guard let self, let window = self.window, event.window === window else { return event }
            if event.locationInWindow.y > window.contentLayoutRect.maxY {
                self.clearSelection()
            }
            return event
        }
        NotificationCenter.default.addObserver(
            self, selector: #selector(appDidBecomeActive(_:)),
            name: NSApplication.didBecomeActiveNotification, object: nil
        )
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

    private func configureSelectionOverlay() {
        selectionOverlayView.tableView = tableView
        selectionOverlayView.autoresizingMask = [.width, .height]
        selectionOverlayView.frame = scrollView.contentView.bounds
        selectionOverlayView.isHidden = true
        scrollView.contentView.addSubview(selectionOverlayView, positioned: .above, relativeTo: nil)

        // The trailing grid line lives inside the (passthrough) overlay so it stays above
        // row backgrounds and never intercepts mouse events. Positioned via frame so it
        // tracks live during a column-resize drag.
        trailingGridLine.wantsLayer = true
        trailingGridLine.isHidden = true
        selectionOverlayView.addSubview(trailingGridLine)
        updateTrailingGridLineColor()

        NotificationCenter.default.addObserver(
            self,
            selector: #selector(scrollViewBoundsChanged(_:)),
            name: NSView.boundsDidChangeNotification,
            object: scrollView.contentView
        )
        // Keeps the line in sync when the table itself is re-laid-out (window resize,
        // column add/remove). Note this does NOT fire during a column-resize drag — the
        // table frame is stretched wider than its columns, so growing a column doesn't
        // change it; live drag tracking comes from headerDragTick() instead.
        tableView.postsFrameChangedNotifications = true
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(tableViewFrameChanged(_:)),
            name: NSView.frameDidChangeNotification,
            object: tableView
        )
    }

    @objc private func tableViewFrameChanged(_ notification: Notification) {
        updateTrailingGridLine()
    }

    /// Called at 60Hz by DataTableHeaderView while the native header tracking loop runs
    /// (column resize or reorder drag). No delegate callback or notification fires during
    /// that loop on current macOS, so poll: column geometry does update live, and both
    /// frame moves and draws composite normally from inside the loop.
    func headerDragTick() {
        updateTrailingGridLine()
        selectionOverlayView.needsDisplay = true
        updateActiveCellEditorFrame()
    }

    /// Repositions the trailing grid line to the right edge of the last column, in overlay
    /// coordinates. Moving the layer-backed subview's frame composites immediately, so the
    /// line follows a live column-resize drag instead of snapping at the end.
    func updateTrailingGridLine() {
        guard tableView.numberOfColumns > 0 else {
            trailingGridLine.isHidden = true
            return
        }
        let edgeX = tableView.rect(ofColumn: tableView.numberOfColumns - 1).maxX
        let x = tableView.convert(NSPoint(x: edgeX, y: 0), to: selectionOverlayView).x
        let bounds = selectionOverlayView.bounds
        guard x >= bounds.minX, x <= bounds.maxX else {
            trailingGridLine.isHidden = true
            return
        }
        trailingGridLine.isHidden = false
        let frame = NSRect(x: x - 0.5, y: bounds.minY, width: 1, height: bounds.height)
        if trailingGridLine.frame != frame {
            trailingGridLine.frame = frame
        }
    }

    private func updateTrailingGridLineColor() {
        tableView.effectiveAppearance.performAsCurrentDrawingAppearance {
            trailingGridLine.layer?.backgroundColor = tableView.gridColor.cgColor
        }
    }

    @objc private func scrollViewBoundsChanged(_ notification: Notification) {
        selectionOverlayView.frame = scrollView.contentView.bounds
        selectionOverlayView.needsDisplay = true
        updateTrailingGridLine()
        updateActiveCellEditorFrame()
        if isLazy { updateLazyViewport() }
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
        cell.focusRingType = .none

        let textField = DataCellTextField()
        textField.isBordered = false
        textField.drawsBackground = false
        textField.lineBreakMode = .byTruncatingTail
        textField.font = .systemFont(ofSize: 13)
        textField.isEditable = false
        textField.isSelectable = true
        textField.focusRingType = .none
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

    private func makeDataTextCell(identifier: NSUserInterfaceItemIdentifier) -> DataTextCellView {
        let cell = DataTextCellView()
        cell.identifier = identifier
        cell.translatesAutoresizingMaskIntoConstraints = true
        return cell
    }

    private func checkboxCell(value: String, schema: ColumnSchema, visibleRow: Int, documentRow: Int, columnIndex: Int) -> NSView {
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
        button.mouseHandler = self
        button.visibleRow = visibleRow
        button.documentRow = documentRow
        button.columnIndex = columnIndex
        button.rawValue = value
        applySelectionStyle(to: cell, visibleRow: visibleRow, visibleColumn: visibleColumn(forDataColumn: columnIndex) ?? -1)
        return cell
    }

    /// Display cell for select/status (single) and multiSelect (multi) — renders colored
    /// pills. Editing is opened via native pickers in dataCellRequestsTagPicker.
    private func pillCell(value: String, schema columnSchema: ColumnSchema, visibleRow: Int, documentRow: Int, columnIndex: Int, multi: Bool) -> NSView {
        let id = NSUserInterfaceItemIdentifier(multi ? "MultiPillCell" : "PillCell")
        let cell: PillCellView
        if let reused = tableView.makeView(withIdentifier: id, owner: self) as? PillCellView {
            cell = reused
        } else {
            cell = PillCellView()
            cell.identifier = id
            cell.translatesAutoresizingMaskIntoConstraints = true
        }
        cell.visibleRow = visibleRow
        cell.documentRow = documentRow
        cell.columnIndex = columnIndex
        cell.rawValue = value
        cell.tokens = tagTokens(for: value, schema: columnSchema, multi: multi)
        let visibleCol = visibleColumn(forDataColumn: columnIndex) ?? -1
        cell.selectionFill = isBodyCell(visibleRow: visibleRow, visibleColumn: visibleCol)
            ? NSColor.controlAccentColor.withAlphaComponent(0.10) : nil
        return cell
    }

    private func tagTokens(for value: String, schema columnSchema: ColumnSchema, multi: Bool) -> [(text: String, color: NSColor)] {
        let names: [String]
        if multi {
            names = value.split(separator: Character(columnSchema.multiSelectSeparator))
                .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
                .filter { !$0.isEmpty }
        } else {
            let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
            names = trimmed.isEmpty ? [] : [trimmed]
        }
        return names.map { ($0, color(forOptionName: $0, schema: columnSchema)) }
    }

    private func color(forOptionName name: String, schema columnSchema: ColumnSchema) -> NSColor {
        Self.systemColor(named: columnSchema.options.first { $0.name == name }?.color ?? "gray")
    }

    /// Resolves a stored semantic color name to an appearance-adaptive system color, so
    /// no colors are hand-picked and dark/light adaptation is automatic.
    static func systemColor(named name: String) -> NSColor {
        switch name {
        case "blue": .systemBlue
        case "green": .systemGreen
        case "yellow": .systemYellow
        case "orange": .systemOrange
        case "red": .systemRed
        case "pink": .systemPink
        case "purple": .systemPurple
        case "indigo": .systemIndigo
        case "teal": .systemTeal
        case "cyan": .systemCyan
        case "mint": .systemMint
        case "brown": .systemBrown
        default: .systemGray
        }
    }

    /// A small rounded color swatch for menu items.
    private func swatchImage(color: NSColor, size: CGFloat = 11) -> NSImage {
        let image = NSImage(size: NSSize(width: size, height: size))
        image.lockFocus()
        let rect = NSRect(x: 0, y: 0, width: size, height: size)
        color.setFill()
        NSBezierPath(roundedRect: rect, xRadius: 3, yRadius: 3).fill()
        image.unlockFocus()
        return image
    }

    // MARK: - Tag pickers (native menu / popover)

    private struct MultiSelectDraft {
        let documentRow: Int
        let columnIndex: Int
        let separator: String
        let order: [String]
        var selected: Set<String>
        let original: String
    }

    private var multiSelectPopover: NSPopover?
    private var multiSelectDraft: MultiSelectDraft?

    func dataCellRequestsTagPicker(documentRow: Int, columnIndex: Int, multi: Bool, sourceView: NSView) {
        guard isEditingEnabled, let tableDocument,
              tableDocument.headers.indices.contains(columnIndex),
              tableDocument.rows.indices.contains(documentRow) else { return }
        let row = tableDocument.rows[documentRow]
        let current = columnIndex < row.count ? row[columnIndex] : ""
        if multi {
            showMultiSelectPopover(documentRow: documentRow, columnIndex: columnIndex, currentValue: current, sourceView: sourceView)
        } else {
            showSingleSelectMenu(documentRow: documentRow, columnIndex: columnIndex, currentValue: current, sourceView: sourceView)
        }
    }

    private func showSingleSelectMenu(documentRow: Int, columnIndex: Int, currentValue: String, sourceView: NSView) {
        guard let tableDocument, tableDocument.headers.indices.contains(columnIndex) else { return }
        let columnSchema = schema.schema(for: tableDocument.headers[columnIndex])
        let trimmed = currentValue.trimmingCharacters(in: .whitespacesAndNewlines)
        let menu = NSMenu()

        let clear = TagMenuItem(title: "None", action: #selector(tagMenuPicked(_:)), keyEquivalent: "")
        clear.target = self
        clear.documentRow = documentRow
        clear.columnIndex = columnIndex
        clear.optionName = ""
        clear.state = trimmed.isEmpty ? .on : .off
        menu.addItem(clear)
        menu.addItem(.separator())

        var names = columnSchema.options.map(\.name)
        if !trimmed.isEmpty, !names.contains(trimmed) { names.append(trimmed) }
        for name in names {
            let item = TagMenuItem(title: name, action: #selector(tagMenuPicked(_:)), keyEquivalent: "")
            item.target = self
            item.documentRow = documentRow
            item.columnIndex = columnIndex
            item.optionName = name
            item.image = swatchImage(color: color(forOptionName: name, schema: columnSchema))
            item.state = (name == trimmed) ? .on : .off
            menu.addItem(item)
        }
        menu.popUp(positioning: nil, at: NSPoint(x: 0, y: sourceView.bounds.height), in: sourceView)
    }

    @objc private func tagMenuPicked(_ sender: TagMenuItem) {
        performUndoableCellValue(sender.optionName, documentRow: sender.documentRow, column: sender.columnIndex, actionName: "Set Value")
    }

    private func showMultiSelectPopover(documentRow: Int, columnIndex: Int, currentValue: String, sourceView: NSView) {
        guard let tableDocument, tableDocument.headers.indices.contains(columnIndex) else { return }
        let columnSchema = schema.schema(for: tableDocument.headers[columnIndex])
        let separator = columnSchema.multiSelectSeparator
        let currentTokens = currentValue.split(separator: Character(separator))
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
        var order = columnSchema.options.map(\.name)
        for token in currentTokens where !order.contains(token) { order.append(token) }

        multiSelectDraft = MultiSelectDraft(
            documentRow: documentRow,
            columnIndex: columnIndex,
            separator: separator,
            order: order,
            selected: Set(currentTokens),
            original: currentValue
        )

        let stack = NSStackView()
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 6
        stack.edgeInsets = NSEdgeInsets(top: 10, left: 14, bottom: 10, right: 14)
        if order.isEmpty {
            let label = NSTextField(labelWithString: "No options yet")
            label.textColor = .secondaryLabelColor
            stack.addArrangedSubview(label)
        }
        for name in order {
            let checkbox = MultiTagCheckbox(checkboxWithTitle: name, target: self, action: #selector(multiSelectCheckboxToggled(_:)))
            checkbox.optionName = name
            checkbox.state = currentTokens.contains(name) ? .on : .off
            stack.addArrangedSubview(checkbox)
        }

        let container = NSView(frame: NSRect(x: 0, y: 0, width: 220, height: 0))
        container.translatesAutoresizingMaskIntoConstraints = false
        container.addSubview(stack)
        stack.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: container.leadingAnchor),
            stack.trailingAnchor.constraint(equalTo: container.trailingAnchor),
            stack.topAnchor.constraint(equalTo: container.topAnchor),
            stack.bottomAnchor.constraint(equalTo: container.bottomAnchor),
            container.widthAnchor.constraint(greaterThanOrEqualToConstant: 200)
        ])

        let viewController = NSViewController()
        viewController.view = container
        let popover = NSPopover()
        popover.behavior = .transient
        popover.delegate = self
        popover.contentViewController = viewController
        multiSelectPopover = popover
        popover.show(relativeTo: sourceView.bounds, of: sourceView, preferredEdge: .maxY)
    }

    @objc private func multiSelectCheckboxToggled(_ sender: MultiTagCheckbox) {
        guard multiSelectDraft != nil else { return }
        if sender.state == .on {
            multiSelectDraft?.selected.insert(sender.optionName)
        } else {
            multiSelectDraft?.selected.remove(sender.optionName)
        }
    }

    private func urlCell(value: String, visibleRow: Int, documentRow: Int, columnIndex: Int) -> NSView {
        let id = NSUserInterfaceItemIdentifier("URLCell")
        let cell: URLCellView
        if let reused = tableView.makeView(withIdentifier: id, owner: self) as? URLCellView {
            cell = reused
        } else {
            cell = URLCellView()
            cell.identifier = id
            cell.translatesAutoresizingMaskIntoConstraints = true
        }
        cell.documentRow = documentRow
        cell.columnIndex = columnIndex
        cell.rawValue = value
        let visibleCol = visibleColumn(forDataColumn: columnIndex) ?? -1
        cell.selectionFill = isBodyCell(visibleRow: visibleRow, visibleColumn: visibleCol)
            ? NSColor.controlAccentColor.withAlphaComponent(0.10) : nil
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

    private func applySelectionStyle(to cell: NSTableCellView, visibleRow: Int, visibleColumn: Int) {
        cell.wantsLayer = true
        cell.layer?.cornerRadius = 0
        if visibleColumn == 0 {
            let anchor = isAnchorCell(visibleRow: visibleRow, visibleColumn: visibleColumn)
            cell.layer?.backgroundColor = anchor ? NSColor.controlAccentColor.cgColor : NSColor.clear.cgColor
            cell.textField?.textColor = anchor ? .white : .secondaryLabelColor
            cell.textField?.font = .systemFont(ofSize: 13, weight: anchor ? .semibold : .regular)
        } else {
            let body = isBodyCell(visibleRow: visibleRow, visibleColumn: visibleColumn)
            cell.layer?.backgroundColor = body
                ? NSColor.controlAccentColor.withAlphaComponent(0.10).cgColor
                : NSColor.clear.cgColor
        }
    }

    // Row-number cell (column 0) is the "anchor" for row/all selection.
    private func isAnchorCell(visibleRow: Int, visibleColumn: Int) -> Bool {
        guard !selectionRange.isEmpty, visibleColumn == 0 else { return false }
        switch selectionMode {
        case .all: return true
        case .rows: return selectionRange.rows.contains(visibleRow)
        default: return false
        }
    }

    // Data cells (column > 0) get the light body tint for row/column/all selection.
    private func isBodyCell(visibleRow: Int, visibleColumn: Int) -> Bool {
        guard !selectionRange.isEmpty, isDataVisibleColumn(visibleColumn) else { return false }
        switch selectionMode {
        case .all: return true
        case .rows: return selectionRange.rows.contains(visibleRow)
        case .columns: return selectionRange.columns.contains(visibleColumn)
        case .cells: return false
        }
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
            if let tableDocument, tableDocument.headers.indices.contains(columnIndex) {
                let type = schema.schema(for: tableDocument.headers[columnIndex]).type
                if type == .select || type == .multiSelect || type == .status {
                    menu.addItem(columnMenuItem(title: "Manage Options", action: #selector(manageColumnOptionsClicked(_:)), columnIndex: columnIndex))
                    menu.addItem(tagColorsMenuItem(columnIndex: columnIndex))
                }
            }
        }
        return menu
    }

    /// Submenu to recolor each tag option using the appearance-adaptive system palette.
    private func tagColorsMenuItem(columnIndex: Int) -> NSMenuItem {
        let item = NSMenuItem(title: "Tag Colors", action: nil, keyEquivalent: "")
        let submenu = NSMenu()
        if let tableDocument, tableDocument.headers.indices.contains(columnIndex) {
            let columnSchema = schema.schema(for: tableDocument.headers[columnIndex])
            if columnSchema.options.isEmpty {
                let empty = NSMenuItem(title: "No options yet", action: nil, keyEquivalent: "")
                empty.isEnabled = false
                submenu.addItem(empty)
            }
            for option in columnSchema.options {
                let optionItem = NSMenuItem(title: option.name, action: nil, keyEquivalent: "")
                optionItem.image = swatchImage(color: Self.systemColor(named: option.color))
                let colorMenu = NSMenu()
                for colorName in TagPalette.names {
                    let colorItem = TagColorMenuItem(title: colorName.capitalized, action: #selector(setOptionColor(_:)), keyEquivalent: "")
                    colorItem.target = self
                    colorItem.columnIndex = columnIndex
                    colorItem.optionName = option.name
                    colorItem.colorName = colorName
                    colorItem.image = swatchImage(color: Self.systemColor(named: colorName))
                    colorItem.state = (option.color == colorName) ? .on : .off
                    colorMenu.addItem(colorItem)
                }
                optionItem.submenu = colorMenu
                submenu.addItem(optionItem)
            }
        }
        item.submenu = submenu
        return item
    }

    @objc private func setOptionColor(_ sender: TagColorMenuItem) {
        guard let tableDocument, tableDocument.headers.indices.contains(sender.columnIndex) else { return }
        let header = tableDocument.headers[sender.columnIndex]
        var columnSchema = schema.schema(for: header)
        guard let index = columnSchema.options.firstIndex(where: { $0.name == sender.optionName }) else { return }
        columnSchema.options[index].color = sender.colorName
        schema.columns[header] = columnSchema
        saveCurrentSchema()
        tableView.reloadData()
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
        let rowNumberHeader = SelectableHeaderCell(textCell: "#")
        rowNumberHeader.alignment = .center
        rowNumberColumn.headerCell = rowNumberHeader
        tableView.addTableColumn(rowNumberColumn)

        let orderedIndexes = visibleColumnIndexes(for: tableDocument)
        for index in orderedIndexes {
            let header = tableDocument.headers[index]
            let identifier = NSUserInterfaceItemIdentifier(String(index))
            let column = NSTableColumn(identifier: identifier)
            let type = metadata.schemaEnabled ? schema.schema(for: header).type : .text
            column.title = metadata.schemaEnabled ? "\(header)  \(type.displayName)" : header
            column.minWidth = 80
            column.width = metadata.columnWidths[header] ?? 120
            let headerCell = SelectableHeaderCell(textCell: column.title)
            headerCell.alignment = .center
            column.headerCell = headerCell
            tableView.addTableColumn(column)
        }
        updateHeaderSortState()
    }

    private func visibleColumnIndexes(for document: TableDocument) -> [Int] {
        var indexes: [Int] = []
        var used = Set<Int>()

        for header in metadata.columnOrder {
            if let index = document.headers.firstIndex(of: header), !used.contains(index) {
                indexes.append(index)
                used.insert(index)
            }
        }

        for index in document.headers.indices where !used.contains(index) {
            indexes.append(index)
        }
        return indexes
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
        removeActiveTextSelectionView()
        removeActiveCellEditor(commit: true)
        if isLazy {
            // DuckDB does the filtering/sorting; just push the query and let paging refill.
            lazyController?.setQuery(currentQuerySpec())
            visibleRows = []
        } else {
            visibleRows = TableQueryEngine.visibleRows(
                in: tableDocument,
                search: searchField.stringValue,
                filter: activeFilter,
                sortDescriptor: tableView.sortDescriptors.first
            )
        }
        selectionRange = TableSelectionRange()
        selectionMode = .cells
        tableView.reloadData()
        updateHeaderSortState()
        updateStatus()
        refreshVisibleSelectionAppearance()
        updateTrailingGridLine()
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
        if isLazy {
            statusLabel.stringValue = "\(displayRowCount) rows · \(tableDocument.columnCount) cols"
        } else {
            statusLabel.stringValue = "\(visibleRows.count)/\(tableDocument.rowCount) rows · \(tableDocument.columnCount) cols\(dirty)"
        }
        statusBadge.isHidden = false
        saveButton.isEnabled = tableDocument.canEditFormat && tableDocument.dirty
    }

    private var isEditingEnabled: Bool {
        tableDocument?.canEditFormat == true && !editLocked
    }

    // View-based NSTableView does not support column selection, so `tableView.selectedColumnIndexes`
    // is always empty (AppKit even logs a warning). The authoritative selection is `selectionRange`.
    private var singleSelectedCell: (visibleRow: Int, visibleColumn: Int)? {
        guard selectionMode == .cells,
              selectionRange.rows.count == 1,
              selectionRange.columns.count == 1,
              let row = selectionRange.rows.first,
              let column = selectionRange.columns.first,
              (0..<displayRowCount).contains(row),
              isDataVisibleColumn(column) else {
            return nil
        }
        return (row, column)
    }

    private var hasCopyableSelection: Bool {
        if activeSelectedText()?.isEmpty == false {
            return true
        }
        return !tableView.selectedRowIndexes.isEmpty && !selectedDataVisibleColumns().isEmpty
    }

    private var canEditSelectedCell: Bool {
        isEditingEnabled && singleSelectedCell != nil
    }

    var canEditSelectedCellForMenu: Bool {
        canEditSelectedCell
    }

    private func modeDescription(for document: TableDocument) -> String {
        if document.readOnly {
            return "format read-only"
        }
        return editLocked ? "locked read-only" : "edit mode"
    }

    private func setEnabled(_ enabled: Bool, on item: NSToolbarItem?) {
        if item?.isEnabled != enabled {
            item?.isEnabled = enabled
        }
    }

    private func updateToolbarState() {
        updateHeaderMenuCheckmark()
        let canEditFormat = tableDocument?.canEditFormat == true
        setEnabled(canEditFormat, on: editModeItem)
        let editLabel = isEditingEnabled ? "Lock" : "Edit"
        if editModeItem?.label != editLabel {
            editModeItem?.label = editLabel
            editModeItem?.image = NSImage(
                systemSymbolName: isEditingEnabled ? "lock.open" : "lock",
                accessibilityDescription: editLabel
            )
        }
        setEnabled(isEditingEnabled, on: addRowItem)
        setEnabled(isEditingEnabled && selectionMode == .rows && !selectionRange.rows.isEmpty, on: deleteRowItem)
        setEnabled(tableDocument != nil, on: typeModeItem)
        // Search and filter trigger full-table scans that are pathological on lazy
        // Parquet (wide, many-row); disable those controls in that mode.
        let searchFilterAvailable = tableDocument != nil && !isLazy
        searchField.isEnabled = searchFilterAvailable
        searchField.placeholderString = isLazy ? "Search unavailable for Parquet" : "Search all columns"
        setEnabled(searchFilterAvailable, on: filterItem)
        let typeLabel = metadata.schemaEnabled ? "Types On" : "Types Off"
        if typeModeItem?.label != typeLabel {
            typeModeItem?.label = typeLabel
            typeModeItem?.image = NSImage(
                systemSymbolName: metadata.schemaEnabled ? "tag.fill" : "tag",
                accessibilityDescription: typeLabel
            )
        }
        let filterLabel = filterPanelVisible ? "Hide Filter" : "Filter"
        if filterItem?.label != filterLabel {
            filterItem?.label = filterLabel
            filterItem?.image = NSImage(
                systemSymbolName: filterPanelVisible ? "line.3.horizontal.decrease.circle.fill" : "line.3.horizontal.decrease.circle",
                accessibilityDescription: filterLabel
            )
        }
        let canSave = tableDocument?.canEditFormat == true && tableDocument?.dirty == true
        if saveButton.isEnabled != canSave {
            saveButton.isEnabled = canSave
        }
    }

    private func selectedDocumentRowIndexes() -> IndexSet {
        var indexes = IndexSet()
        for visibleIndex in tableView.selectedRowIndexes {
            if let documentRow = documentRow(forVisible: visibleIndex) {
                indexes.insert(documentRow)
            }
        }
        return indexes
    }

    private func selectedDataColumnIndex() -> Int? {
        selectedDataVisibleColumns().first.flatMap { Int(tableView.tableColumns[$0].identifier.rawValue) }
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

    private func isDataVisibleColumn(_ visibleColumn: Int) -> Bool {
        guard tableView.tableColumns.indices.contains(visibleColumn) else { return false }
        return tableView.tableColumns[visibleColumn].identifier.rawValue != "rowNumber"
    }

    private func visibleColumn(forDataColumn dataColumn: Int) -> Int? {
        tableView.tableColumns.firstIndex { column in
            Int(column.identifier.rawValue) == dataColumn
        }
    }

    private func dataVisibleColumnIndexes() -> IndexSet {
        var indexes = IndexSet()
        for visibleColumn in tableView.tableColumns.indices where isDataVisibleColumn(visibleColumn) {
            indexes.insert(visibleColumn)
        }
        return indexes
    }

    private func selectedDataVisibleColumns() -> [Int] {
        selectionRange.columns.filter { isDataVisibleColumn($0) }.sorted()
    }

    private func currentVisibleDataColumnOrder(in document: TableDocument) -> [Int]? {
        let order = tableView.tableColumns.compactMap { column -> Int? in
            guard let index = Int(column.identifier.rawValue),
                  document.headers.indices.contains(index) else {
                return nil
            }
            return index
        }
        return order.count == document.headers.count ? order : nil
    }

    private func activeSelectedText() -> String? {
        if let selectedText = activeCellEditorSelectedText(), !selectedText.isEmpty {
            return selectedText
        }
        return activeTextSelectionView?.selectedText
    }

    private func activeCellEditorSelectedText() -> String? {
        guard let editor = activeCellEditor else {
            return nil
        }
        let selectedRange = editor.selectedRange()
        guard selectedRange.length > 0,
              let range = Range(selectedRange, in: editor.string) else {
            return nil
        }
        return String(editor.string[range])
    }

    private func refreshVisibleSelectionAppearance() {
        selectionOverlayView.selectionRange = selectionRange
        // Always visible: the overlay also draws the trailing grid line, not just the
        // selection box (it's transparent where neither is present, and click-through).
        selectionOverlayView.isHidden = tableDocument == nil
        selectionOverlayView.frame = scrollView.contentView.bounds
        selectionOverlayView.needsDisplay = true
        if let headerView = tableView.headerView as? DataTableHeaderView {
            headerView.highlightedColumns = (selectionRange.mode == .columns || selectionRange.mode == .all)
                ? selectionRange.columns : []
        }
        updateHeaderSortState()
        refreshVisibleCellSelectionStyles()
    }

    private func refreshVisibleCellSelectionStyles() {
        let rowRange = tableView.rows(in: scrollView.contentView.bounds)
        guard rowRange.location != NSNotFound, rowRange.length > 0 else { return }
        let upperRow = min(rowRange.location + rowRange.length, tableView.numberOfRows)
        guard rowRange.location < upperRow else { return }

        for row in rowRange.location..<upperRow {
            for column in 0..<tableView.numberOfColumns {
                let view = tableView.view(atColumn: column, row: row, makeIfNecessary: false)
                if let cell = view as? PillCellView {
                    cell.selectionFill = isBodyCell(visibleRow: row, visibleColumn: column)
                        ? NSColor.controlAccentColor.withAlphaComponent(0.10) : nil
                } else if let cell = view as? URLCellView {
                    cell.selectionFill = isBodyCell(visibleRow: row, visibleColumn: column)
                        ? NSColor.controlAccentColor.withAlphaComponent(0.10) : nil
                } else if let cell = view as? DataTextCellView {
                    cell.selectionFill = isBodyCell(visibleRow: row, visibleColumn: column)
                        ? NSColor.controlAccentColor.withAlphaComponent(0.10) : nil
                } else if let cell = view as? NSTableCellView {
                    applySelectionStyle(to: cell, visibleRow: row, visibleColumn: column)
                }
            }
        }
    }

    private func updateHeaderSortState() {
        guard let headerView = tableView.headerView as? DataTableHeaderView else { return }
        guard let sortDescriptor = tableView.sortDescriptors.first,
              let key = sortDescriptor.key,
              let dataColumn = Int(key),
              let visibleColumn = visibleColumn(forDataColumn: dataColumn) else {
            headerView.activeSortColumn = nil
            headerView.activeSortAscending = true
            headerView.needsDisplay = true
            return
        }

        headerView.activeSortColumn = visibleColumn
        headerView.activeSortAscending = sortDescriptor.ascending
        headerView.needsDisplay = true
    }

    private func showTextSelectionOverlay(for cell: DataTextCellView, anchorEvent: NSEvent, firstDragEvent: NSEvent) {
        removeActiveTextSelectionView()

        let cellFrameInTable = cell.convert(cell.bounds, to: tableView)
        let overlay = CellTextSelectionOverlay(cellView: cell, frame: cellFrameInTable)
        overlay.autoresizingMask = []

        cell.isHidden = true
        tableView.addSubview(overlay, positioned: .above, relativeTo: nil)
        activeTextSelectionView = overlay
        activeTextSelectionSource = cell

        overlay.beginSelection(anchorEvent: anchorEvent, firstDragEvent: firstDragEvent)
    }

    private func showInlineCellEditor(for cell: InlineEditableCellView, initialText: String?, activationEvent: NSEvent?) {
        let editable = isEditingEnabled
        let cellFrameInTable = cell.convert(cell.bounds, to: tableView)
        let editorFrame = cellFrameInTable.insetBy(dx: 1, dy: 2)
        let editor = InlineCellEditor(frame: editorFrame)
        editor.identifier = NSUserInterfaceItemIdentifier("InlineCellEditor")
        editor.editHandler = self
        editor.delegate = self
        editor.commitsChanges = editable
        editor.isRichText = false
        editor.importsGraphics = false
        editor.allowsUndo = true
        editor.drawsBackground = true
        editor.backgroundColor = .textBackgroundColor
        editor.font = cell.font
        editor.alignment = cell.alignment
        editor.textColor = .labelColor
        editor.insertionPointColor = .controlAccentColor
        editor.isEditable = editable
        editor.isSelectable = true
        editor.isHorizontallyResizable = false
        editor.isVerticallyResizable = false
        editor.textContainerInset = NSSize(width: 7, height: max(0, (editorFrame.height - cell.font.boundingRectForFont.height) / 2 - 1))
        editor.textContainer?.lineFragmentPadding = 0
        editor.textContainer?.widthTracksTextView = true
        editor.textContainer?.heightTracksTextView = true
        editor.string = editable ? (initialText ?? cell.editingString) : cell.editingString
        editor.autoresizingMask = []

        cell.isHidden = true
        tableView.addSubview(editor, positioned: .above, relativeTo: nil)
        activeCellEditor = editor
        activeCellEditorSource = cell

        window?.makeFirstResponder(editor)

        DispatchQueue.main.async { [weak self, weak editor, weak cell] in
            guard let self,
                  let editor,
                  editor === self.activeCellEditor,
                  let cell else {
                return
            }
            let selectedRange = self.initialEditorSelectedRange(
                for: editor,
                source: cell,
                initialText: initialText,
                activationEvent: activationEvent
            )
            editor.setSelectedRange(selectedRange)
        }
    }

    private func initialEditorSelectedRange(
        for editor: InlineCellEditor,
        source: InlineEditableCellView,
        initialText: String?,
        activationEvent: NSEvent?
    ) -> NSRange {
        if let initialText, editor.commitsChanges {
            return NSRange(location: (initialText as NSString).length, length: 0)
        }

        if let activationEvent {
            let point = source.convert(activationEvent.locationInWindow, from: nil)
            let insertionIndex = source.insertionIndex(for: point)
            return NSRange(location: insertionIndex, length: 0)
        }

        return NSRange(location: 0, length: (editor.string as NSString).length)
    }

    private func updateActiveCellEditorFrame() {
        guard let editor = activeCellEditor,
              let source = activeCellEditorSource else {
            return
        }
        editor.frame = source.convert(source.bounds, to: tableView).insetBy(dx: 1, dy: 2)
        editor.textContainerInset = NSSize(width: 7, height: max(0, (editor.frame.height - source.font.boundingRectForFont.height) / 2 - 1))
    }

    private func removeActiveTextSelectionView(reloadIfChanged: Bool = false) {
        guard let overlay = activeTextSelectionView else { return }
        overlay.removeFromSuperview()
        activeTextSelectionView = nil
        activeTextSelectionSource?.isHidden = false
        activeTextSelectionSource = nil
    }

    private func removeActiveCellEditor(commit: Bool) {
        guard activeCellEditor != nil else { return }
        if commit {
            commitActiveCellEditor()
            return
        }
        cancelActiveCellEditor()
    }

    private func commitActiveCellEditor() {
        guard let editor = activeCellEditor,
              let source = activeCellEditorSource else {
            return
        }
        let newValue = editor.string
        commitActiveCellEditor(value: newValue, editor: editor, source: source)
    }

    private func commitActiveCellEditor(value newValue: String) {
        guard let editor = activeCellEditor,
              let source = activeCellEditorSource else {
            return
        }
        commitActiveCellEditor(value: newValue, editor: editor, source: source)
    }

    private func commitActiveCellEditor(value newValue: String, editor: InlineCellEditor, source: InlineEditableCellView) {
        editor.removeFromSuperview()
        activeCellEditor = nil
        source.isHidden = false
        activeCellEditorSource = nil
        window?.makeFirstResponder(tableView)

        guard editor.commitsChanges else { return }
        // Enforce format-typed input while types are on: number/date columns reject
        // non-conforming text (empty is always allowed). url degrades; checkbox isn't
        // typed. The discarded edit leaves the cell at its previous value.
        if metadata.schemaEnabled, !isLazy, let tableDocument,
           tableDocument.headers.indices.contains(source.columnIndex) {
            let type = schema.schema(for: tableDocument.headers[source.columnIndex]).type
            if (type == .number || type == .date), !ColumnTypeValidator.matches(newValue, type: type) {
                NSSound.beep()
                return
            }
        }
        let rawValue = rawValueForEditedText(newValue, columnIndex: source.columnIndex, rawValue: source.rawValue)
        guard rawValue != source.rawValue else { return }
        performUndoableCellValue(rawValue, documentRow: source.documentRow, column: source.columnIndex, actionName: "Edit Cell")
    }

    private func cancelActiveCellEditor() {
        activeCellEditor?.removeFromSuperview()
        activeCellEditor = nil
        activeCellEditorSource?.isHidden = false
        activeCellEditorSource = nil
        window?.makeFirstResponder(tableView)
    }

    private func indexSet(from start: Int, to end: Int) -> IndexSet {
        let lower = min(start, end)
        let upper = max(start, end)
        return IndexSet(integersIn: lower..<(upper + 1))
    }

    private func selectedTabDelimitedText() -> String {
        guard let tableDocument else { return "" }
        let selectedRows = tableView.selectedRowIndexes
        let selectedColumns = selectedDataVisibleColumns()
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
            guard documentRow(forVisible: visibleRow) != nil else { return nil }
            return dataColumns.map { columnIndex in
                cellString(visibleRow: visibleRow, columnIndex: columnIndex)
            }.joined(separator: "\t")
        }.joined(separator: "\n")
    }

    private func captureMetadata() {
        guard let tableDocument else { return }
        var widths: [String: Double] = [:]
        var order: [String] = []
        for column in tableView.tableColumns {
            guard let index = Int(column.identifier.rawValue),
                  tableDocument.headers.indices.contains(index) else {
                continue
            }
            widths[tableDocument.headers[index]] = Double(column.width)
            order.append(tableDocument.headers[index])
        }
        metadata.columnWidths = widths
        metadata.columnOrder = order
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

    /// Writes the current sort into ViewMetadata (alongside column widths/order from
    /// captureMetadata) and saves. Safe to call on every sort/column drag — cheap
    /// since metadata is tiny.
    private func persistViewMetadata() {
        guard let tableDocument else { return }
        captureMetadata()
        if let descriptor = tableView.sortDescriptors.first,
           let key = descriptor.key,
           let columnIndex = Int(key),
           tableDocument.headers.indices.contains(columnIndex) {
            metadata.sortColumnName = tableDocument.headers[columnIndex]
            metadata.sortAscending = descriptor.ascending
        } else {
            metadata.sortColumnName = nil
        }
        ViewMetadataStore.save(metadata, for: tableDocument.url)
    }

    /// Restores a persisted sort descriptor from the view metadata on file open.
    /// Column name → column index (headers may differ if document changed, so we
    /// look up by name; missing columns are silently ignored).
    private func restoreSortFromMetadata(for document: TableDocument) {
        guard let name = metadata.sortColumnName,
              let columnIndex = document.headers.firstIndex(of: name) else { return }
        suppressSortPersistence = true
        tableView.sortDescriptors = [
            NSSortDescriptor(key: String(columnIndex), ascending: metadata.sortAscending)
        ]
        suppressSortPersistence = false
    }

    /// Explicitly syncs the "Use First Row as Header" menu checkmark with the current
    /// document (validateMenuItem state wasn't taking effect for this item).
    private func updateHeaderMenuCheckmark() {
        guard let item = NSApp.mainMenu?.findItem(withAction: Selector(("toggleFirstRowHeaderClicked:"))) else { return }
        item.state = (supportsHeaderToggle && tableDocument?.hasHeaderRow == true) ? .on : .off
    }

    /// Delimited (CSV/TSV) — the formats whose header row can be written to disk.
    private var isDelimitedDocument: Bool {
        guard let format = tableDocument?.format else { return false }
        return format == .csv || format == .tsv
    }

    /// Formats where "first row is header" is a meaningful choice: CSV/TSV (editable)
    /// and XLSX (read-only → the toggle is view-only, never written).
    private var supportsHeaderToggle: Bool {
        guard let format = tableDocument?.format else { return false }
        return format == .csv || format == .tsv || format == .xlsx
    }

    /// Toggles whether the file's first row is treated as a header. Off → synthesize
    /// "Column N" and the former header values move into the data; On → the first data
    /// row is promoted to the header. Remembered per file.
    @objc func toggleFirstRowHeaderClicked(_ sender: Any?) {
        guard var doc = tableDocument, supportsHeaderToggle else { return }
        removeActiveCellEditor(commit: true)
        if doc.hasHeaderRow {
            // Turning OFF: synthesize placeholders; old header becomes first data row.
            let count = doc.headers.count
            let oldHeaders = doc.headers
            doc.headers = (0..<count).map { "Column \($0 + 1)" }
            doc.rows.insert(oldHeaders, at: 0)
            doc.hasHeaderRow = false
        } else {
            // Turning ON: promote the first data row to the header.
            guard !doc.rows.isEmpty else { return }
            let promoted = doc.rows.removeFirst()
            doc.headers = promoted.enumerated().map { index, value in
                let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
                return trimmed.isEmpty ? "Column \(index + 1)" : trimmed
            }
            doc.hasHeaderRow = true
        }
        if !doc.readOnly { doc.dirty = true }   // read-only XLSX: view-only, never saved
        tableDocument = doc
        metadata.hasHeaderRow = doc.hasHeaderRow
        metadata.headerlessColumnNames = doc.hasHeaderRow ? nil : doc.headers
        documentColumnOrderDirty = false
        buildColumns()
        rebuildVisibleRows()
        updateStatus()
        updateToolbarState()
        ViewMetadataStore.save(metadata, for: doc.url)
    }

    /// For a headerless file: commit the current column names as a real header row in
    /// the data file (writes it to disk). The file becomes headered.
    @objc func writeHeadersToFileClicked(_ sender: Any?) {
        guard var doc = tableDocument, isDelimitedDocument, !doc.readOnly, !doc.hasHeaderRow else { return }
        doc.hasHeaderRow = true
        tableDocument = doc
        metadata.hasHeaderRow = true
        metadata.headerlessColumnNames = nil
        saveDocument()   // writes header line + data to the file atomically
    }

    /// Wipes all view-layer arrangement (sort, column order, column widths) back to the
    /// raw data-driven defaults, and persists the cleared state. Works in both modes.
    /// (Leaves column types / schema alone — that's a deliberate feature toggle.)
    @objc func resetViewClicked(_ sender: Any?) {
        guard let tableDocument else { return }
        suppressSortPersistence = true
        tableView.sortDescriptors = []
        suppressSortPersistence = false
        metadata.columnOrder = []
        metadata.columnWidths = [:]
        metadata.sortColumnName = nil
        metadata.sortAscending = true
        documentColumnOrderDirty = false
        if isEditingEnabled { self.tableDocument?.dirty = false }
        buildColumns()            // rebuilds at default width + original column order
        rebuildVisibleRows()
        updateHeaderSortState()
        updateStatus()
        updateToolbarState()
        // Save the truly-empty arrangement directly (don't go through persistViewMetadata,
        // which would recapture current widths/order from the rebuilt table).
        ViewMetadataStore.save(metadata, for: tableDocument.url)
    }

    private func configure(textCell: DataTextCellView, value: String, schema: ColumnSchema) {
        textCell.alignment = schema.type == .number ? .right : .left
        textCell.textColor = .labelColor
        textCell.displayString = displayValue(value, schema: schema)

        switch schema.type {
        case .url:
            textCell.textColor = .linkColor
        case .select, .multiSelect, .status:
            textCell.textColor = colorForTag(value, schema: schema)
        case .checkbox:
            textCell.alignment = .center
        default:
            break
        }
    }

    private func rawValueForEditedText(_ text: String, columnIndex: Int, rawValue: String) -> String {
        guard let tableDocument,
              tableDocument.headers.indices.contains(columnIndex) else {
            return text
        }
        let columnSchema = schema.schema(for: tableDocument.headers[columnIndex])
        if text == displayValue(rawValue, schema: columnSchema) {
            return rawValue
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

    private func displayValueForRawValue(_ value: String, columnIndex: Int) -> String {
        guard let tableDocument,
              tableDocument.headers.indices.contains(columnIndex) else {
            return value
        }
        let columnSchema = metadata.schemaEnabled ? schema.schema(for: tableDocument.headers[columnIndex]) : ColumnSchema(type: .text)
        return displayValue(value, schema: columnSchema)
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
        return color(forOptionName: name, schema: schema)
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
            if ["csv", "tsv", "tab", "json", "jsonl", "ndjson", "xlsx", "parquet", "pq"].contains(ext) {
                return url
            }
        }
        return nil
    }
}

extension MainWindowController: NSPopoverDelegate {
    /// Multi-select edits are batched: the popover stays open while the user toggles
    /// checkboxes, and the joined value is written back once on close (a single undo).
    func popoverDidClose(_ notification: Notification) {
        guard let draft = multiSelectDraft else { return }
        multiSelectDraft = nil
        multiSelectPopover = nil
        let joined = draft.order.filter { draft.selected.contains($0) }.joined(separator: draft.separator)
        guard joined != draft.original else { return }
        performUndoableCellValue(joined, documentRow: draft.documentRow, column: draft.columnIndex, actionName: "Edit Multi-select")
    }
}

private extension NSToolbarItem.Identifier {
    static let newTab = NSToolbarItem.Identifier("LightDataNewTab")
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
