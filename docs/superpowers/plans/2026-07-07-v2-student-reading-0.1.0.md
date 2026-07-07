# PDFlab v0.1.0 实现计划:学生查阅体验(即时翻译 + 阅读舒适度)

> 来源:Notion Requirement Pool 中 9 条 Status=To Do、Version=0.1.0 的需求;架构定稿见 [docs/superpowers/specs/2026-07-06-v2-student-reading-design.md](../specs/2026-07-06-v2-student-reading-design.md)。
> **For agentic workers:** REQUIRED SUB-SKILL: superpowers:subagent-driven-development,逐任务派发 + 双重审查。
> 注意:「双击词典」需求仍是 Planning,**本计划不含词典功能**,气泡/点选实现不得顺手实现双击取词。

**Goal:** 查看模块升级为学生查阅工具:即时翻译(划选气泡 / 点选段译侧栏 / 整页翻译 / 扫描页 OCR 点选)+ 阅读舒适度(布局切换 / 阅读位置恢复 / 专注模式 / 护眼渲染)。翻译模块不动。

**Architecture:** Core 新增 `ViewerTranslationService`(含 LRU `TranslationCache`)、`ParagraphHitTester`、`PageOCRStore`、`ReadingStateStore`,全部纯逻辑可 `make test`(TDD)。App 层新增气泡、侧栏、覆盖层高亮、工具栏控件,挂在现有 `ViewerView` / `DualPaneController` 上。

## Global Constraints(每个任务都必须遵守)

- 仓库根 `/Users/zzz/Documents/Claude/PDFlab`。**构建/测试一律 `make build` / `make test`,绝不直接调 `swift`**(DEVELOPER_DIR 与 Swift Testing 框架路径已由 Makefile 封装;直接 `swift test` 会报 `no such module 'Testing'`)。
- **测试文件禁止直接 `import Foundation`**(CLT 缺 `_Testing_Foundation` overlay 编译必败)。Foundation 经 `Models.swift` 顶部 `@_exported import Foundation` 传递,测试只需 `@testable import PDFLabCore`;要用 PDFKit/Vision/CoreImage 时直接 import 那个框架。
- 最低部署 macOS 15;macOS 26 专属 API 必须 `if #available(macOS 26.0, *)` 且保留 15 回退。开发机 15.7。
- **用户可见文案一律经 `L10n.t(_:)`**(`Sources/PDFLabApp/L10n.swift` zh/en 字典),新 key 中英都要给,禁止硬编码。
- 错误一律复用既有 `PDFLabError` case → 既有 `error.*` L10n 映射,**不新增 error case**。
- 零第三方依赖;Swift Testing(`import Testing`);TDD:先写失败测试再实现。
- conventional commits(feat:/fix:/test:/chore:);每任务至少一个 commit。
- 数值常量:翻译缓存 LRU 上限 500;ReadingStateStore 上限 50 条、90 天过期;OCR 渲染 350 DPI。
- 现有测试 141 个必须保持全绿;任务完成时报告 `make test` 总数与结果。
- 查看模块保持只读,不修改用户文件。UI 的 GUI 验收(make run 人工)不在实现任务内,由用户复核;实现任务负责编译通过 + Core 逻辑测试全绿 + 代码自审。

## 现有代码地标(实现前先读相关文件)

- `Sources/PDFLabApp/ViewerView.swift`(~530 行):单文档/标签条/布局模式 `ViewerLayout`;`DualPaneController.swift`(~583 行):并排 NSSplitView + 同步滚动。
- `Sources/PDFLabApp/AppState.swift`:`makeEngine() -> TranslationEngine` 工厂(engineID 跟随设置)。
- Core:`TranslationEngine` 协议(`translate(_:direction:) async throws`,有 `id`)、`LanguageDetector.detectDirection(sample:)`、`PDFTextExtractor.extractPage`(输出带归一化 bbox 的 `TextLine`,原点左下)、`ParagraphBuilder.buildParagraphs(from:)`、`PageRasterizer.rasterize(page:targetDPI:)`、`OCRService(primaryChinese:)`、`HistoryStore`(UserDefaults JSON 风格样板)。

