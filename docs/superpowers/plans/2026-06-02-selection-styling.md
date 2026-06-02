# Selection Styling + Column Interaction Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Give LightData a clean, native-feeling selection appearance (cell / row / column / whole-table) and fix two column interactions: selection box following column-width drag, and column drag-reorder in edit mode.

**Architecture:** Drive all background/anchor tinting from the app's authoritative `selectionRange` + `selectionMode` (via `applySelectionStyle` / `refreshVisibleCellSelectionStyles`); `SelectionOverlayView` only draws the crisp rounded border for cell/range selection. Add a `.all` selection mode triggered by the top-left corner. Fix `tableViewColumnDidResize` to refresh the overlay, and gate/repair native column reordering.

**Tech Stack:** Swift 6 (language mode v5), AppKit, single file `Sources/LightData/MainWindowController.swift`.

**Testing note:** No test target exists; this is AppKit rendering/interaction code. Each task is verified by `swift build` then a manual check in `.build/debug/LightData /tmp/lightdata_test.csv`. Create the test file first if missing:
`printf 'name,age,city\nAlice,30,NYC\nBob,25,LA\nCarol,28,SF\n' > /tmp/lightdata_test.csv`

Accent color throughout: `NSColor.controlAccentColor`. Body tint = `controlAccentColor.withAlphaComponent(0.10)`. Anchor = solid `controlAccentColor` + white text.

---

## Task 1: Add `.all` selection mode + select-all model

**Files:**
- Modify: `Sources/LightData/MainWindowController.swift` — `TableSelectionMode` (~195), `selectColumnRange`/selection helpers area (~889), add `selectAll`.

- [ ] **Step 1: Add `.all` case to the mode enum**

```swift
private enum TableSelectionMode {
    case cells
    case rows
    case columns
    case all
}
```

- [ ] **Step 2: Add a `selectAll` method** (place next to `selectColumnRange`, ~line 905)

```swift
func selectAllCells() {
    removeActiveTextSelectionView()
    removeActiveCellEditor(commit: true)
    guard !visibleRows.isEmpty else { return }
    let dataColumns = dataVisibleColumnIndexes()
    guard !dataColumns.isEmpty else { return }
    selectionMode = .all
    selectionRange = TableSelectionRange(
        mode: .all,
        rows: IndexSet(integersIn: 0..<visibleRows.count),
        columns: dataColumns
    )
    tableView.selectRowIndexes(selectionRange.rows, byExtendingSelection: false)
    window?.makeFirstResponder(tableView)
    refreshVisibleSelectionAppearance()
    updateToolbarState()
}
```

- [ ] **Step 3: Build**

Run: `swift build`
Expected: `Build complete!` (no behavior change yet; `.all` unused — compiler may warn about non-exhaustive switches; fix any switch over `TableSelectionMode` to add an `.all` branch if the build errors).

- [ ] **Step 4: Commit**

```bash
git add Sources/LightData/MainWindowController.swift
git commit -m "feat: add .all selection mode and selectAllCells"
```

---

## Task 2: Body tint + anchor styling across all states

Make data text cells tintable, and route row/column/all body+anchor tinting through the existing style refresh.

**Files:**
- Modify: `Sources/LightData/MainWindowController.swift` — `DataTextCellView` (draw + new property), `applySelectionStyle` (~1877), `isSelectionHighlighted` (~1891), `refreshVisibleCellSelectionStyles` (~2240), `viewFor` default branch (~778).

- [ ] **Step 1: Add `selectionFill` to `DataTextCellView` and paint it**

In `DataTextCellView`, add the property near the other display vars:

```swift
    var selectionFill: NSColor? {
        didSet { needsDisplay = true }
    }
```

In `DataTextCellView.draw(_:)`, paint the fill before the text:

```swift
    override func draw(_ dirtyRect: NSRect) {
        super.draw(dirtyRect)
        if let selectionFill {
            selectionFill.setFill()
            NSBezierPath(rect: bounds).fill()
        }
        drawDisplayString(color: textColor, clippedTo: nil)
    }
```

- [ ] **Step 2: Replace `isSelectionHighlighted` with anchor/body queries**

Replace the existing `isSelectionHighlighted(visibleRow:visibleColumn:)` with two helpers:

```swift
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
```

- [ ] **Step 3: Rewrite `applySelectionStyle` to handle anchor row-number cells**

