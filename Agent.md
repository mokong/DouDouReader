# 豆豆阅读 (DouDouReader) — Agent 执行说明与待办清单

给后续 Agent 执行实现用的工程规范与待执行任务清单。已实现能力见 [README.md](file:///Users/drama/Desktop/WorkSpace/trae_projects/DouDouReader/README.md)，本文档维护工程约束、目录职责与待执行任务。

功能落地后，请勾选下方「待执行清单」中的对应条目，确保 `-selfTest` 输出 `LOGIC_OK`，并将用户可见行为同步至 `README.md`。

---

## 一、工程约束（必读）

1. **目录同步机制**：
   - `DouDouReader.xcodeproj` 使用 `PBXFileSystemSynchronizedRootGroup`。在 `DouDouReader/` 下新增或修改 `.swift` 文件会自动加入编译目标，**切勿手改 `project.pbxproj` 登记源文件**。
2. **并发与 Actor 隔离**：
   - 工程开启了 `SWIFT_DEFAULT_ACTOR_ISOLATION = MainActor` 与 `SWIFT_APPROACHABLE_CONCURRENCY = YES`。
   - 所有非 UI 的纯数据模型、解析器、网络执行器（如 `UniversalBookSource`、`RuleBasedBookCatalog`、`HTMLMiniParser`）必须显式标注 `nonisolated` 并遵循 `Sendable`，避免后台线程调用时触发 MainActor 隔离编译错误。
3. **跨平台兼容**：
   - 同时支持 iOS / iPadOS / visionOS (`UIKit`) 与 macOS (`AppKit`)。涉及平台特定 API 时必须使用 `#if os(iOS) || os(visionOS)` 与 `#elseif os(macOS)` 条件编译。
4. **向后兼容**：
   - `UniversalBookSource` 及其子规则结构体（`SourceSearchRule`、`SourceTocRule`、`SourceContentRule`、`SourceExploreRule`）的新增字段必须在 `init` 中提供默认值，并在 `init(from decoder: Decoder)` 中使用 `decodeIfPresent(...) ?? 默认值`，保证旧存档 JSON 解码不失败（`LogicChecks` 中有专门的旧版 JSON 回归测试）。
5. **零第三方依赖**：
   - 仅使用系统原生框架（`Foundation`、`SwiftUI`、`SwiftData`、`Compression`、`AVFAudio`），不引入外部 SPM 包。

---

## 二、核心目录职责

| 路径 | 职责 |
| :--- | :--- |
| [`DouDouReader/BookSource/UniversalBookSource.swift`](file:///Users/drama/Desktop/WorkSpace/trae_projects/DouDouReader/DouDouReader/BookSource/UniversalBookSource.swift) | 统一书源模型（抽象阅读 3.0、香色闺阁 `.xbs`、豆豆标准源）及搜索/发现/目录/正文规则结构体。 |
| [`DouDouReader/BookSource/BookSourceParser.swift`](file:///Users/drama/Desktop/WorkSpace/trae_projects/DouDouReader/DouDouReader/BookSource/BookSourceParser.swift) | 书源解析器：将阅读 3.0 (`ruleSearch`/`ruleBookInfo`/`ruleToc`/`ruleContent`/`ruleExplore`) 与香色闺阁 (`searchBook`/`findBook`/`bookDetail`/`chapterList`/`chapterContent`) 映射为 `UniversalBookSource`。 |
| [`DouDouReader/BookSource/RuleBasedBookCatalog.swift`](file:///Users/drama/Desktop/WorkSpace/trae_projects/DouDouReader/DouDouReader/BookSource/RuleBasedBookCatalog.swift) | 规则书源执行器：负责构建请求、GBK/UTF-8 解码、HTML/JSON 提取、详情与目录解析、分页章节下载与正文清洗。 |
| [`DouDouReader/BookSource/HTMLMiniParser.swift`](file:///Users/drama/Desktop/WorkSpace/trae_projects/DouDouReader/DouDouReader/BookSource/HTMLMiniParser.swift) | 轻量 HTML DOM 解析与 XPath / CSS / `@css:` / `@js:` / `\|\|` / `&&` / `##regex##replacement` 规则求值引擎。 |
| [`DouDouReader/BookSource/SourceBrowser.swift`](file:///Users/drama/Desktop/WorkSpace/trae_projects/DouDouReader/DouDouReader/BookSource/SourceBrowser.swift) | 发现页、站点切换弹窗、书源管理中心。 |
| [`DouDouReader/BookSource/BookSearchView.swift`](file:///Users/drama/Desktop/WorkSpace/trae_projects/DouDouReader/DouDouReader/BookSource/BookSearchView.swift) | 多书源并发聚合搜索视图。 |
| [`DouDouReader/Diagnostics/LogicChecks.swift`](file:///Users/drama/Desktop/WorkSpace/trae_projects/DouDouReader/DouDouReader/Diagnostics/LogicChecks.swift) | 离线自动化自检与回归测试套件（通过 `-selfTest` 触发）。 |

---

## 三、待执行清单：增强香色书源规则兼容

> **目标**：全面对齐香色闺阁（`.xbs`）与阅读 3.0 书源的高级规则语义，重点解决 **详情页独立规则 (`bookDetail`)**、**分页章节正文自动拼接 (`1/2页`、`1/3页` 截断问题)** 以及 **分类/状态/字数元数据提取与清洗**。

### 任务 1：完善 `bookDetail` 详情页请求模板与 JSON 详情执行链路

**现状说明**：
目前 [`SourceTocRule`](file:///Users/drama/Desktop/WorkSpace/trae_projects/DouDouReader/DouDouReader/BookSource/UniversalBookSource.swift#L284) 已包含 `infoNameSelector`、`infoAuthorSelector`、`infoCoverSelector`、`tocURLSelector` 基础字段，但香色闺阁的 `bookDetail` 可能携带独立请求配置（`requestInfo`，如 `/book/%@.html`）：当搜索结果只给出纯书号 `bookID` 时，[`prepare(bookID:)`](file:///Users/drama/Desktop/WorkSpace/trae_projects/DouDouReader/DouDouReader/BookSource/RuleBasedBookCatalog.swift#L159) 无法拼装详情页 URL。另外部分源详情页直接返回 JSON，现有逻辑只按 HTML 解析，目录会抓空。

**范围说明（重要）**：本任务**不新增**详情页简介/分类/状态/最新章选择器。原因：搜索/发现侧返回的 `CatalogBook` 已带 `summary`/`category`/`status`/`latestChapter`，而 `PreparedBook`、`OnlineOpening`、`OnlineTOC` 均不承载这些字段，详情页提取出来没有落点。详情页元数据的清洗在任务 3 基于搜索/发现结果完成。

**执行步骤**：
1. **扩展模型 [`SourceTocRule`](file:///Users/drama/Desktop/WorkSpace/trae_projects/DouDouReader/DouDouReader/BookSource/UniversalBookSource.swift)**：
   - 仅新增一个字段 `detailRequestTemplate: String = ""`（香色 `bookDetail.requestInfo` 规范化后的详情页 URL 模板），并在 `CodingKeys`、`init(from:)`（`decodeIfPresent` 兜底空串）、`encode(to:)` 中向后兼容。
2. **扩展解析器 [`BookSourceParser.swift`](file:///Users/drama/Desktop/WorkSpace/trae_projects/DouDouReader/DouDouReader/BookSource/BookSourceParser.swift)**：
   - 在 `parseXiangSe` 的 `dict["bookDetail"]` 解析块中：若 `detailAction["requestInfo"]` 为字符串且非空，经 `normalizeXiangSeURL` 规范化后存入 `tocRule.detailRequestTemplate`。
   - 在 `parseLegado` 中**不映射** URL 模板：阅读 3.0 的详情 URL 直接来自搜索结果（`ruleSearch` 的 bookUrl），`ruleBookInfo` 没有 URL 模板字段，无需处理。
3. **扩展执行器 [`RuleBasedBookCatalog.swift`](file:///Users/drama/Desktop/WorkSpace/trae_projects/DouDouReader/DouDouReader/BookSource/RuleBasedBookCatalog.swift)**：
   - **详情 URL 模板拼装**：在 `prepare(bookID:)` 开头，仅当 `bookID` 不是可独立解析的地址（不含 `://`，且相对 `source.sourceURL` 也解析不出合法详情页）且 `!source.tocRule.detailRequestTemplate.isEmpty` 时，将模板中的 `%@`、`%@result`、`{{key}}` 占位符（`%@` 是香色最常见写法）替换为 `bookID` 后再 `resolveURL` 为 `bookURL`；否则维持现有直接解析逻辑。
   - **JSON 详情响应**：当 `detailHtml` 去空白后以 `{` 或 `[` 开头、能 `JSONSerialization` 解析成功，且 `tocRule.listSelector` 以 `$.` 开头时，不走 `HTMLMiniParser.parse`，而是新增私有方法 `loadChapterList(bookURL:json:)`（复用现有章节 URL 相对/绝对拼装逻辑），用 `navigateJSON` 按 `listSelector`/`nameSelector`/`urlSelector` 提取章节数组。书名/作者/封面维持现有 HTML 提取逻辑不变（JSON 详情页时回退为空值，本任务不扩展 `PreparedBook` 字段）。

---

### 任务 2：实现分页章节正文自动拼接（解决单章被拆为 `1/2页`、`1/3页` 截断问题）

**现状说明**：
国内大量笔趣阁及香色书源站点为赚取翻页 PV，会将单章正文拆成 `12345.html`、`12345_2.html`、`12345_3.html`。目前 [`RuleBasedBookCatalog.downloadChapter(_:)`](file:///Users/drama/Desktop/WorkSpace/trae_projects/DouDouReader/DouDouReader/BookSource/RuleBasedBookCatalog.swift#L184-L200) 只拉取第一页，导致每章后半部分丢失。

**执行步骤**：
1. **扩展模型 [`SourceContentRule`](file:///Users/drama/Desktop/WorkSpace/trae_projects/DouDouReader/DouDouReader/BookSource/UniversalBookSource.swift#L353)**：
   - 新增 `nextContentURLSelector: String = ""`（并在 `CodingKeys`、`init`、`init(from:)`、`encode(to:)` 中做好默认空串兼容）。
2. **扩展解析器 [`BookSourceParser.swift`](file:///Users/drama/Desktop/WorkSpace/trae_projects/DouDouReader/DouDouReader/BookSource/BookSourceParser.swift)**：
   - 在 `parseLegado` 中读取 `(ruleContent["nextContentUrl"] as? String) ?? ""` 赋值给 `contentRule.nextContentURLSelector`。
   - 在 `parseXiangSe` 中读取 `contentAction["nextPageUrl"]` / `contentAction["nextContentUrl"]` / `contentAction["moreKeys"]`（若为字符串）赋值给 `contentRule.nextContentURLSelector`。
   - 注：真实香色/阅读源很少提供显式字段，大多数站点依赖第 3 步的启发式兜底。
3. **在 [`RuleBasedBookCatalog.swift`](file:///Users/drama/Desktop/WorkSpace/trae_projects/DouDouReader/DouDouReader/BookSource/RuleBasedBookCatalog.swift) 实现多页循环抓取与自动拼接**：
   - 新增私有辅助方法 `extractNextContentPageURL(from root: HTMLNode, currentPageURL: URL, firstPageURL: URL) -> URL?`，返回下一页候选 URL（无则返回 `nil`）：
     - **显式规则优先**：若 `!source.contentRule.nextContentURLSelector.isEmpty`，通过 `HTMLMiniParser.queryStrings(root: root, rule: source.contentRule.nextContentURLSelector)` 提取首个候选并 `resolveURL` 为绝对 URL。**显式规则结果不做同章校验**——它是书源作者写死的规则，直接信任，只参与 `visited` 去重与页数上限。
     - **启发式兜底**：仅当显式规则无结果时，扫描页面内 `//a` 节点，若链接文本包含 `"下一页"`、`"下一节"`、`"本章未完"`（且不含 `"下一章"`、`"下一篇"`），取其 `href` 并**必须通过同章分页校验**（关键防越界）：去重后缀（`.html`/`.htm`）后，路径应以首页路径 stem 为前缀并紧跟 `_\d+`、`-d+`、`/d+`（如首页 `/txt/100/500.html`，合法分页 `/txt/100/500_2.html`、`/txt/100/500/2.html`），或 query 参数含 `page=`；指向 `/txt/100/501.html` 等下一章链接一律拒绝。
   - 改造 `downloadChapter(_ url: URL) async throws -> String`：
     - 维护 `visited: Set<String>`（首个元素为首页 URL）与最大分页上限 `maxPages = 10`。循环：拉取当前页 → 提取正文段 → 取合法 `nextURL`（不在 `visited` 中且当前页数 `< maxPages`）→ 继续，直到无 `nextURL` 或触发终止条件。
     - **失败语义（宽容）**：分页循环中某一页下载失败时，保留已抓到的各页正文并终止该章的分页拼接，**不整章抛错**；仅首页失败、或各页拼出的正文经清洗后仍为空时，维持现有 `fetchChapterText` 的 `emptyBook` 语义。
     - **分页噪音清洗**：逐页剥离分页交界重复出现的章节标题（仅当整行与章节标题完全一致时才移除，防止误伤正文）与常见翻页提示语（如 `本章未完，请点击下一页继续阅读`、`正在手打中，请稍等片刻`、`第1章 标题(第2/2页)`、`(1/3)`）；剥离正则必须**锚定行首/行尾**（多行模式 `^...$`），避免误删正文中的分数、日期类文本。最后统一走 `applyReplaceRules` 清洗并以换行拼接返回。
   - 并发说明：`fetchText` 现有 4 路并发整本下载的并发模型不变；多页化后最坏单章 10 请求 × 4 并发，无需额外调整。

---

### 任务 3：分类、连载状态与字数元数据提取清洗与 UI 展示

**现状说明**：
[`SourceSearchRule`](file:///Users/drama/Desktop/WorkSpace/trae_projects/DouDouReader/DouDouReader/BookSource/UniversalBookSource.swift) 与 [`SourceExploreRule`](file:///Users/drama/Desktop/WorkSpace/trae_projects/DouDouReader/DouDouReader/BookSource/UniversalBookSource.swift) 已添加 `categorySelector` 和 `statusSelector`，但许多香色/阅读书源在网页中抓出的分类或状态带有冗余括号、分隔符或复合文本（如 `"[玄幻奇幻]"`、`"分类：都市言情"`、`"玄幻 · 连载中 · 128万字"`）。

**执行步骤**：
1. **新增元数据清洗工具函数（可在 `RuleBasedBookCatalog.swift` 或独立 `nonisolated enum BookMetadataCleaner` 中实现）**：
   - `cleanCategory(_ raw: String) -> String`：去掉 `"分类："`、`"类型："`、`"["`、`"]"`、`"【"`、`"】"` 等外层修饰符；若包含 `"|"` 或 `"·"` 等复合段且未单独拆出状态，优先取首个非空分类词。
   - `cleanStatus(_ raw: String) -> String`：去掉 `"状态："` 等前缀，归一常见状态词（如 `"连载中"` / `"连载"` / `"完本"` / `"完结"`）。
2. **在 [`RuleBasedBookCatalog.parseHTMLBooks`](file:///Users/drama/Desktop/WorkSpace/trae_projects/DouDouReader/DouDouReader/BookSource/RuleBasedBookCatalog.swift#L831-L882) 与 `tryParseJSONSearchResults` 中应用清洗**：
   - 当 `statusSelector` 为空但 `category` 原文包含 `"连载"` 或 `"完结"` / `"完本"` 时，自动从复合文本中分离出 `category` 与 `status`。
3. **检查 UI 卡片展示**：
   - 在 [`SourceBrowserView.bookCard`](file:///Users/drama/Desktop/WorkSpace/trae_projects/DouDouReader/DouDouReader/BookSource/SourceBrowser.swift#L409-L463) 与 [`BookSearchView.meta`](file:///Users/drama/Desktop/WorkSpace/trae_projects/DouDouReader/DouDouReader/BookSource/BookSearchView.swift#L449-L454) 中确保分类、状态、最新章节展示整洁，不出现重复分隔符（如 `作者 ·  · 在线`）。

---

### 任务 4：编写回归测试并验证编译与 `-selfTest`

1. **在 [`DouDouReader/Diagnostics/LogicChecks.swift`](file:///Users/drama/Desktop/WorkSpace/trae_projects/DouDouReader/DouDouReader/Diagnostics/LogicChecks.swift) 的 `checkBookCoverAndXiangSeEnhancements` 中追加断言**：
   - **分页章节自动拼接测试**：使用 `CatalogURLStub` 注册 `/book/99/c1.html`（含 `<a href="/book/99/c1_2.html">下一页</a>`）、`/book/99/c1_2.html`（含 `<a href="/book/99/c1_3.html">下一页</a>`）与 `/book/99/c1_3.html`（含指向下一章 `<a href="/book/99/c2.html">下一章</a>`），验证 `fetchChapterText` 自动拼合三页正文、剥离 `本章未完` 提示，且不会误把 `c2.html` 拼进第一章。
   - **分页死循环防护测试**：当 `c1_2.html` 的下一页指回 `c1.html` 时，验证 `visited` 集合能立即终止循环而不死锁。
   - **分页中间页失败宽容测试**：当 `c1_2.html` 返回 500 时，验证 `fetchChapterText` 仍返回首页正文而不是整章抛错。
   - **分类与状态清洗测试**：验证 `"[玄幻奇幻]"`、`"分类：仙侠 | 连载中"` 能正确清洗并拆出 `category` 与 `status`。
2. **编译与自检命令**：
   ```bash
   xcodebuild -project DouDouReader.xcodeproj -scheme DouDouReader -destination 'platform=macOS' -derivedDataPath /tmp/DouDouReaderBuild build -quiet && /tmp/DouDouReaderBuild/Build/Products/Debug/DouDouReader.app/Contents/MacOS/DouDouReader -selfTest
   ```
   确保控制台输出 `LOGIC_OK` 且退出码为 `0`。

---

## 四、待执行状态追踪

- [x] **基础支持**：`BookRecord.coverURL` 持久化、EPUB 封面提取、防盗链 `BookCoverLoader`、基础 `bookDetail` 封面/目录选择器与 `cat`/`status` 字段定义（已于 `91683f4` 完成）
- [x] **任务 1**：`bookDetail` 详情请求模板（`detailRequestTemplate`，支持 `%@`/`%@result`/`{{key}}` 占位符）+ JSON 详情页目录提取执行链路
- [x] **任务 2**：分页章节正文自动拼接（`nextContentURLSelector` + 启发式同章分页识别 + 防死循环 + 宽容失败语义 + 行首行尾锚定的分页提示词清洗）
- [x] **任务 3**：实现分类/连载状态复合文本清洗与卡片展示优化
- [x] **任务 4**：在 `LogicChecks.swift` 补充多页章节拼接与死循环防护自检，并通过 `-selfTest`