---

### Task 1: ViewerTranslationService + TranslationCache(Core 基建)

**Notion**: 「当我在查看器里反复触发翻译时,我想要命中缓存直接出结果」 https://app.notion.com/p/3960b9fdde91815582e9ea3ea48d0a4d

**Files:**
- Create: `Sources/PDFLabCore/ViewerTranslationService.swift`
- Test: `Tests/PDFLabCoreTests/ViewerTranslationServiceTests.swift`

**Interfaces(后续任务依赖,签名保持稳定):**

```swift
/// 查看器即时翻译共用服务:引擎跟随全局设置 + LRU 缓存 + 方向检测。actor 保证线程安全。
public actor ViewerTranslationService {
    /// engineProvider 每次调用取当前引擎(跟随设置切换);cacheLimit 默认 500。
    public init(engineProvider: @escaping @Sendable () -> TranslationEngine, cacheLimit: Int = 500)
    /// 翻译一段文本:LanguageDetector 定方向(zh→en / en→zh);非中英抛 PDFLabError.unsupportedLanguage。
    /// 缓存 key = (文本, 方向, 引擎 id);命中不调引擎。相同 key 的并发/连续请求合并为一次引擎调用。
    public func translate(_ text: String) async throws -> (text: String, direction: TranslationDirection)
    /// 批量翻译(整页翻译用):逐段走同一缓存;顺序与输入一致。
    public func translateBatch(_ texts: [String], direction: TranslationDirection) async throws -> [String]
    /// 显式指定方向的单段翻译(扫描页等已知方向场景)。
    public func translate(_ text: String, direction: TranslationDirection) async throws -> String
}
```

**要求:**
- LRU 语义:上限 500,超限淘汰最久未用;命中刷新新鲜度。缓存进程内存级,不持久化。
- key 必须含引擎 id:切换引擎后同文本不误命中旧引擎结果。
- in-flight 合并:同一 key 的请求在前一次未返回时不重复调引擎(用 Task/continuation 挂起等待同一结果)。验收「连续触发 10 次只 1 次引擎调用」。
- 错误透传:引擎抛什么就抛什么(PDFLabError),不吞不换。
- 方向检测:`LanguageDetector.detectDirection(sample:)`;返回 nil 时抛 `.unsupportedLanguage(detected: LanguageDetector.detectedLanguageName(sample:))`。
- TDD 用可注入的计数 mock 引擎(参考 `Tests/PDFLabCoreTests/MockHTTPClient.swift` 的注入风格,但直接 mock `TranslationEngine` 协议更简单)。
- 测试覆盖:命中不调引擎 / LRU 淘汰 / key 含方向与引擎 id / 并发合并只调一次 / 方向检测 en与zh / 非中英抛错 / 错误透传 / 批量顺序一致。

**Commit:** `feat: viewer translation service with LRU cache and in-flight dedupe`

---

### Task 2: 划选气泡翻译(App)

**Notion**: 「当我读外文 PDF 遇到看不懂的句子时,我想要划选后立即看到译文」 https://app.notion.com/p/3960b9fdde91815f9c53f6d3a6d28672

**Files:**
- Create: `Sources/PDFLabApp/SelectionTranslationPopover.swift`(气泡控制器 + SwiftUI 内容视图)
- Modify: `Sources/PDFLabApp/ViewerView.swift` / `DualPaneController.swift`(挂接选区监听)、`L10n.swift`(新 key)、`AppState.swift`(如需持有共享 `ViewerTranslationService` 实例)