```swift
    private func applySelectionStyle(to cell: NSTableCellView, visibleRow: Int, visibleColumn: Int) {
        if visibleColumn == 0 {
            let anchor = isAnchorCell(visibleRow: visibleRow, visibleColumn: visibleColumn)
            cell.wantsLayer = true
            cell.layer?.backgroundColor = anchor ? NSColor.controlAccentColor.cgColor : NSColor.clear.cgColor
            cell.textField?.textColor = anchor ? .white : .secondaryLabelColor
            cell.textField?.font = .systemFont(ofSize: 13, weight: anchor ? .semibold : .regular)
        } else {
            // Typed data cells (checkbox/popup/url) that are NSTableCellView get the body tint.
            let body = isBodyCell(visibleRow: visibleRow, visibleColumn: visibleColumn)
            cell.wantsLayer = true
            cell.layer?.backgroundColor = body ? NSColor.controlAccentColor.withAlphaComponent(0.10).cgColor : NSColor.clear.cgColor
        }
    }
```

- [ ] **Step 4: Style `DataTextCellView` body tint in the refresh loop**

In `refreshVisibleCellSelectionStyles`, handle both cell kinds. Replace the inner cast/apply with:

```swift
        for row in rowRange.location..<upperRow {
            for column in 0..<tableView.numberOfColumns {
                let view = tableView.view(atColumn: column, row: row, makeIfNecessary: false)
                if let cell = view as? DataTextCellView {
                    cell.selectionFill = isBodyCell(visibleRow: row, visibleColumn: column)
                        ? NSColor.controlAccentColor.withAlphaComponent(0.10) : nil
                } else if let cell = view as? NSTableCellView {
                    applySelectionStyle(to: cell, visibleRow: row, visibleColumn: column)
                }
            }
        }
```

- [ ] **Step 5: Set initial body tint when a data text cell is created**

In `viewFor`, default branch (after `cell.rawValue = value`, ~line 784), add:

```swift
            cell.selectionFill = isBodyCell(visibleRow: row, visibleColumn: visibleColumn)
                ? NSColor.controlAccentColor.withAlphaComponent(0.10) : nil
```

- [ ] **Step 6: Build**

Run: `swift build`
Expected: `Build complete!`

- [ ] **Step 7: Manual verify**

Run app. Select a whole row (click row number) → row-number cell solid blue + white, the row's data cells light blue. Select via header (column) → that column's data cells light blue. (Cell selection still shows old border for now — Task 4.)

- [ ] **Step 8: Commit**

```bash
git add Sources/LightData/MainWindowController.swift
git commit -m "feat: body tint + anchor styling for row/column/all selection"
```

---

## Task 3: Column header solid-blue with white text

**Files:**
- Modify: `Sources/LightData/MainWindowController.swift` — `DataTableHeaderView.draw` (~569), `drawSortButtons` (~599), and how `highlightedColumns` is set (`refreshVisibleSelectionAppearance` ~2240).

- [ ] **Step 1: Set `highlightedColumns` for column AND all modes**

In `refreshVisibleSelectionAppearance`, change the header line:

```swift
        if let headerView = tableView.headerView as? DataTableHeaderView {
            headerView.highlightedColumns = (selectionRange.mode == .columns || selectionRange.mode == .all)
                ? selectionRange.columns : []
        }
```

- [ ] **Step 2: Draw solid accent + white title for highlighted columns**

Replace the `if !highlightedColumns.isEmpty { ... }` block in `DataTableHeaderView.draw` with:

```swift
        if !highlightedColumns.isEmpty, let tableView {
            let columnCount = tableView.numberOfColumns
            for column in highlightedColumns where column >= 0 && column < columnCount {
                let rect = headerRect(ofColumn: column)
                NSColor.controlAccentColor.setFill()
                NSBezierPath(rect: rect).fill()

                let title = tableView.tableColumns[column].title
                let style = NSMutableParagraphStyle()
                style.alignment = .left
                style.lineBreakMode = .byTruncatingTail
                let attrs: [NSAttributedString.Key: Any] = [
                    .font: NSFont.systemFont(ofSize: 13, weight: .semibold),
                    .foregroundColor: NSColor.white,
                    .paragraphStyle: style
                ]
                let textRect = rect.insetBy(dx: 8, dy: 0)
                let size = (title as NSString).size(withAttributes: attrs)
                let drawRect = NSRect(x: textRect.minX, y: rect.midY - size.height / 2, width: textRect.width, height: size.height)
                (title as NSString).draw(in: drawRect, withAttributes: attrs)
            }
        }
```

- [ ] **Step 3: White sort arrow on highlighted columns**

In `drawSortButtons`, make the arrow visible on the blue header:

