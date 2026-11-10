import AppKit
import XCTest
@testable import LightData
import LightDataCore

/// Integration tests hosted inside the real app process: each test drives an actual
/// MainWindowController — real window, real table view, real undo stack, real files
/// on disk — through the same internal entry points the UI uses. This is the
/// automated replacement for the manual regression checklist (edit/undo/close/types).
///
/// Modal alerts and browser-opening are injected via the controller's seams
/// (`presentAlert` / `openExternalURL`) so nothing blocks the test runner.
final class MainWindowControllerTests: XCTestCase {
    private var tempDir: URL!
    private var controller: MainWindowController!

    override func setUpWithError() throws {
        tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("lightdata-apptests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        controller = MainWindowController()
        // Fail loudly if any code path still reaches a real modal.
        controller.presentAlert = { alert in
            XCTFail("unexpected modal alert: \(alert.messageText)")
            return .alertSecondButtonReturn
        }
        controller.showWindow(nil)
    }

    override func tearDownWithError() throws {
        controller.tableDocument = nil   // silence close-prompt paths
        controller.close()
        controller = nil
        try? FileManager.default.removeItem(at: tempDir)
    }

    // MARK: - Helpers

    @discardableResult
    private func openCSV(_ content: String = "name,age,city\nAlice,30,NYC\nBob,25,LA\nCarol,41,SF\n",
                         name: String = "doc.csv") throws -> URL {
        let url = tempDir.appendingPathComponent(name)
        try Data(content.utf8).write(to: url)
        controller.open(url: url)
        XCTAssertNotNil(controller.tableDocument, "fixture must open")
        return url
    }

    private func enableEditing() {
        controller.editLocked = false
    }

    /// First visible (table) column showing document column `dataColumn`.
    private func visibleColumn(forData dataColumn: Int) -> Int {
        let index = controller.tableView.tableColumns.firstIndex {
            Int($0.identifier.rawValue) == dataColumn
        }
        XCTAssertNotNil(index)
        return index ?? -1
    }

    private func pumpRunLoop(seconds: TimeInterval = 0.05) {
        RunLoop.main.run(until: Date().addingTimeInterval(seconds))
    }

    // MARK: - Inline editor: snapshot commit

    func testEditorCommitSurvivesFullReload() throws {
        try openCSV()
        enableEditing()
        controller.selectCellRange(from: (0, visibleColumn(forData: 0)), to: (0, visibleColumn(forData: 0)))
        controller.editSelectedCell(initialText: "EDITED")
        let editor = try XCTUnwrap(controller.activeCellEditor, "editor must open")

        // A full reload recycles every cell view — the editor's weak source now either
        // represents some other cell or is gone. Commit must still write (0,0).
        controller.tableView.reloadData()
        controller.inlineCellEditorDidCommit(editor)

        let doc = try XCTUnwrap(controller.tableDocument)
        XCTAssertEqual(doc.rows[0][0], "EDITED", "value lands in the ORIGINAL cell")
        XCTAssertEqual(doc.rows[1][0], "Bob", "no other cell touched")
        XCTAssertNil(controller.activeCellEditor, "editor torn down")
        XCTAssertNil(editor.superview, "editor removed from hierarchy")
    }

    func testEditorCommitSurvivesColumnRebuild() throws {
        try openCSV()
        enableEditing()
        controller.selectCellRange(from: (1, visibleColumn(forData: 1)), to: (1, visibleColumn(forData: 1)))
        controller.editSelectedCell(initialText: "99")
        let editor = try XCTUnwrap(controller.activeCellEditor)

        // buildColumns() removes every NSTableColumn — the zombie-editor scenario.
        controller.buildColumns()
        controller.tableView.reloadData()
        controller.inlineCellEditorDidCommit(editor)

        XCTAssertEqual(controller.tableDocument?.rows[1][1], "99")
        XCTAssertNil(controller.activeCellEditor, "no zombie editor")
        XCTAssertNil(editor.superview)
    }

    func testEditorUsesPrivateUndoManagerNotDocumentStack() throws {
        try openCSV()
        enableEditing()
        controller.selectCellRange(from: (0, visibleColumn(forData: 0)), to: (0, visibleColumn(forData: 0)))
        controller.editSelectedCell(initialText: nil)
        let editor = try XCTUnwrap(controller.activeCellEditor)

        XCTAssertNotNil(editor.undoManager)
        XCTAssertFalse(editor.undoManager === controller.documentUndoManager,
                       "editor keystrokes must not pollute the document undo stack")
        controller.inlineCellEditorDidCancel(editor)
    }

    func testCommittedEditIsUndoable() throws {
        try openCSV()
        enableEditing()
        controller.selectCellRange(from: (0, visibleColumn(forData: 2)), to: (0, visibleColumn(forData: 2)))
        controller.editSelectedCell(initialText: "Tokyo")
        let editor = try XCTUnwrap(controller.activeCellEditor)
        controller.inlineCellEditorDidCommit(editor)

        XCTAssertEqual(controller.tableDocument?.rows[0][2], "Tokyo")
        XCTAssertTrue(controller.documentUndoManager.canUndo)
        controller.documentUndoManager.undo()
        XCTAssertEqual(controller.tableDocument?.rows[0][2], "NYC")
        controller.documentUndoManager.redo()
        XCTAssertEqual(controller.tableDocument?.rows[0][2], "Tokyo")
    }

    // MARK: - Close prompt

    private func makeDirty() throws {
        enableEditing()
        controller.selectCellRange(from: (0, visibleColumn(forData: 0)), to: (0, visibleColumn(forData: 0)))
        controller.editSelectedCell(initialText: "changed")
        let editor = try XCTUnwrap(controller.activeCellEditor)
        controller.inlineCellEditorDidCommit(editor)
        XCTAssertEqual(controller.tableDocument?.dirty, true)
    }

    func testCloseWithCleanDocumentNeedsNoPrompt() throws {
        try openCSV()
        // presentAlert seam XCTFails on any alert — passing means no prompt shown.
        XCTAssertTrue(controller.windowShouldClose(controller.window!))
    }

    func testClosePromptCancelVetoesClose() throws {
        try openCSV()
        try makeDirty()
        controller.presentAlert = { _ in .alertSecondButtonReturn }   // Cancel
        XCTAssertFalse(controller.windowShouldClose(controller.window!))
        XCTAssertEqual(controller.tableDocument?.dirty, true, "edits retained")
    }

    func testClosePromptDontSaveAllowsCloseWithoutWriting() throws {
        let url = try openCSV()
        try makeDirty()
        controller.presentAlert = { _ in .alertThirdButtonReturn }    // Don't Save
        XCTAssertTrue(controller.windowShouldClose(controller.window!))
        let onDisk = try String(contentsOf: url, encoding: .utf8)
        XCTAssertTrue(onDisk.contains("Alice"), "file untouched")
        XCTAssertFalse(onDisk.contains("changed"))
    }

    func testClosePromptSaveWritesAndCloses() throws {
        let url = try openCSV()
        try makeDirty()
        controller.presentAlert = { _ in .alertFirstButtonReturn }    // Save
        XCTAssertTrue(controller.windowShouldClose(controller.window!))
        XCTAssertEqual(controller.tableDocument?.dirty, false)
        let onDisk = try String(contentsOf: url, encoding: .utf8)
        XCTAssertTrue(onDisk.contains("changed"), "edits persisted to disk")
    }

    // MARK: - Save with open editor

    func testSaveWithOpenEditorWritesLatestText() throws {
        let url = try openCSV()
        enableEditing()
        controller.selectCellRange(from: (0, visibleColumn(forData: 0)), to: (0, visibleColumn(forData: 0)))
        controller.editSelectedCell(initialText: "Typed")
        XCTAssertNotNil(controller.activeCellEditor)
        controller.saveDocument()                          // ⌘S, editor still open
        XCTAssertNil(controller.activeCellEditor)
        XCTAssertEqual(controller.tableDocument?.dirty, false)
        XCTAssertTrue(try String(contentsOf: url, encoding: .utf8).contains("Typed"))
    }

    func testSaveAsSnapshotIncludesOpenEditorText() throws {
        try openCSV()
        enableEditing()
        controller.selectCellRange(from: (1, visibleColumn(forData: 2)), to: (1, visibleColumn(forData: 2)))
        controller.editSelectedCell(initialText: "Paris")
        let snapshot = try XCTUnwrap(controller.documentSnapshotForSaveAs())
        XCTAssertEqual(snapshot.rows[1][2], "Paris")
    }

    func testQuitWithOpenEditorPromptsAndSavesTypedText() throws {
        let url = try openCSV()                            // clean document
        enableEditing()
        controller.selectCellRange(from: (0, visibleColumn(forData: 0)), to: (0, visibleColumn(forData: 0)))
        controller.editSelectedCell(initialText: "Typed")
        var prompted = false
        controller.presentAlert = { _ in prompted = true; return .alertFirstButtonReturn }  // Save
        XCTAssertTrue(controller.confirmDiscardingUnsavedChanges())
        XCTAssertTrue(prompted, "uncommitted text makes the doc dirty → must prompt")
        XCTAssertTrue(try String(contentsOf: url, encoding: .utf8).contains("Typed"))
    }

    func testSaveWithInvalidTypedEditorKeepsOldValue() throws {
        let url = try openCSV()
        enableEditing()
        controller.metadata.schemaEnabled = true
        let doc = try XCTUnwrap(controller.tableDocument)
        controller.schema.setType(.number, for: "age", sampleValues: doc.rows.map { $0[1] })
        controller.selectCellRange(from: (0, visibleColumn(forData: 1)), to: (0, visibleColumn(forData: 1)))
        controller.editSelectedCell(initialText: "abc")
        XCTAssertNotNil(controller.activeCellEditor)
        controller.saveDocument()
        XCTAssertEqual(controller.tableDocument?.rows[0][1], "30")
        XCTAssertFalse(try String(contentsOf: url, encoding: .utf8).contains("abc"))
    }

    // MARK: - Column operations & undo consistency

    func testDeleteColumnIsUndoableAndRestoresValues() throws {
        try openCSV()
        enableEditing()
        let before = controller.tableDocument!.rows

        controller.performUndoableDeleteColumn(at: 1, actionName: "Delete Column")
        XCTAssertEqual(controller.tableDocument?.headers, ["name", "city"])
        XCTAssertEqual(controller.tableDocument?.rows[0], ["Alice", "NYC"])

        controller.documentUndoManager.undo()
        XCTAssertEqual(controller.tableDocument?.headers, ["name", "age", "city"])
        XCTAssertEqual(controller.tableDocument?.rows, before, "all column values restored")
    }

    func testRenameColumnMigratesMetadataAndUndoes() throws {
        try openCSV()
        enableEditing()
        // Set up REAL view state (metadata is captured from the live table, so
        // hand-written dictionary entries would just be overwritten):
        controller.tableView.moveColumn(visibleColumn(forData: 1), toColumn: 1)   // age first
        controller.tableView.tableColumns[visibleColumn(forData: 1)].width = 222
        controller.schema.columns["age"] = ColumnSchema(type: .number)
        controller.tableView.sortDescriptors = [NSSortDescriptor(key: "1", ascending: true)]
        XCTAssertEqual(controller.metadata.columnWidths["age"], 222)
        XCTAssertEqual(controller.metadata.columnOrder.first, "age")
        XCTAssertEqual(controller.metadata.sortColumnName, "age")

        controller.performUndoableRenameColumn(at: 1, to: "years", actionName: "Rename Column")

        XCTAssertEqual(controller.tableDocument?.headers[1], "years")
        XCTAssertEqual(controller.metadata.columnWidths["years"], 222, "width follows the rename")
        XCTAssertNil(controller.metadata.columnWidths["age"])
        XCTAssertEqual(controller.metadata.columnOrder.first, "years", "custom order follows the rename")
        XCTAssertEqual(controller.metadata.sortColumnName, "years",
                       "sort follows the rename via the live descriptor")
        XCTAssertEqual(controller.schema.columns["years"]?.type, .number)

        controller.documentUndoManager.undo()
        XCTAssertEqual(controller.tableDocument?.headers[1], "age")
        XCTAssertEqual(controller.metadata.columnWidths["age"], 222)
        XCTAssertEqual(controller.metadata.columnOrder.first, "age")
        XCTAssertEqual(controller.schema.columns["age"]?.type, .number)
    }

    func testRenameCollisionLeavesOtherColumnAlone() throws {
        try openCSV()
        enableEditing()
        controller.performUndoableRenameColumn(at: 0, to: "city", actionName: "Rename Column")
        XCTAssertEqual(controller.tableDocument?.headers, ["city 2", "age", "city"],
                       "the OTHER 'city' column keeps its name")
    }

    // MARK: - Trailing grid line geometry

    func testTrailingGridLineTracksProgrammaticColumnResize() throws {
        try openCSV()
        let lastColumn = controller.tableView.numberOfColumns - 1

        controller.tableView.tableColumns[lastColumn].width += 77
        controller.headerDragTick()   // what the 60Hz drag poll invokes

        let edgeX = controller.tableView.rect(ofColumn: lastColumn).maxX
        let expected = controller.tableView.convert(NSPoint(x: edgeX, y: 0), to: controller.selectionOverlayView).x
        XCTAssertFalse(controller.trailingGridLine.isHidden)
        XCTAssertEqual(controller.trailingGridLine.frame.midX, expected, accuracy: 1.0,
                       "grid line must sit on the last column's edge after a resize")
    }

    // MARK: - URL cells

    func testCmdClickOpensLinkThroughSeam() throws {
        try openCSV("name,site\nAnthropic,https://www.anthropic.com/claude\n", name: "urls.csv")
        controller.metadata.schemaEnabled = true
        controller.schema.columns["site"] = ColumnSchema(type: .url)
        controller.buildColumns()
        controller.rebuildVisibleRows()

        var opened: URL?
        controller.openExternalURL = { opened = $0 }

        let siteColumn = visibleColumn(forData: 1)
        // Materialize the cell view (openLink reads the prepared URLCellView).
        _ = controller.tableView.view(atColumn: siteColumn, row: 0, makeIfNecessary: true)
        XCTAssertTrue(controller.openLink(atVisibleRow: 0, visibleColumn: siteColumn))
        XCTAssertEqual(opened?.absoluteString, "https://www.anthropic.com/claude")

        // Non-URL column: not consumed, nothing opened.
        opened = nil
        _ = controller.tableView.view(atColumn: visibleColumn(forData: 0), row: 0, makeIfNecessary: true)
        XCTAssertFalse(controller.openLink(atVisibleRow: 0, visibleColumn: visibleColumn(forData: 0)))
        XCTAssertNil(opened)
    }

    // MARK: - View state regressions

    func testResetViewKeepsDirtyFlag() throws {
        try openCSV()
        try makeDirty()
        controller.resetViewClicked(nil)
        XCTAssertEqual(controller.tableDocument?.dirty, true,
                       "Reset View must not silently drop the unsaved-changes marker")
    }

    func testHeaderToggleRefreshesFilterColumnPopup() throws {
        try openCSV()
        XCTAssertEqual(controller.columnPopup.itemTitles, ["name", "age", "city"])
        controller.toggleFirstRowHeaderClicked(nil)
        XCTAssertEqual(controller.columnPopup.itemTitles, ["Column 1", "Column 2", "Column 3"],
                       "filter popup must follow the header toggle")
        controller.toggleFirstRowHeaderClicked(nil)
        XCTAssertEqual(controller.columnPopup.itemTitles, ["name", "age", "city"])
    }

    func testReloadDismissesTextSelectionOverlay() throws {
        try openCSV()
        let cell = DataTextCellView()
        cell.displayString = "Alice"
        let overlay = CellTextSelectionOverlay(cellView: cell, frame: NSRect(x: 0, y: 0, width: 80, height: 24))
        controller.tableView.addSubview(overlay)
        controller.activeTextSelectionView = overlay

        controller.tableView.reloadData()

        XCTAssertNil(controller.activeTextSelectionView, "reload must dismiss the overlay")
        XCTAssertNil(overlay.superview, "orphan overlay removed from the hierarchy")
    }

    // MARK: - Large-cell display previews

    func testEditorOpensWithFullValueNotTruncatedPreview() throws {
        // A cell far larger than the display cap: the preview truncates for drawing
        // speed, but editing MUST round-trip the complete raw value.
        let hugeValue = (0..<300).map { "segment \($0)" }.joined(separator: " ")
        XCTAssertGreaterThan(hugeValue.count, 1000)
        try openCSV("a,b\n\"\(hugeValue)\",x\n", name: "huge.csv")
        enableEditing()
        controller.selectCellRange(from: (0, visibleColumn(forData: 0)), to: (0, visibleColumn(forData: 0)))
        controller.editSelectedCell(initialText: nil)
        let editor = try XCTUnwrap(controller.activeCellEditor)

        XCTAssertEqual(editor.string, hugeValue, "editor gets the full value, not the display preview")
        // Commit unchanged → document identical, not truncated.
        controller.inlineCellEditorDidCommit(editor)
        XCTAssertEqual(controller.tableDocument?.rows[0][0], hugeValue)
        XCTAssertEqual(controller.tableDocument?.dirty, false, "no-op commit must not dirty the file")
    }

    func testDisplayPreviewCapsAndFlattens() {
        let long = String(repeating: "x", count: 2000)
        let preview = MainWindowController.displayPreview(long)
        XCTAssertEqual(preview.count, 513, "512 chars + ellipsis")
        XCTAssertTrue(preview.hasSuffix("…"))

        XCTAssertEqual(MainWindowController.displayPreview("line1\nline2"), "line1 line2",
                       "newlines flatten for the one-line cell")
        XCTAssertEqual(MainWindowController.displayPreview("short"), "short", "short values untouched")
    }

    // MARK: - Add Column end to end

    func testAddColumnInsertsSelectsAndUndoes() throws {
        try openCSV()
        enableEditing()
        controller.selectColumnRange(from: visibleColumn(forData: 0), to: visibleColumn(forData: 0))
        controller.addColumnClicked(nil)

        XCTAssertEqual(controller.tableDocument?.headers, ["name", "Column 4", "age", "city"],
                       "inserted right of the selected column")
        XCTAssertEqual(controller.tableDocument?.rows[0], ["Alice", "", "30", "NYC"])

        controller.documentUndoManager.undo()
        XCTAssertEqual(controller.tableDocument?.headers, ["name", "age", "city"])
    }
}