**要求:**
- 监听 `PDFView` 选区(`.PDFViewSelectionChanged` 通知),鼠标松开且选区非空、非纯空白时,在选区 bounds 旁弹 `NSPopover`:上原文(次要色)、下译文;加载中显示 ProgressView;失败显示 L10n 错误文案 + 「建议切换翻译引擎」提示(复用/新增 L10n key,如 `viewer.bubble.suggestSwitch`)。
- 鼠标未松开不弹(拖选过程中不闪气泡);可用 NSEvent 监听或选区稳定去抖(~0.3s)实现,实现者选一种并在报告里说明。
- 点击其他位置、滚动、翻页时气泡关闭;连续快速划选不叠加多个气泡(旧的先关)。
- md/txt 查看侧(NSTextView)同样支持:监听 `NSTextView` 选区变化,同样弹气泡。
- 单文档与对照模式两侧 PDFView 都生效。
- 翻译经 Task 1 的 `ViewerTranslationService`(AppState 持有单例,engineProvider = `{ appState.makeEngine() }`);非中英选区按 `error.unsupportedLanguage` 文案内联显示。
- **不做双击取词/词典**(那条需求还在 Planning)。
- 选区为扫描页(无文字层选不出文本)时自然无选区,不需特殊处理(扫描页支持在 Task 5)。
- App 层无法单测 UI;把可测的纯逻辑(如选区文本清洗、去抖判定)提成小函数放 App target 内并在 `Tests/PDFLabAppTests` 加测试(该 target 已存在,参考 `ViewerInteractionTests.swift`)。

**Commit:** `feat: selection translation bubble in viewer`

---

### Task 3: ParagraphHitTester + 点选段译侧栏(Core + App)

**Notion**: 「当我逐段精读外文文献时,我想要点击段落就在侧栏看到译文」 https://app.notion.com/p/3960b9fdde9181eda1ebd1161f13892e

**Files:**
- Create: `Sources/PDFLabCore/ParagraphHitTester.swift`
- Test: `Tests/PDFLabCoreTests/ParagraphHitTesterTests.swift`
- Create: `Sources/PDFLabApp/TranslationSidebar.swift`(侧栏视图)+ 高亮覆盖层(可并入 ViewerView 相关文件)
- Modify: `ViewerView.swift`、`L10n.swift`

**Interfaces:**

```swift
/// 页内段落(带聚合 bbox,归一化坐标,原点左下)。
public struct PageParagraph: Equatable, Sendable {
    public var text: String
    public var bbox: CGRect
    public var ocrConfidence: Double?
    public init(text: String, bbox: CGRect, ocrConfidence: Double? = nil)
}
public enum ParagraphHitTester {
    /// 由 TextLine 列表聚段并生成段落级 union bbox(聚段规则复用 ParagraphBuilder 的行距/连接语义)。
    public static func paragraphs(from lines: [TextLine]) -> [PageParagraph]
    /// 命中:点击点(归一化,原点左下)落入某段 bbox(可加少量外扩容差,如 0.005)则命中;多段重叠取 bbox 面积最小者;无命中返回 nil。
    public static func hitTest(point: CGPoint, in paragraphs: [PageParagraph]) -> Int?
}
```

**要求:**
- Core TDD:命中 / 边界(容差内外)/ 重叠取小 / 空列表 / bbox 聚合正确(多行 union)。
- App:单文档模式点击 PDF 页 → `PDFView.page(for:nearest:)` + 页 bounds 换算归一化点 → 文字层页经 `PDFTextExtractor.extractPage` 行 → `ParagraphHitTester.paragraphs` → 命中段整段高亮(覆盖层画圆角半透明高亮框,accent 色 15% 不透明度左右,与段落 bbox 吻合)→ 译文经 `ViewerTranslationService` 追加进右侧侧栏。
- 侧栏:右侧面板(可用 HSplitView 或 overlay 面板,与现有布局兼容),条目=原文摘要+译文,可累积,顶部「清空」按钮;条目加载中/失败态内联展示。
- 点击空白处(无命中):不高亮、不新增条目。
- **仅单文档模式可用**:打开第二个文档(对照模式)时侧栏与点选功能隐藏/停用。
- 每页段落解析结果做简单内存缓存(同页重复点击不重复提行聚段)。
- 扫描页(`isScanned == true`)本任务不处理:点击不响应即可(Task 5 接管)。
- 新 L10n key:侧栏标题、清空、点选开关(若做成开关)等。