```swift
            let onHighlighted = highlightedColumns.contains(column)
            let color = onHighlighted ? NSColor.white
                : (isActive ? NSColor.controlAccentColor : NSColor.tertiaryLabelColor)
            color.setFill()
```

- [ ] **Step 4: Build + manual verify**

Run: `swift build` → run app. Click a column header → header turns solid blue with white title; column body light blue. Whole-table (after Task 5 wires the corner) will also show blue headers.

- [ ] **Step 5: Commit**

```bash
git add Sources/LightData/MainWindowController.swift
git commit -m "feat: solid accent column header with white title for column/all selection"
```

---

## Task 4: Rounded crisp cell border, cells-mode only

**Files:**
- Modify: `Sources/LightData/MainWindowController.swift` — `SelectionOverlayView.draw` (~266).

- [ ] **Step 1: Restrict overlay to cells mode and round the border**

Replace the body of `SelectionOverlayView.draw(_:)` after the existing guard with a mode check and rounded path. Update the guard to also require cells mode:

```swift
    override func draw(_ dirtyRect: NSRect) {
        super.draw(dirtyRect)
        guard let tableView,
              selectionRange.mode == .cells,
              !selectionRange.isEmpty,
              let firstRow = selectionRange.rows.min(),
              let lastRow = selectionRange.rows.max(),
              let firstColumn = selectionRange.columns.min(),
              let lastColumn = selectionRange.columns.max(),
              firstRow >= 0, lastRow < tableView.numberOfRows,
              firstColumn >= 0, lastColumn < tableView.numberOfColumns else {
            return
        }

        let rowRect = tableView.rect(ofRow: firstRow).union(tableView.rect(ofRow: lastRow))
        let columnRect = tableView.rect(ofColumn: firstColumn).union(tableView.rect(ofColumn: lastColumn))
        let tableRect = rowRect.intersection(columnRect)
        guard !tableRect.isNull, !tableRect.isEmpty else { return }

        let overlayRect = tableView.convert(tableRect, to: self).insetBy(dx: 1, dy: 1)
        let path = NSBezierPath(roundedRect: overlayRect, xRadius: 2.5, yRadius: 2.5)
        path.lineWidth = 2
        NSColor.controlAccentColor.setStroke()
        path.stroke()
    }
```

- [ ] **Step 2: Build + manual verify**

Run: `swift build` → run app. Single cell selection = rounded 2px blue border, no fill. Row/column/all selection no longer draws the big hard rectangle (only body tint + anchors from Tasks 2–3).

- [ ] **Step 3: Commit**

```bash
git add Sources/LightData/MainWindowController.swift
git commit -m "feat: rounded cell selection border, cells mode only"
```

---

## Task 5: Whole-table select via top-left corner

**Files:**
- Modify: `Sources/LightData/MainWindowController.swift` — corner view setup in `buildInterface` (~1575 `tableView.cornerView = NSView()`), add a small `CornerSelectButton` class, wire click to `selectAllCells`.

- [ ] **Step 1: Add a clickable corner view class** (near the other small view subclasses, e.g. after `DropView`)

```swift
final class CornerSelectButton: NSView {
    var onClick: (() -> Void)?
    override func mouseDown(with event: NSEvent) { onClick?() }
    override func draw(_ dirtyRect: NSRect) {
        NSColor.clear.setFill()
        dirtyRect.fill()
    }
}
```

- [ ] **Step 2: Install it as the corner view**

Replace `tableView.cornerView = NSView()` in `buildInterface` with:

```swift
        let corner = CornerSelectButton()
        corner.onClick = { [weak self] in self?.selectAllCells() }
        tableView.cornerView = corner
```

- [ ] **Step 3: Build + manual verify**

Run: `swift build` → run app. Click the top-left corner (above the row numbers) → all headers + all row-number cells turn solid blue, all data cells light blue (whole-table selection).

- [ ] **Step 4: Verify copy-all**

Select-all via corner, press `⌘C`, paste into a text editor → full table (all rows × columns) is copied.

- [ ] **Step 5: Commit**

```bash
git add Sources/LightData/MainWindowController.swift
git commit -m "feat: whole-table selection via top-left corner"
```

---

## Task 6: Selection box follows column-width drag

**Files:**
- Modify: `Sources/LightData/MainWindowController.swift` — `tableViewColumnDidResize` (~804).

- [ ] **Step 1: Refresh selection appearance on resize**

```swift
    func tableViewColumnDidResize(_ notification: Notification) {
        updateActiveCellEditorFrame()
        refreshVisibleSelectionAppearance()
        captureMetadata()
    }
```

