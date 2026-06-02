# LightData 选区视觉重做 + 列交互优化 — 设计

## Context

LightData 的表格(自定义 view-based `NSTableView`)当前选区指示比较粗糙、不够"现代苹果原生":
- 单元格/区域选中只是 `SelectionOverlayView` 描了个**直角、纯色、无圆角**的蓝框,显硬。
- 行选中只把**行号格**染了 20% 淡蓝(`applySelectionStyle` 仅处理 `visibleColumn == 0`),行身数据格没有任何高亮。
- 列选中表头是 16% 半透明淡蓝 + 下划线,偏弱。
- 拖动列宽时选框不跟随(`tableViewColumnDidResize` 没刷新 overlay)。
- 编辑模式下列无法拖动调换顺序。
- 左上角(cornerView)是空的,没有"全选整表"。

目标:把四种选中状态(单元格/整行/整列/整表)统一成一套干净的原生风格,并修复两个列交互问题。改动集中在 `Sources/LightData/MainWindowController.swift`。

视觉方向已通过可视化对比与用户确认(见 `.superpowers/brainstorm/`)。

## 视觉规范(已确认)

强调色统一用 `NSColor.controlAccentColor`(下称 accent)。

| 状态 | 锚点(实心 accent + 白字) | 身(accent ~8% 淡色填充) | 边框 |
|------|--------------------------|--------------------------|------|
| 单元格 | — | 无填充(纯单元格底) | 2px accent 描边,圆角 ~3px |
| 整行 | 行号格 | 该行所有数据格 | — |
| 整列 | 列表头 | 该列所有数据格 | — |
| 整表 | 左上角 + 所有表头 + 所有行号格 | 所有数据格 | — |

## 设计：以 `selectionRange` 驱动全部着色

把所有"底色/锚点"着色统一由 `applySelectionStyle` 按 `selectionMode` + `selectionRange` 决定;`SelectionOverlayView` **只**负责单元格/区域(cells 模式)的圆角描边。

### 1. 数据格底色 — 让 `DataTextCellView` 支持选中填充
数据格是自定义绘制的 `DataTextCellView`(透明、`hitTest` 返回 nil、自己画文字),目前无法染背景。
- 新增属性 `var selectionFill: NSColor? { didSet { needsDisplay } }`。
- `draw(_:)` 中在 `drawDisplayString` 之前,若 `selectionFill != nil` 则填充 `bounds`(行身淡 accent)。
- 复用现有 `applySelectionStyle(to:visibleRow:visibleColumn:)`:扩展为对**所有可见列**生效(去掉 `guard visibleColumn == 0`),根据状态设置:
  - 行号格(`NSTableCellView`,`RowNumberCell`):锚点 → `layer.backgroundColor = accent`、`textField.textColor = white`;否则清空。
  - 数据格(`DataTextCellView`):`selectionFill = 身淡 accent` 或 `nil`。
- `isSelectionHighlighted` 扩展:支持 rows / columns / all 三种身着色判定 + 锚点判定(可拆成"是否锚点 / 是否身"两个查询)。

### 2. 表头实心蓝白字 — `DataTableHeaderView.draw`
当前用半透明填充让默认深色表头文字透出。改为锚点列(列选中/整表)用**实心 accent**,因此文字需变白:
- 选中列:不依赖默认绘制的深色标题——在 `draw` 里对锚点列填充实心 accent 后,**自行用白色重绘该列标题文字**(参照 `drawSortButtons` 的自绘方式);非选中列维持系统默认。
- 排序箭头在选中(蓝底)列上改用白色,保证可见。

### 3. 单元格圆角描边 — `SelectionOverlayView.draw`
- 仅在 `selectionMode == .cells` 时绘制;用 `NSBezierPath(roundedRect:xRadius:2.5 yRadius:2.5)`,`lineWidth = 2`,accent 描边,无填充。
- rows / columns / all 模式不再画整块硬边框(改由格子底色 + 锚点表达)。

### 4. 拖宽列时选框跟随 — `tableViewColumnDidResize`
在现有 `updateActiveCellEditorFrame()` / `captureMetadata()` 基础上,补 `refreshVisibleSelectionAppearance()`(会刷新 overlay 与可见格样式),使选框/底色随列宽实时适配。

### 5. 左上角全选整表 — cornerView
- 把 `tableView.cornerView` 从空 `NSView()` 换成一个可点击的角落视图(或在其上加点击处理),点击 → 新增 `selectAll`:`selectionMode = .all`(或等价:rows=全部、columns=全部数据列),刷新外观。
- `TableSelectionMode` 增加 `.all`;`selectionRange`/`isSelectionHighlighted`/`applySelectionStyle` 支持该模式(所有表头+行号格为锚点、全部数据格为身)。
- 用途以**复制整表**为主:`hasCopyableSelection` / 复制逻辑在 all 模式下覆盖全部行列(复用现有 `selectedDataVisibleColumns` + 全行)。不特别处理批量删除。

### 6. 编辑模式列拖动排序 —— 修复 + 限定
现状:`allowsColumnReordering = true`、`shouldReorderColumn` 已允许数据列;但实际拖不动,疑因 `DataTableHeaderView.mouseDown` 在调用 `super.mouseDown`(NSTableView 原生列拖动的入口)前先做了 `selectColumnRange`(内含 `makeFirstResponder` 等),干扰了原生拖动跟踪。
- **调查并修复** header 的 mouseDown:确保点击表头既能选列/排序,又不破坏原生列拖动(可能需要把选列推迟到判定为"非拖动"后,或调整调用顺序/避免在 mouseDown 中改 firstResponder)。
- `shouldReorderColumn` 增加 `isEditingEnabled` 限定:**仅编辑模式**可拖动排序;只读模式返回 false。
- 排序结果持久化沿用现有 `tableViewColumnDidMove`(已设 `documentColumnOrderDirty` / `dirty`,保存时写回文件)。

## 不在范围
- 选区/重绘的系统级重构;其余 reloadData 调用点。
- 只读模式下的列排序(本次仅编辑模式)。

## 验证
1. `swift build` → `.build/debug/LightData /tmp/lightdata_test.csv`。
2. 四种选中外观与确认的 mock 一致:单元格圆角蓝框;整行(行号实心蓝+行身淡蓝);整列(表头实心蓝白字+列身淡蓝);整表(点左上角,全表头/行号实心蓝+表身淡蓝)。
3. 选中单元格后拖动其所在列的列宽 → 蓝框实时跟随。
4. 编辑模式下拖动列头可调换顺序、保存后写回文件;只读模式拖不动。点表头仍能选列/排序。
5. 整表选中后 ⌘C → 粘贴得到完整表格。
6. 回归:编辑、方向键移动、复制行/列、删除行、切换编辑↔只读、工具栏不闪、无 `Column selection` 警告。