**Commit:** `feat: paragraph hit-testing and click-to-translate sidebar`

---

### Task 4: 整页即时翻译(App,基于侧栏批量档)

**Notion**: 「当我通读整页外文时,我想要当前页自动整页翻译并随翻页跟进」 https://app.notion.com/p/3960b9fdde9181768e03ec73c50f752d

**Files:**
- Modify: `Sources/PDFLabApp/TranslationSidebar.swift`、`ViewerView.swift`、`L10n.swift`

**要求:**
- 工具栏开关(SF Symbol 如 `text.page.badge.magnifyingglass` 或类似,带 `.help` tooltip);仅单文档 PDF 模式显示。
- 开启:当前页全部段落(Task 3 的 `ParagraphHitTester.paragraphs`)按原文顺序批量进 `ViewerTranslationService.translateBatch`,译文按顺序填满侧栏(替换点选累积内容,或侧栏分「整页」模式——实现者选更简单方案并说明)。
- 翻页(`.PDFViewPageChanged`)自动刷新为新页译文;已译页(缓存命中)立即显示。
- **快速连续翻页**:上一页未完成的批量任务取消(Task cancellation),不产生乱序/重复条目;以当前页为准。
- 段落方向:整页样本一次 `LanguageDetector` 检测,整页统一方向;非中英按现有语义提示(侧栏顶部提示条)。
- OCR 低置信度条目提示挂钩:`PageParagraph.ocrConfidence` 低于阈值(0.5)时条目带「识别质量低」标签(文字层页恒无;真正触发在 Task 5)。
- 开关关闭:停止跟进并清空侧栏整页内容。

**Commit:** `feat: full-page live translation following page turns`

---

### Task 5: 扫描页按页 OCR 点选(Core + App)

**Notion**: 「当我阅读扫描版 PDF 时,我想要照常点选翻译」 https://app.notion.com/p/3960b9fdde9181ba9b6bcf9210003678

**Files:**
- Create: `Sources/PDFLabCore/PageOCRStore.swift`
- Test: `Tests/PDFLabCoreTests/PageOCRStoreTests.swift`
- Modify: `ViewerView.swift`(扫描页点选/整页翻译接入)、`L10n.swift`

**Interfaces:**

```swift
/// 按页缓存查看器 OCR 结果。actor;OCR 本体可注入以便测试。
public actor PageOCRStore {
    public enum PageState: Sendable { case notStarted, running, done([PageParagraph]), failed }
    /// recognizer 注入:输入 CGImage 与页号,输出 TextLine(生产实现包 OCRService;测试注入 stub)。
    public init(recognizer: @escaping @Sendable (CGImage, Int) async throws -> [TextLine])
    /// 取某页段落;notStarted 时启动识别(rasterize 由调用方完成传入闭包/或 store 内完成——实现者定,需可测),
    /// running 时挂起等待同一次识别结果(不重复识别),done 直接返回。
    public func paragraphs(forPage pageIndex: Int, image: @Sendable @escaping () throws -> CGImage) async throws -> [PageParagraph]
    public func state(forPage pageIndex: Int) -> PageState
}
```

**要求:**
- Core TDD(注入 stub recognizer):首次触发识别 / 并发请求同页只识别一次 / 已识别页直接命中 / 识别失败标 failed 且可重试 / 空结果(无文字)返回空数组。
- App:扫描页(`PDFTextExtractor.extractPage(...).isScanned`)点击或开整页翻译时:`PageRasterizer.rasterize(page:targetDPI: 350)` → OCR(`OCRService`,沿用语言预嗅探:对页面样本或文档已有文本判断 primaryChinese)→ `ParagraphBuilder`/`ParagraphHitTester.paragraphs` 聚段入 store → 后续点选/整页翻译与文字层页共用同一条路径。
- 识别期间页面给轻量「识别中」指示(如侧栏/角标 ProgressView + L10n `viewer.ocr.running`);OCR 全程后台线程,不卡滚动。
- 整页无结果:提示既有 L10n「未识别到文字」(`error.noTextRecognized` 既有 key,确认后复用)。
- 低置信度段落(confidence < 0.5)条目挂「识别质量低」提示(与 Task 4 的挂钩联动;新 L10n key 或复用翻译模块既有 key,先查 L10n.swift)。
- OCR 结果不持久化,重开文档重新识别。文档切换/关闭时 store 释放。
- 不做字符级划选、不做扫描页双击。