- [ ] **Step 2: Build + manual verify**

Run: `swift build` → run app. Select a cell, then drag the width of its column → the rounded blue border tracks the new column width in real time. Same for row/column body tint.

- [ ] **Step 3: Commit**

```bash
git add Sources/LightData/MainWindowController.swift
git commit -m "fix: selection box follows column width drag"
```

---

## Task 7: Column drag-reorder in edit mode

Gate reordering to edit mode and ensure the custom header mouse handling does not block NSTableView's native column drag.

**Files:**
- Modify: `Sources/LightData/MainWindowController.swift` — `shouldReorderColumn` (~825), `DataTableHeaderView.mouseDown` (~550).

- [ ] **Step 1: Gate reorder to edit mode**

```swift
    func tableView(_ tableView: NSTableView, shouldReorderColumn columnIndex: Int, toColumn newColumnIndex: Int) -> Bool {
        isEditingEnabled && isDataVisibleColumn(columnIndex) && newColumnIndex > 0
    }
```

- [ ] **Step 2: Verify whether native drag works after gating**

Run: `swift build` → run app, enter edit mode, try dragging a column header to a new position.
- If it reorders: skip to Step 4.
- If it does NOT reorder, the custom `DataTableHeaderView.mouseDown` is interfering — continue to Step 3.

- [ ] **Step 3: Let native drag drive; select column without disrupting tracking**

Reorder `DataTableHeaderView.mouseDown` so the sort-button check stays first, but column selection happens via `super.mouseDown` driving the drag, and our selection is applied without stealing first responder mid-drag. Replace the non-sort branch:

```swift
    override func mouseDown(with event: NSEvent) {
        let point = convert(event.locationInWindow, from: nil)
        let column = self.column(at: point)
        guard column >= 0 else {
            super.mouseDown(with: event)
            return
        }

        if tableView?.tableColumns[column].identifier.rawValue != "rowNumber",
           sortButtonRect(forColumn: column).contains(point) {
            columnActionHandler?.toggleSort(forVisibleColumn: column)
            return
        }

        columnActionHandler?.clearSortForHeaderSelection()
        // Let NSTableHeaderView run its own tracking (selection highlight + native
        // column drag). Apply our selection model without grabbing first responder
        // mid-event, which previously cancelled the drag.
        selectionHandler?.selectColumnRange(from: column, to: column)
        super.mouseDown(with: event)
    }
```

If `selectColumnRange`'s `window?.makeFirstResponder(tableView)` is the disruptor, add a parameter to skip it when called from the header:

```swift
    func selectColumnRange(from startColumn: Int, to endColumn: Int, takeFocus: Bool = true) {
        // ... existing body ...
        if takeFocus { window?.makeFirstResponder(tableView) }
        // ...
    }
```

and call `selectionHandler?.selectColumnRange(from: column, to: column)` with the protocol updated to include `takeFocus`. Re-test the drag; pick whichever of (a) call order or (b) skipping focus actually lets the drag proceed (confirm by manual drag).

- [ ] **Step 4: Verify edit-mode-only + persistence**

Run app:
- Edit mode: drag a column to a new position → order changes; `Save` (⌘S) then reopen → new order persisted (via existing `tableViewColumnDidMove` → `documentColumnOrderDirty`).
- Read-only mode: dragging a column header does NOT reorder.
- Clicking a header still selects the column (solid blue) and the sort caret still sorts.

- [ ] **Step 5: Commit**

```bash
git add Sources/LightData/MainWindowController.swift
git commit -m "feat: column drag-reorder in edit mode only"
```

---

## Final regression pass

- [ ] Run app and confirm: cell edit (Enter/double-click/typing), arrow-key movement (incl. right after Enter-edit-Enter), read-only double-click no-op, edit↔read-only toggle no ghosting, toolbar buttons don't flicker, copy row/column/all, delete rows. Log (`2>/tmp/lightdata.log`) shows no `rejected` and no `Column selection` warning.

## Self-Review notes
- Spec coverage: visual规范(Tasks 2–4), 拖宽跟随(Task 6), 全选整表(Tasks 1+5), 列排序仅编辑模式(Task 7) — all covered.
- Type consistency: `selectAllCells`, `isAnchorCell`/`isBodyCell`, `selectionFill`, `CornerSelectButton` used consistently across tasks.
- Body tint constant `controlAccentColor.withAlphaComponent(0.10)` used identically in Tasks 2 and 4-adjacent code.
