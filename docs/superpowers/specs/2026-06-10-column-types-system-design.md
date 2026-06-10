# 列类型系统重构设计（Column Types System）

日期：2026-06-10
状态：已批准，待实现

## 背景与问题

LightData 的"类型"(types)功能把 Notion 式的列类型(text/number/date/checkbox/url/select/multiSelect/status)叠加到**已存在的、无类型的字符串数据**上(CSV/TSV/JSON/XLSX),类型只存在于视图元数据(`SchemaMetadataStore`),不写入数据文件。

**根本矛盾**:Notion 是"先定类型、再录数据"——类型是**输入约束**(authoring);我们是"先有数据、后贴类型"——类型是对既有数据的**解释**(interpreting)。

由此产生的现状问题:
1. **零校验**:`setColumnTypeFromMenu` 允许给任意列贴任意类型,数据不匹配也照渲染(文本列设 checkbox 全变勾、设 number 全右对齐、设 url 全变蓝),观感崩坏。
2. **推断弱**:`TableSchema.inferred` 只能推断 url/number/text 三种,checkbox/date/select/status 永远推不出 → 多数列落到 text。
3. **单选/多选 UI 丑**:用 `NSPopUpButton`,只读模式变灰变暗;颜色只染文字、不是 Notion 式色块标签。

## 设计原则

类型是"**对整列数据的一个承诺**":整列(非空值)都能兑现某类型,才允许贴上;兑现不了就不贴(这是与 Notion 的本质差异——我们不约束输入,而是约束"能不能声明这个类型")。

## A. 类型门禁(Gate)

把类型分成两类:

- **格式型(有客观 pass/fail 判定,参与门禁)**:`number` / `url` / `date` / `checkbox`
- **意图型(无客观判定,排除在门禁外,永远由用户手动选)**:`select` / `multiSelect` / `status`
  - 理由:任何文本都"算"select(就是从出现过的值里挑),机器测不出"这列算不算分类",是语义判断。

**门禁规则**:
1. 某格式型类型可贴到某列 ⟺ 该列**所有非空值**都符合该类型判定。
2. **空值/NULL 对任何类型都兼容**,只校验非空值(否则现实中几乎没列能过门禁)。
3. 菜单里:`text` 永远可选(= 不贴类型的兜底);符合的格式型**亮**,不符合的**置灰**;意图型永远可选。
4. **自动推断**只在"恰好唯一一个非 text 格式型匹配"时自动贴;**匹配多个**(如全 0/1 既是 number 又是 checkbox)→ 不自动贴,留 text,由用户在亮着的选项里挑。

**各格式型的判定**:
- `number`:每个非空值 `Double($0) != nil`。
- `url`:每个非空值是 http(s) URL(`URL(string:)?.scheme?.hasPrefix("http")`)。
- `date`:每个非空值符合 **ISO 8601 一族**(`YYYY-MM-DD`、`YYYY-MM-DDTHH:MM:SS`)。窄但无歧义,以后再扩。
- `checkbox`:每个非空值 ∈ `trueValues ∪ falseValues`(`true/false/yes/no/1/0/y/n`)。

## B. 类型生命周期

类型是"承诺",所以要在编辑过程中维持承诺:

1. **贴类型那一刻**:走 A 的门禁,整列(非空)全符合才让贴。
2. **types ON 且列有格式型时的后续输入**:
   - `number` / `date`:用**原生 `NSFormatter`**(`NSNumberFormatter` / `NSDateFormatter`)挂到内联编辑器,非法输入当场拒绝提交。
   - `url`:不做逐键拦截;**贴后某格若不是合法 URL,则那一格退回纯文本渲染**(优雅降级,只当安全网,不整列降级)。
   - `checkbox`:经勾选控件编辑,不存在打字,不需要拦截。
   - 空值在所有情况下放行。
3. **types OFF**:自由输入任何内容,不校验。
4. **从 OFF 重新切回 ON**:重新扫每个有保存类型的列,**若已不再匹配 → 该列退化成 text**(丢弃保存的类型)。"自愈"。

## C. 单选/多选/状态的原生 UI + 系统色

**显示层 = 自绘彩色 pill**:在单元格绘制里用 `NSBezierPath` 画圆角胶囊(淡色底 + 同色文字)。
- 选它而非 `NSTokenField`/`NSPopUpButton` 的理由:原生件只读模式变灰变暗、且无法干净上色;自绘是唯一能同时做到"彩色 + 只读不变暗"的方式。
- 自绘范围仅限"显示那颗胶囊";交互全用原生件。

**编辑交互(全原生)**:
- **单选 / 状态**:点单元格 → 原生 `NSMenu`,每项前缀色块(`NSMenuItem.image` 色卡),选一个即合上。
- **多选**:点单元格 → 原生 `NSPopover`,内含一列原生复选框(`NSButton` checkbox),可勾多个、保持打开,关闭时写回。
  - 不用 `NSMenu` 做多选:它每次点击自动合上,做"连续勾多个"很别扭。

**颜色 = 系统色(零设计)**:
- 存储用**语义名**("blue"/"green"/…),渲染时解析为 **Apple 系统色** `NSColor.systemBlue` 等。已是现状(`colorForTag`),保留并对齐扩展。
- 好处:苹果维护配色、**自动适配深色/浅色**、我们零设计。
- 调色板对齐到 `NSColor.system*` 全集:现有 8 个 + `systemTeal/systemIndigo/systemMint/systemCyan/systemBrown/systemGray`;`"gray"` 显式映射到 `.systemGray`。
- pill 背景从同一系统色派生淡色(`color.withAlphaComponent(~0.15)` 当底、原色当字),底与字都从系统色推导,无手挑色号。
- **变成单选/多选时按色板自动轮配颜色**(现有 `inferOptions` 已如此);**用户改色 = 从这组系统色里挑**(固定的系统色清单)。**不做自定义取色器(NSColorWell)**——零设计零维护;以后若要任意色再加。

## 适用范围与性能

- 类型功能本就**只作用于完整载入的文件**,对懒加载 Parquet 关闭(`MainWindowController.swift` 渲染处 `!isLazy && metadata.schemaEnabled`)。所以"扫全列做门禁/再校验"的开销被文件大小天然兜住,不碰大文件性能红线。

## 不在本次范围(YAGNI)

- 自定义任意色取色器(NSColorWell)。
- date 接受格式扩展(本次只 ISO 8601 一族)。
- 把类型写入数据文件(类型始终只在视图层)。
- filter / 行序进入视图记忆(与本特性无关)。

## 实现切分(阶段)

1. **核心模型/判定**(LightDataCore):格式型 pass/fail 判定函数、`inferType` 增强(覆盖 date/checkbox、"唯一匹配才推断")、调色板对齐系统色。
2. **门禁接线**(MainWindowController):列头类型菜单按列数据 enable/disable;`setColumnTypeFromMenu` 拒绝不符合;types 切回 ON 时整体重校验 + 不匹配列降级 text。
3. **生命周期**:内联编辑器对 number/date 挂 `NSFormatter`;url 坏格降级渲染。
4. **显示层**:自绘彩色 pill 渲染 select/multiSelect/status(替换文字染色 / NSPopUpButton 显示)。
5. **编辑交互**:单选原生 `NSMenu`(带色块) / 多选原生 `NSPopover`+复选框 / 改色从系统色板挑。
6. 编译 + 测试 + 安装验证。