**Commit:** `feat: per-page viewer OCR enabling tap-translate on scanned PDFs`

---

### Task 6: 页面布局模式切换(App)

**Notion**: 「当我阅读书籍型 PDF 时,我想要切换单页/双页/连续布局」 https://app.notion.com/p/3960b9fdde9181bf9c8dffb0f5dd9036

**Files:**
- Modify: `Sources/PDFLabApp/ViewerView.swift`、`DualPaneController.swift`、`L10n.swift`

**要求:**
- 工具栏分段控件三档:单页(`PDFDisplayMode.singlePage`)/ 双页(`.twoUp`)/ 连续(`.singlePageContinuous`),SF Symbols + `.help` tooltip,仅 PDF 文档时显示。
- 切换后阅读位置不丢:切换前记录当前页,切换后 `go(to:)` 回该页。
- 对照模式:两栏 PDF 同时生效(md/txt 栏忽略)。注意与同步滚动共存:切换布局后同步滚动仍工作(绝对屏数映射不依赖 displayMode,应天然兼容,验证不回归即可)。
- 布局状态存于查看会话(每文档标签各自记住本次会话的选择);跨启动持久化由 Task 7 接管——本任务把当前布局档暴露成可读写属性,供 Task 7 存取。
- 新 L10n key:`viewer.layout.*`。

**Commit:** `feat: single/two-up/continuous page layout switching`

---

### Task 7: 阅读位置与缩放恢复(Core + App)

**Notion**: 「当我重新打开读过的文档时,我想要回到上次的位置和缩放」 https://app.notion.com/p/3960b9fdde918155a2e3c52abef9cdc8

**Files:**
- Create: `Sources/PDFLabCore/ReadingStateStore.swift`
- Test: `Tests/PDFLabCoreTests/ReadingStateStoreTests.swift`
- Modify: `ViewerView.swift` / `DualPaneController.swift`(记录与恢复挂接)

**Interfaces:**

```swift
public struct ReadingState: Codable, Equatable, Sendable {
    public var path: String
    public var pageIndex: Int
    public var zoomScale: Double
    public var layoutMode: String   // Task 6 布局档的 rawValue;非 PDF 可空串
    public var updatedAt: Date
}
public final class ReadingStateStore: @unchecked Sendable {
    /// 风格照抄 HistoryStore:UserDefaults JSON,key "pdflab.readingStates";maxEntries 50;maxAge 90 天;clock 可注入。
    public init(defaults: UserDefaults = .standard, maxEntries: Int = 50, maxAge: TimeInterval = 90*24*3600, now: @escaping () -> Date = Date.init)
    public func record(_ state: ReadingState)          // 同 path 覆盖并刷新时间;超限裁最旧;读写时剔除过期
    public func state(forPath path: String) -> ReadingState?
    public func clear()
}
```

**要求:**
- Core TDD:存取 round-trip / 同 path 覆盖 / 超 50 裁最旧 / 90 天过期剔除(注入时钟)/ clear。先读 `HistoryStore.swift` 与其测试,保持同风格。
- App:PDF 文档关闭标签、切换文档、App 退出(`willTerminateNotification` 或 scene 生命周期)时记录当前页码 + `PDFView.scaleFactor` + 布局档;打开时若有记录则恢复(go to page + scaleFactor + displayMode)。恢复在文档加载完成后执行一次,不与「首次自动缩放」打架(先恢复布局再恢复缩放/页码)。
- 对照模式主副文档各记各的(按各自 path)。
- md/txt 本期不记(超范围)。
- 恢复不可感知延迟:同步读 UserDefaults 即可。

**Commit:** `feat: per-file reading position, zoom, and layout restore`

---

### Task 8: 专注模式(App)

**Notion**: 「当我需要沉浸阅读时,我想要隐藏所有界面元素」 https://app.notion.com/p/3960b9fdde918144ad87ed5aed219d2c

**Files:**
- Modify: `Sources/PDFLabApp/ViewerView.swift`、`L10n.swift`

**要求:**
- 工具栏按钮(SF Symbol `arrow.up.left.and.arrow.down.right` 或 `rectangle.expand.vertical` 类,带 tooltip)+ 键盘快捷键(选不与系统/现有冲突的,如 ⇧⌘F 若空闲;在 tooltip 里标注)进入专注模式:隐藏查看器工具栏与标签条,只剩正文。
- Esc 退出(SwiftUI `.onExitCommand` 或 NSEvent 监听;确保气泡打开时 Esc 先关气泡再退模式,或分开处理——实现者定,报告说明)。
- 专注模式中滚动/翻页/划选气泡/点选侧栏照常可用(侧栏算界面元素吗?——按「只剩正文」处理:侧栏也隐藏,但点选/划选翻译产生的气泡照常)。
- 进入/退出不闪烁、阅读位置不跳:隐藏用条件布局(如 `if !isFocusMode { toolbar/tab }`)并保持 PDFView 实例不重建(注意 ViewerView 现有结构,不要触发 DualPaneController 重建;单看模式同理)。
- 与系统全屏兼容(不强制绑定,全屏是系统行为)。
- 新 L10n key:`viewer.focus.enter` / `viewer.focus.exit`。

**Commit:** `feat: focus mode hiding chrome for immersive reading`

---

### Task 9: 护眼渲染三档(App,先 spike)

**Notion**: 「当我夜间或长时间阅读时,我想要护眼的页面色调」 https://app.notion.com/p/3960b9fdde918160a886cef81552cf4c

**Files:**
- Modify: `Sources/PDFLabApp/ViewerView.swift`、`DualPaneController.swift`、`L10n.swift`(如逻辑可抽,滤镜构造可提成独立文件 `Sources/PDFLabApp/ComfortFilter.swift`)

**要求:**
- **先做 spike**:验证在 `PDFView`(NSView)图层挂 CIFilter 的可行路径——候选:`pdfView.layer?.filters = [...]`(需 `wantsLayer`)、或包一层容器 layer 加 `backgroundFilters`/`filters`。写一个最小可运行验证(可以是临时的 make run 手动路径 + 代码注释记录结论);若 layer.filters 在滚动时性能/渲染有问题,备选方案:夜间档改用 `pdfView.appearance` 反色不可行时,用 CALayer compositingFilter 或接受仅界面级滤镜。**spike 结论写进报告与代码注释**;若两条路径都明确不可行,报 BLOCKED 而不是硬做。
- 三档:正常(移除滤镜)/ 羊皮纸(暖色:如 CIColorControls 降饱和 + CIColorMonochrome/CIColorMatrix 暖色叠加,呈米黄)/ 夜间(CIColorInvert + CIHueAdjust 角度 π,「智能反色」图片观感基本正常)。
- 工具栏或菜单三档选择(分段控件或 Menu,带 tooltip);对照模式两栏同时生效;md/txt 侧:夜间/羊皮纸可用背景+文字色近似(NSTextView 配色),不强求滤镜一致。
- 切回正常必须与原始渲染一致(滤镜彻底移除)。
- 档位选择存 `@AppStorage`(全局偏好,非按文档)。
- 新 L10n key:`viewer.comfort.normal/sepia/night` 等。
- 滚动帧率无明显下降属 GUI 验收(用户侧);实现侧确保滤镜只挂一次、不逐帧重建。

**Commit:** `feat: three-mode eye-comfort rendering (normal/sepia/night)`
