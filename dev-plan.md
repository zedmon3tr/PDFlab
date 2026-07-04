# PDFlab 开发计划(dev-plan)

> **文档定位**:开发计划与任务编排。读完 [product-spec.md](product-spec.md) 与 [design-brief.md](design-brief.md) 后,先调研技术栈有没有现成组件可复用,再把项目拆成 Phase(每个 Phase 有明确交付物),Phase 内再拆可独立测试的任务。开发细节(构建/约定/架构)见 [dev-build.md](dev-build.md)。
> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

## 前置调研结论(2026-07,决定用什么/不重复造轮子)

- **本地翻译**:Apple Translation 框架(macOS 15+,免费离线)作默认引擎,不接付费云。macOS 26 有直接构造器、15 需 SwiftUI 修饰符。
- **OCR**:Vision 框架(26 `RecognizeDocumentsRequest` 直出结构,15 `RecognizeTextRequest`),不引第三方 OCR。
- **PDF 读写/渲染**:PDFKit,不引第三方 PDF 库。
- **语言检测**:NaturalLanguage(`NLLanguageRecognizer`)。
- **docx 导出**:无合适零依赖 Swift 库 → 自建最小 OOXML(zip + XML),`/usr/bin/zip` 打包。
- **云端翻译**:Google/DeepL 走免 Key 逆向端点(可插拔,随时可能失效);有道走官方智云 API;LLM 走 OpenAI 兼容协议。
- **结论:零第三方依赖**,全部用系统框架 + 自建纯逻辑。

## Phase 划分与交付物

| Phase | 交付物 | 对应任务 |
|---|---|---|
| P0 脚手架 | 可构建可测的 SPM 双 target | T1–T2 |
| P1 解析/OCR 核心 | 文本提取 + 扫描页 OCR + 段落重建 + 语言检测 | T3–T8 |
| P2 翻译引擎组 | 5 个可插拔引擎 + Keychain + 限速/分块 | T9–T12、T11b |
| P3 导出与管线 | 组装器 + 三格式导出 + 端到端管线 | T13–T17 |
| P4 App 与 UI | 历史 + App 壳 + 查看模块 + 翻译 UI | T18–T21 |
| P5 打包与验收 | dmg 打包 + 验收清单 + 最终审查 | T22 + 最终验收 |

> 下方为按任务(task)的细粒度分解;Phase 是交付视角的聚合,任务是执行/测试/审查的最小单元。

**Goal:** 按 [product-spec.md](product-spec.md)(v1.3)实现 PDFlab:macOS 15+ 原生应用,含"查看"(本地文件对照阅读、同步滚动)与"翻译"(PDF OCR/提取/中英互译,导出 PDF/Word/Markdown)两个模块。

**Architecture:** SPM 双 target——`PDFLabCore`(纯逻辑库:解析/OCR/翻译引擎/导出/管线,全部可 `swift test`)+ `PDFLabApp`(SwiftUI 壳)。翻译引擎为可插拔协议适配器;Vision 与 Translation 框架按 `#available(macOS 26.0, *)` 双路径分支。

**Tech Stack:** Swift 6.2(v5 语言模式)、SwiftUI、PDFKit、Vision、Translation、NaturalLanguage、Swift Testing。零第三方依赖。

> **计划修订(2026-07-03,用户决定)**:有道翻译从"免 Key 非官方接口"改为**有道智云官方 API**(appKey + appSecret,存 Keychain,配置/校验方式同 LLM 引擎)。原因:T10 实测发现免 Key 网页接口响应体已 AES 加密不可解。影响:①新增任务 **T11b**(在 T11 之后,复用 KeychainStore),实现 `YoudaoZhiyunEngine` 替换 T10 已交付的 `YoudaoFreeEngine`(后者保留在 git 历史,可删);②T19 设置面板:有道引擎展开 appKey/appSecret 输入 + "测试连接",与 LLM 同款;③T19 引擎工厂:youdao 分支从 Keychain 取 appKey/appSecret 构造。现在免 Key 引擎只剩 Google、DeepL 两个。

## Global Constraints

- 仓库根目录:`/Users/zzz/Documents/Claude/PDFlab`(下称 `$ROOT`;2026-07-03 已从 "PDF lab" 改名去除空格)。产品事实源为 `$ROOT/product-spec.md`(原 Obsidian `PDFlab.md` 已迁入仓库,只留指针)
- 所有 swift 命令加前缀 `DEVELOPER_DIR=/Library/Developer/CommandLineTools`(系统 /Applications/Xcode.app 是 13.4,禁用;CLT 为 Swift 6.2.4 + macOS 26.2 SDK)
- 最低部署目标 **macOS 15**;macOS 26 专属 API 一律 `if #available(macOS 26.0, *)` 分支,且必须保留 15 的回退路径(开发机即 macOS 15.7,是主要实测环境)
- 零第三方依赖;测试框架用 Swift Testing(`import Testing`)
- **测试文件禁止直接 `import Foundation`**(CLT 缺 `_Testing_Foundation` 跨导入 overlay,会编译失败):Foundation 已由 `Models.swift` 顶部 `@_exported import Foundation` 统一重导出,测试文件经 `@testable import PDFLabCore` 传递获得;测试里需要 PDFKit/Vision 等框架时直接 import 该框架本身(它们不触发此 overlay)
- 界面文案全部经 `L10n` 取值,中英双语;禁止硬编码用户可见字符串
- API Key 只存 Keychain;免 Key 引擎必须经 `RateLimiter` 限速
- 每个任务结束必须 commit;提交信息用 conventional commits(feat:/test:/chore:)
- 数值常量以需求文档为准:历史 20 条、软上限 300 页/100MB、滚动比例 50%–200% 步进 10%、OCR 渲染 300–400 DPI、Google 单次 5000 字符

## 执行分工与模型路由(用户 2026-07-03 指定)

- **主代理**:只做统筹规划、任务分配、进度监控、审查把关和最终成功把控,不亲自写实现代码
- **实现子代理**:每个任务派一个全新子代理执行(subagent-driven development),派发时**显式指定模型**:
  - 简单/轻松任务(计划中已给出完整代码、1-2 个文件、纯转录+测试)→ **sonnet**
  - 复杂任务或遇到不确定问题(多文件集成、系统 API 双路径、逆向接口、调试)→ **fable 5**
  - 实现中途发现复杂度超预期时,升级为 fable 5 重派,不强行让原模型重试
- **任务级审查**:每个任务完成后由审查子代理做规格符合性 + 代码质量双重审查,通过才算完成
- **最终验收**:全部任务完成后,由**独立的 fable 5 代理**(不复用任何实现代理)做整体代码验收,对照 `product-spec.md`(v1.3)与 `验收清单.md`(均在仓库根)
- 各任务模型路由参考:T1/T2/T4/T8/T9/T13/T14/T16/T18/T19/T22 → sonnet;T3/T5/T6/T11 → 视实现情况 sonnet 起步;T7/T10/T12/T15/T17/T20/T21 → fable 5

## 进度追踪与中断恢复(用户 2026-07-03 指定)

- **行动前必须先建任务 to-do list**:执行开始前用任务工具为 22 个任务建立追踪清单,防止会话意外中断或 token 限额导致进度丢失
- **状态实时标记**:派发子代理领取任务前将该任务标为 in_progress;任务审查通过后立即标为 completed——不允许批量补标
- **双保险 ledger**:任务清单之外,同步维护 `$ROOT/.superpowers/sdd/progress.md`,每完成一个任务追加一行 `Task N: complete (commits <base>..<head>, review clean)`(git init 之后开始)
- **恢复规则**:新会话/压缩后恢复时,先读 ledger 和 `git log`,凡 ledger 标记完成的任务一律不重派,从第一个未完成任务继续

## 文件结构总览

```
$ROOT/
  Package.swift
  Makefile                          # build/test/run/bundle 快捷命令
  Sources/PDFLabCore/
    Models.swift                    # 任务2:全部核心类型
    ParagraphBuilder.swift          # 任务3:行→段聚合、跨页重建
    TextChunker.swift  RateLimiter.swift        # 任务4
    PDFTextExtractor.swift          # 任务5:文本层提取/扫描页判定/解锁
    PageRasterizer.swift  ImagePreprocessor.swift  # 任务6
    OCRService.swift                # 任务7:Vision 双路径
    LanguageDetector.swift          # 任务8
    TranslationEngine.swift         # 任务9:协议+错误
    GoogleFreeEngine.swift          # 任务9
    DeepLXEngine.swift  YoudaoFreeEngine.swift   # 任务10
    OpenAICompatEngine.swift  KeychainStore.swift # 任务11
    AppleLocalEngine.swift          # 任务12
    DocumentComposer.swift          # 任务13:输出内容×分页模式
    MarkdownExporter.swift          # 任务14
    PDFExporter.swift               # 任务15
    DocxExporter.swift              # 任务16
    TranslationPipeline.swift       # 任务17:编排/进度/取消
    HistoryStore.swift              # 任务18
    ScrollSyncMath.swift            # 任务20:同步滚动纯数学
  Sources/PDFLabApp/
    PDFLabApp.swift  MainView.swift  L10n.swift  SettingsView.swift  # 任务19
    AppleTranslationHost.swift      # 任务12:macOS15 隐藏宿主视图
    ViewerView.swift  DualPaneController.swift   # 任务20
    TranslateFlowView.swift  PreviewView.swift   # 任务21
  Tests/PDFLabCoreTests/            # 与 Sources 文件一一对应的 *Tests.swift
  scripts/bundle_app.sh             # 任务22:打 .app
  docs/验收清单.md                  # 任务22
```

---

### Task 1: Git 仓库与 SPM 脚手架

**Files:**
- Create: `Package.swift`, `Makefile`, `.gitignore`, `Sources/PDFLabCore/Placeholder.swift`, `Sources/PDFLabApp/PDFLabApp.swift`, `Tests/PDFLabCoreTests/SmokeTests.swift`

**Interfaces:**
- Produces: 可构建的双 target 包;`make test` / `make run` 可用

- [ ] **Step 1: git init 并写 .gitignore**

```bash
cd "/Users/zzz/Documents/Claude/PDFlab" && git init
printf '.build/\n.DS_Store\n*.app\n*.dmg\n' > .gitignore
```

- [ ] **Step 2: 写 Package.swift**

```swift
// swift-tools-version:6.0
import PackageDescription

let package = Package(
    name: "PDFlab",
    defaultLocalization: "zh-Hans",
    platforms: [.macOS(.v15)],
    targets: [
        .target(name: "PDFLabCore",
                swiftSettings: [.swiftLanguageMode(.v5)]),
        .executableTarget(name: "PDFLabApp",
                dependencies: ["PDFLabCore"],
                swiftSettings: [.swiftLanguageMode(.v5)]),
        .testTarget(name: "PDFLabCoreTests",
                dependencies: ["PDFLabCore"],
                swiftSettings: [.swiftLanguageMode(.v5)]),
    ]
)
```

- [ ] **Step 3: 写最小源文件与冒烟测试**

`Sources/PDFLabCore/Placeholder.swift`:
```swift
public enum PDFLabCoreInfo { public static let version = "0.1.0" }
```

`Sources/PDFLabApp/PDFLabApp.swift`:
```swift
import SwiftUI
import PDFLabCore

@main
struct PDFLabApp: App {
    var body: some Scene {
        WindowGroup { Text("PDFlab \(PDFLabCoreInfo.version)") }
    }
}
```

`Tests/PDFLabCoreTests/SmokeTests.swift`:
```swift
import Testing
@testable import PDFLabCore

@Test func smokeVersion() {
    #expect(PDFLabCoreInfo.version == "0.1.0")
}
```

- [ ] **Step 4: 写 Makefile**

```makefile
DEV := DEVELOPER_DIR=/Library/Developer/CommandLineTools
# CLT 的 SwiftPM 不会自动把 Testing.framework 加入框架搜索路径,必须显式传 -F/-rpath
FW  := /Library/Developer/CommandLineTools/Library/Developer/Frameworks
TESTFLAGS := -Xswiftc -F$(FW) -Xlinker -F$(FW) -Xlinker -rpath -Xlinker $(FW)
build: ; $(DEV) swift build
test:  ; $(DEV) swift test $(TESTFLAGS)
run:   ; $(DEV) swift run PDFLabApp
bundle:; bash scripts/bundle_app.sh
```

- [ ] **Step 5: 验证测试通过**

Run: `cd "/Users/zzz/Documents/Claude/PDFlab" && make test`
Expected: `Test smokeVersion() passed`。
若报 "no such module Testing":说明 CLT 缺 Swift Testing,停下来向用户报告,建议安装新版完整 Xcode 后调整 DEVELOPER_DIR;不要擅自改用 XCTest。

- [ ] **Step 6: Commit**

```bash
git add -A && git commit -m "chore: SPM scaffold with Core/App targets and smoke test"
```

---

### Task 2: 核心数据模型

**Files:**
- Create: `Sources/PDFLabCore/Models.swift`
- Test: `Tests/PDFLabCoreTests/ModelsTests.swift`
- Delete: `Sources/PDFLabCore/Placeholder.swift`(version 常量并入 Models.swift)

**Interfaces:**
- Produces(后续所有任务依赖,签名必须一字不差):

```swift
public enum PDFLabCoreInfo { public static let version = "0.1.0" }

/// 一段源文本。pageIndex 从 0 计,是段落起始页(跨页段落归起始页)。
public struct SourceParagraph: Equatable, Sendable {
    public var text: String
    public var pageIndex: Int
    public var ocrConfidence: Double?   // nil = 来自文本层非 OCR
    public init(text: String, pageIndex: Int, ocrConfidence: Double? = nil)
}

/// 解析完成的整篇文档。
public struct ParsedDocument: Equatable, Sendable {
    public var paragraphs: [SourceParagraph]
    public var pageCount: Int
    public var lowQualityPages: [Int]   // 置信度兜底标记的页
    public init(paragraphs: [SourceParagraph], pageCount: Int, lowQualityPages: [Int] = [])
}

public enum TranslationDirection: String, Sendable, CaseIterable {
    case enToZh, zhToEn
}

public enum OutputContent: String, Sendable, CaseIterable { case translationOnly, bilingual, extractionOnly }
public enum OutputFormat: String, Sendable, CaseIterable { case pdf, docx, markdown }
public enum PageMode: String, Sendable, CaseIterable { case continuous, pageAligned }

public struct ExportOptions: Equatable, Sendable {
    public var content: OutputContent
    public var format: OutputFormat
    public var pageMode: PageMode
    public init(content: OutputContent, format: OutputFormat, pageMode: PageMode)
}

/// 组装后待渲染的块(任务13产出,任务14-16消费)。
public enum ComposedBlock: Equatable, Sendable {
    case pageBreak(pageIndex: Int)        // 按页模式的页边界(pageIndex 为新页,0 计)
    case sourceText(String)
    case translatedText(String)
}
public struct ComposedDocument: Equatable, Sendable {
    public var blocks: [ComposedBlock]
    public var direction: TranslationDirection?
    public init(blocks: [ComposedBlock], direction: TranslationDirection?)
}

/// 管线进度(任务17产出,UI 消费)。
public enum PipelineStage: String, Sendable { case parsing, ocr, translating, composing }
public struct PipelineProgress: Equatable, Sendable {
    public var stage: PipelineStage
    public var currentPage: Int   // 1 计,用于显示
    public var totalPages: Int
    public init(stage: PipelineStage, currentPage: Int, totalPages: Int)
}

/// 全应用统一错误。localizedDescription 由 UI 层经 L10n 映射,Core 只给 case。
public enum PDFLabError: Error, Equatable, Sendable {
    case fileUnreadable
    case notAPDF
    case encryptedPDFWrongPassword
    case noTextRecognized
    case unsupportedLanguage(detected: String)
    case languagePackMissing
    case engineInvalidKey
    case engineRateLimited
    case engineUnavailable(engineID: String)
    case networkError(String)
    case exportWriteFailed(String)
    case cancelled
}
```

- [ ] **Step 1: 写测试**(`ModelsTests.swift`)

```swift
import Testing
@testable import PDFLabCore

@Test func paragraphEquality() {
    let a = SourceParagraph(text: "hi", pageIndex: 0)
    #expect(a == SourceParagraph(text: "hi", pageIndex: 0))
    #expect(a.ocrConfidence == nil)
}
@Test func optionsRoundtrip() {
    let o = ExportOptions(content: .bilingual, format: .markdown, pageMode: .pageAligned)
    #expect(o.content.rawValue == "bilingual")
    #expect(OutputFormat.allCases.count == 3)
}
@Test func composedBlocks() {
    let d = ComposedDocument(blocks: [.pageBreak(pageIndex: 0), .sourceText("s"), .translatedText("t")], direction: .enToZh)
    #expect(d.blocks.count == 3)
}
```

- [ ] **Step 2: 跑测试确认失败**(类型不存在,编译错误即为"失败")
- [ ] **Step 3: 实现 Models.swift**(按上方 Interfaces 全量实现,init 逐字段赋值,无额外逻辑)
- [ ] **Step 4: `make test` 全绿**
- [ ] **Step 5: Commit** `feat: core data models and error taxonomy`

---

### Task 3: 段落聚合与跨页重建

**Files:**
- Create: `Sources/PDFLabCore/ParagraphBuilder.swift`
- Test: `Tests/PDFLabCoreTests/ParagraphBuilderTests.swift`

**Interfaces:**
- Consumes: `SourceParagraph`
- Produces:

```swift
/// 一行文本及几何信息(OCR 或文本层均产出此结构;bbox 为页内归一化坐标,原点左下)。
public struct TextLine: Equatable, Sendable {
    public var text: String
    public var pageIndex: Int
    public var bbox: CGRect
    public var confidence: Double?
    public init(text: String, pageIndex: Int, bbox: CGRect, confidence: Double? = nil)
}

public enum ParagraphBuilder {
    /// 行→段:相邻行垂直间距 ≤ 行高×1.6 且水平重叠则并段;段内英文行以空格连接,中文行直接连接;行尾连字符去掉并无缝连接。
    public static func buildParagraphs(from lines: [TextLine]) -> [SourceParagraph]
    /// 跨页合并:前段末字符不是句末标点(。.!?;;:」”"』)且后段首字符是小写字母或中文续写,则并段,归属前段起始页。
    public static func mergeAcrossPages(_ paragraphs: [SourceParagraph]) -> [SourceParagraph]
}
```

- [ ] **Step 1: 写测试**

```swift
import Testing
import CoreGraphics
@testable import PDFLabCore

private func line(_ t: String, page: Int = 0, y: CGFloat, conf: Double? = nil) -> TextLine {
    TextLine(text: t, pageIndex: page, bbox: CGRect(x: 0.1, y: y, width: 0.8, height: 0.03), confidence: conf)
}

@Test func groupsAdjacentLinesIntoParagraph() {
    let ps = ParagraphBuilder.buildParagraphs(from: [
        line("The quick brown", y: 0.90), line("fox jumps.", y: 0.865),
        line("New paragraph here.", y: 0.70),   // 间距远大于 1.6 倍行高 → 分段
    ])
    #expect(ps.map(\.text) == ["The quick brown fox jumps.", "New paragraph here."])
}
@Test func joinsChineseWithoutSpaceAndStripsHyphen() {
    let zh = ParagraphBuilder.buildParagraphs(from: [line("这是第一", y: 0.9), line("行文字。", y: 0.865)])
    #expect(zh.first?.text == "这是第一行文字。")
    let hy = ParagraphBuilder.buildParagraphs(from: [line("hyphen-", y: 0.9), line("ated word", y: 0.865)])
    #expect(hy.first?.text == "hyphenated word")
}
@Test func mergesCrossPageAndKeepsStartPage() {
    let merged = ParagraphBuilder.mergeAcrossPages([
        SourceParagraph(text: "This sentence continues", pageIndex: 0),
        SourceParagraph(text: "on the next page.", pageIndex: 1),
        SourceParagraph(text: "完整的一段。", pageIndex: 1),
    ])
    #expect(merged.count == 2)
    #expect(merged[0].text == "This sentence continues on the next page.")
    #expect(merged[0].pageIndex == 0)
}
@Test func doesNotMergeWhenSentenceEnded() {
    let merged = ParagraphBuilder.mergeAcrossPages([
        SourceParagraph(text: "Sentence done.", pageIndex: 0),
        SourceParagraph(text: "Next page para.", pageIndex: 1),
    ])
    #expect(merged.count == 2)
}
```

- [ ] **Step 2: 跑测试确认失败**
- [ ] **Step 3: 实现**

```swift
import CoreGraphics
import Foundation

public struct TextLine: Equatable, Sendable { /* 按 Interfaces */ }

public enum ParagraphBuilder {
    private static let sentenceEnders: Set<Character> = ["。", ".", "!", "?", "!", "?", ";", ";", ":", ":", "」", "”", "\"", "』"]

    public static func buildParagraphs(from lines: [TextLine]) -> [SourceParagraph] {
        var result: [SourceParagraph] = []
        var current: (text: String, page: Int, confs: [Double], lastBox: CGRect)? = nil

        func flush() {
            if let c = current {
                let conf = c.confs.isEmpty ? nil : c.confs.reduce(0, +) / Double(c.confs.count)
                result.append(SourceParagraph(text: c.text, pageIndex: c.page, ocrConfidence: conf))
            }
            current = nil
        }
        for l in lines {
            guard var c = current, c.page == l.pageIndex else { flush(); current = (l.text, l.pageIndex, l.confidence.map { [$0] } ?? [], l.bbox); continue }
            let gap = c.lastBox.minY - l.bbox.maxY          // 归一化坐标,原点左下,行自上而下
            let sameParagraph = gap <= l.bbox.height * 0.6  // 间距 ≤ 0.6 倍行高(即行距 ≤ 1.6 倍行高)
            if sameParagraph {
                c.text = join(c.text, l.text)
                if let cf = l.confidence { c.confs.append(cf) }
                c.lastBox = l.bbox
                current = c
            } else { flush(); current = (l.text, l.pageIndex, l.confidence.map { [$0] } ?? [], l.bbox) }
        }
        flush()
        return result
    }

    public static func mergeAcrossPages(_ paragraphs: [SourceParagraph]) -> [SourceParagraph] {
        var out: [SourceParagraph] = []
        for p in paragraphs {
            if var prev = out.last, prev.pageIndex < p.pageIndex,
               let lastChar = prev.text.last, !sentenceEnders.contains(lastChar),
               let firstChar = p.text.first, isContinuation(firstChar) {
                prev.text = join(prev.text, p.text)
                out[out.count - 1] = prev
            } else { out.append(p) }
        }
        return out
    }

    private static func isContinuation(_ ch: Character) -> Bool {
        ch.isLowercase || ch.unicodeScalars.first.map { (0x4E00...0x9FFF).contains($0.value) } ?? false
    }
    private static func join(_ a: String, _ b: String) -> String {
        if a.hasSuffix("-") { return String(a.dropLast()) + b }
        let aCJK = a.last.map { $0.unicodeScalars.first.map { (0x2E80...0x9FFF).contains($0.value) } ?? false } ?? false
        let bCJK = b.first.map { $0.unicodeScalars.first.map { (0x2E80...0x9FFF).contains($0.value) } ?? false } ?? false
        return (aCJK && bCJK) ? a + b : a + " " + b
    }
}
```

- [ ] **Step 4: `make test` 全绿**
- [ ] **Step 5: Commit** `feat: paragraph grouping and cross-page merge`

---

### Task 4: 文本分块器与限速器

**Files:**
- Create: `Sources/PDFLabCore/TextChunker.swift`, `Sources/PDFLabCore/RateLimiter.swift`
- Test: `Tests/PDFLabCoreTests/TextChunkerTests.swift`, `Tests/PDFLabCoreTests/RateLimiterTests.swift`

**Interfaces:**
- Produces:

```swift
public enum TextChunker {
    /// 把超过 limit 字符的文本按句子边界切块,每块 ≤ limit;单句超限则硬切。
    public static func split(_ text: String, limit: Int) -> [String]
}
public actor RateLimiter {
    public init(minInterval: TimeInterval)
    /// 距上次放行不足 minInterval 则挂起等待。
    public func waitTurn() async
}
```

- [ ] **Step 1: 写测试**

```swift
import Testing
@testable import PDFLabCore

@Test func shortTextSingleChunk() {
    #expect(TextChunker.split("hello world.", limit: 100) == ["hello world."])
}
@Test func splitsAtSentenceBoundary() {
    let chunks = TextChunker.split("第一句。第二句。第三句。", limit: 8)
    #expect(chunks == ["第一句。第二句。", "第三句。"])
    #expect(chunks.allSatisfy { $0.count <= 8 })
}
@Test func hardSplitsOversizedSentence() {
    let chunks = TextChunker.split(String(repeating: "a", count: 25), limit: 10)
    #expect(chunks.count == 3)
    #expect(chunks.joined() == String(repeating: "a", count: 25))
}
@Test func rateLimiterEnforcesInterval() async {
    let rl = RateLimiter(minInterval: 0.2)
    let t0 = Date()
    await rl.waitTurn(); await rl.waitTurn(); await rl.waitTurn()
    #expect(Date().timeIntervalSince(t0) >= 0.4)
}
```

- [ ] **Step 2: 跑测试确认失败**
- [ ] **Step 3: 实现**

```swift
// TextChunker.swift
import Foundation
public enum TextChunker {
    public static func split(_ text: String, limit: Int) -> [String] {
        guard text.count > limit else { return [text] }
        var sentences: [String] = []
        var cur = ""
        for ch in text {
            cur.append(ch)
            if "。.!?!?".contains(ch) { sentences.append(cur); cur = "" }
        }
        if !cur.isEmpty { sentences.append(cur) }
        var chunks: [String] = []
        var buf = ""
        for var s in sentences {
            while s.count > limit {                       // 单句超限硬切
                if !buf.isEmpty { chunks.append(buf); buf = "" }
                chunks.append(String(s.prefix(limit)))
                s = String(s.dropFirst(limit))
            }
            if buf.count + s.count > limit { chunks.append(buf); buf = s }
            else { buf += s }
        }
        if !buf.isEmpty { chunks.append(buf) }
        return chunks
    }
}

// RateLimiter.swift
import Foundation
public actor RateLimiter {
    private let minInterval: TimeInterval
    private var lastFire: Date = .distantPast
    public init(minInterval: TimeInterval) { self.minInterval = minInterval }
    public func waitTurn() async {
        let wait = minInterval - Date().timeIntervalSince(lastFire)
        if wait > 0 { try? await Task.sleep(nanoseconds: UInt64(wait * 1e9)) }
        lastFire = Date()
    }
}
```

- [ ] **Step 4: `make test` 全绿**
- [ ] **Step 5: Commit** `feat: sentence-boundary chunker and actor rate limiter`

---

### Task 5: PDF 文本层提取与扫描页判定

**Files:**
- Create: `Sources/PDFLabCore/PDFTextExtractor.swift`
- Test: `Tests/PDFLabCoreTests/PDFTextExtractorTests.swift`(测试内用 PDFKit 动态生成样例 PDF)

**Interfaces:**
- Consumes: `TextLine`, `PDFLabError`
- Produces:

```swift
import PDFKit

public struct PageExtraction: Sendable {
    public var pageIndex: Int
    public var lines: [TextLine]     // 文本层逐行(含 bbox);空数组 = 需要 OCR 的扫描页
    public var isScanned: Bool
}
public enum PDFTextExtractor {
    /// 打开文档;加密时用 password 解锁,失败抛 encryptedPDFWrongPassword,损坏抛 fileUnreadable。
    public static func openDocument(at url: URL, password: String?) throws -> PDFDocument
    /// 提取单页文本行。文本字符数 < 20 判定为扫描页(isScanned=true, lines=[])。
    public static func extractPage(_ doc: PDFDocument, pageIndex: Int) -> PageExtraction
}
```

- [ ] **Step 1: 写测试**——用 PDFKit 在临时目录生成:①含两行文字的 PDF ②空白页 PDF ③设了 ownerPassword+userPassword 的加密 PDF,分别断言:提取出的行文本正确、空白页 `isScanned == true`、错误密码抛 `encryptedPDFWrongPassword`、正确密码解锁成功、随机字节文件抛 `fileUnreadable`。生成样例代码:

```swift
import Testing
import PDFKit
@testable import PDFLabCore

private func makePDF(text: String?, password: String? = nil) throws -> URL {
    let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString + ".pdf")
    let page = NSRect(x: 0, y: 0, width: 612, height: 792)
    var mediaBox = page
    var opts: [CFString: Any] = [:]
    if let pw = password { opts[kCGPDFContextUserPassword] = pw; opts[kCGPDFContextOwnerPassword] = pw }
    let ctx = CGContext(url as CFURL, mediaBox: &mediaBox, opts as CFDictionary)!
    ctx.beginPDFPage(nil)
    if let text {
        let attr = NSAttributedString(string: text, attributes: [.font: NSFont.systemFont(ofSize: 14)])
        let line = CTLineCreateWithAttributedString(attr)
        ctx.textPosition = CGPoint(x: 72, y: 700)
        CTLineDraw(line, ctx)
    }
    ctx.endPDFPage(); ctx.closePDF()
    return url
}

@Test func extractsTextLayer() throws {
    let url = try makePDF(text: "Hello PDFlab world of testing")
    let doc = try PDFTextExtractor.openDocument(at: url, password: nil)
    let ex = PDFTextExtractor.extractPage(doc, pageIndex: 0)
    #expect(ex.isScanned == false)
    #expect(ex.lines.first?.text.contains("Hello PDFlab") == true)
}
@Test func blankPageIsScanned() throws {
    let doc = try PDFTextExtractor.openDocument(at: try makePDF(text: nil), password: nil)
    #expect(PDFTextExtractor.extractPage(doc, pageIndex: 0).isScanned == true)
}
@Test func wrongPasswordThrows() throws {
    let url = try makePDF(text: "secret content here padded", password: "pw123")
    #expect(throws: PDFLabError.encryptedPDFWrongPassword) {
        _ = try PDFTextExtractor.openDocument(at: url, password: "wrong")
    }
    _ = try PDFTextExtractor.openDocument(at: url, password: "pw123") // 正确密码不抛
}
@Test func garbageFileThrows() throws {
    let url = FileManager.default.temporaryDirectory.appendingPathComponent("g.pdf")
    try Data([0x00, 0x01, 0x02]).write(to: url)
    #expect(throws: PDFLabError.fileUnreadable) { _ = try PDFTextExtractor.openDocument(at: url, password: nil) }
}
```

- [ ] **Step 2: 跑测试确认失败**
- [ ] **Step 3: 实现**

```swift
import PDFKit

public struct PageExtraction: Sendable { /* 按 Interfaces */ }

public enum PDFTextExtractor {
    public static func openDocument(at url: URL, password: String?) throws -> PDFDocument {
        guard let doc = PDFDocument(url: url) else { throw PDFLabError.fileUnreadable }
        if doc.isLocked {
            guard let pw = password, doc.unlock(withPassword: pw) else {
                throw PDFLabError.encryptedPDFWrongPassword
            }
        }
        guard doc.pageCount > 0 else { throw PDFLabError.fileUnreadable }
        return doc
    }

    public static func extractPage(_ doc: PDFDocument, pageIndex: Int) -> PageExtraction {
        guard let page = doc.page(at: pageIndex), let content = page.string,
              content.trimmingCharacters(in: .whitespacesAndNewlines).count >= 20 else {
            return PageExtraction(pageIndex: pageIndex, lines: [], isScanned: true)
        }
        let pageBounds = page.bounds(for: .mediaBox)
        var lines: [TextLine] = []
        for raw in content.components(separatedBy: .newlines) {
            let t = raw.trimmingCharacters(in: .whitespaces)
            guard !t.isEmpty else { continue }
            // 用 PDFKit selection 拿行框;取不到时退化为按序等高分布
            let idx = lines.count
            var bbox = CGRect(x: 0.1, y: 0.9 - CGFloat(idx) * 0.035, width: 0.8, height: 0.03)
            if let sel = doc.findString(t, withOptions: .literal).first(where: { $0.pages.first == page }) {
                let r = sel.bounds(for: page)
                bbox = CGRect(x: r.minX / pageBounds.width, y: r.minY / pageBounds.height,
                              width: r.width / pageBounds.width, height: r.height / pageBounds.height)
            }
            lines.append(TextLine(text: t, pageIndex: pageIndex, bbox: bbox, confidence: nil))
        }
        return PageExtraction(pageIndex: pageIndex, lines: lines, isScanned: lines.isEmpty)
    }
}
```

- [ ] **Step 4: `make test` 全绿**
- [ ] **Step 5: Commit** `feat: PDF text-layer extraction, scan detection, unlock`

---

### Task 6: 页面栅格化与图像预处理

**Files:**
- Create: `Sources/PDFLabCore/PageRasterizer.swift`, `Sources/PDFLabCore/ImagePreprocessor.swift`
- Test: `Tests/PDFLabCoreTests/PageRasterizerTests.swift`

**Interfaces:**
- Produces:

```swift
public enum PageRasterizer {
    /// 按 targetDPI(默认 350,夹在 300...400)渲染页面;单边超过 maxPixels(6000)时整体降比例。
    public static func rasterize(page: PDFPage, targetDPI: CGFloat) -> CGImage?
}
public enum ImagePreprocessor {
    /// 灰度 + 对比度增强 + 去斜 + 降噪(CoreImage: CIColorControls/CIDocumentEnhancer 路径),仅供低置信度页重试用。
    public static func enhance(_ image: CGImage) -> CGImage
}
```

- [ ] **Step 1: 写测试**——生成一页 612×792pt 的样例 PDF,断言:`rasterize` 350DPI 产出宽度 ≈ 612/72×350 (±2px);超大页(2000pt 宽)产出宽度 ≤ 6000;`enhance` 返回同尺寸图像。
- [ ] **Step 2: 确认失败**
- [ ] **Step 3: 实现**——`rasterize` 用 `page.thumbnail(of:for:)` 不可控,改用 CGContext:`scale = targetDPI/72`,建 `CGContext(data:nil,width:,height:,bitsPerComponent:8,...)`,白底填充后 `page.draw(with:.mediaBox,to:ctx)`;`enhance` 用 CIFilter 链(CIColorControls saturation 0 → contrast 1.25 → CIGaussianBlur radius 0.5 反锐化可省),输出经 CIContext 渲染回 CGImage。
- [ ] **Step 4: `make test` 全绿**
- [ ] **Step 5: Commit** `feat: page rasterizer (300-400 DPI) and preprocess filter`

---

### Task 7: OCR 服务(Vision 双路径)

**Files:**
- Create: `Sources/PDFLabCore/OCRService.swift`
- Test: `Tests/PDFLabCoreTests/OCRServiceTests.swift`

**Interfaces:**
- Consumes: `PageRasterizer`, `ImagePreprocessor`, `TextLine`
- Produces:

```swift
public struct OCRService: Sendable {
    public init(primaryChinese: Bool)   // true 时识别语言序 ["zh-Hans","en-US"],否则反序
    /// 识别一页:macOS26+ 走 RecognizeDocumentsRequest(取段落结构),否则 RecognizeTextRequest(.accurate,usesLanguageCorrection)。
    /// 整页平均置信度 < 0.5 时,ImagePreprocessor.enhance 后重试一次,取置信度高的结果。
    /// 返回 (lines, pageConfidence);无文字时 lines 为空。
    public func recognizePage(_ image: CGImage, pageIndex: Int) async throws -> (lines: [TextLine], confidence: Double)
}
```

- [ ] **Step 1: 写测试**——用 CoreGraphics 绘一张含 "PDFlab OCR Test 2026" 文本的位图(白底黑字 72pt),断言识别结果拼接文本包含 "OCR" 且 confidence > 0.3;再用纯白图断言 lines 为空。真机 Vision 可用,此测试在本机可跑。
- [ ] **Step 2: 确认失败**
- [ ] **Step 3: 实现**——新式 Swift Vision API:

```swift
import Vision
import CoreGraphics

public struct OCRService: Sendable {
    private let languages: [Locale.Language]
    public init(primaryChinese: Bool) {
        let zh = Locale.Language(identifier: "zh-Hans"), en = Locale.Language(identifier: "en-US")
        languages = primaryChinese ? [zh, en] : [en, zh]
    }

    public func recognizePage(_ image: CGImage, pageIndex: Int) async throws -> (lines: [TextLine], confidence: Double) {
        let first = try await runOnce(image, pageIndex: pageIndex)
        if first.confidence < 0.5 {
            let retry = try await runOnce(ImagePreprocessor.enhance(image), pageIndex: pageIndex)
            return retry.confidence > first.confidence ? retry : first
        }
        return first
    }

    private func runOnce(_ image: CGImage, pageIndex: Int) async throws -> (lines: [TextLine], confidence: Double) {
        if #available(macOS 26.0, *) {
            var req = RecognizeDocumentsRequest()
            req.recognitionLanguages = languages
            let observations = try await req.perform(on: image)
            var lines: [TextLine] = []
            for doc in observations {
                for para in doc.document.paragraphs {
                    let t = para.transcript
                    guard !t.isEmpty else { continue }
                    lines.append(TextLine(text: t, pageIndex: pageIndex,
                                          bbox: para.boundingRegion.boundingBox.cgRect, confidence: 0.9))
                }
            }
            let conf = lines.isEmpty ? 0 : 0.9
            return (lines, conf)
        } else {
            var req = RecognizeTextRequest()
            req.recognitionLevel = .accurate
            req.usesLanguageCorrection = true
            req.recognitionLanguages = languages
            let observations = try await req.perform(on: image)
            var lines: [TextLine] = []
            var confSum = 0.0
            for obs in observations {
                guard let cand = obs.topCandidates(1).first else { continue }
                lines.append(TextLine(text: cand.string, pageIndex: pageIndex,
                                      bbox: obs.boundingBox.cgRect, confidence: Double(cand.confidence)))
                confSum += Double(cand.confidence)
            }
            return (lines, lines.isEmpty ? 0 : confSum / Double(lines.count))
        }
    }
}
```
(编译时若 `RecognizeDocumentsRequest` 的段落 API 名不符,以 SDK 头文件为准调整——26 分支在开发机 macOS 15 上编译但不执行,重点保证 15 分支正确。)

- [ ] **Step 4: `make test` 全绿**
- [ ] **Step 5: Commit** `feat: Vision OCR with version branch and confidence retry`

---

### Task 8: 语言检测与翻译方向

**Files:**
- Create: `Sources/PDFLabCore/LanguageDetector.swift`
- Test: `Tests/PDFLabCoreTests/LanguageDetectorTests.swift`

**Interfaces:**
- Produces:

```swift
public enum LanguageDetector {
    /// 取前 4000 字符经 NLLanguageRecognizer 检测;zh* → zhToEn,en → enToZh,其余返回 nil(UI 弹"仅支持中英文档"让用户强制指定)。
    public static func detectDirection(sample: String) -> TranslationDirection?
    public static func detectedLanguageName(sample: String) -> String   // 供错误提示显示,如 "ja"
}
```

- [ ] **Step 1: 写测试**——英文段落 → `.enToZh`;中文段落 → `.zhToEn`;日文段落 → `nil` 且 name 为 "ja";空串 → nil。
- [ ] **Step 2: 确认失败**
- [ ] **Step 3: 实现**——`NLLanguageRecognizer.processString`,取 `dominantLanguage`,`.simplifiedChinese/.traditionalChinese → .zhToEn`,`.english → .enToZh`。
- [ ] **Step 4: `make test` 全绿**
- [ ] **Step 5: Commit** `feat: language detection and direction decision`

---

### Task 9: 翻译引擎协议 + Google 免 Key 引擎

**Files:**
- Create: `Sources/PDFLabCore/TranslationEngine.swift`, `Sources/PDFLabCore/GoogleFreeEngine.swift`
- Test: `Tests/PDFLabCoreTests/GoogleFreeEngineTests.swift`

**Interfaces:**
- Consumes: `TextChunker`, `RateLimiter`, `TranslationDirection`, `PDFLabError`
- Produces(全部引擎实现同一协议;任务10/11/12 逐字复用):

```swift
public protocol TranslationEngine: Sendable {
    var id: String { get }                 // "apple"/"llm"/"google"/"deepl"/"youdao"
    var isUnofficial: Bool { get }         // UI 标注"非官方接口,可能不稳定"
    var perRequestCharLimit: Int { get }
    func translate(_ texts: [String], direction: TranslationDirection) async throws -> [String]
}
/// 供测试注入的 URLSession 协议封装
public protocol HTTPClient: Sendable {
    func data(for request: URLRequest) async throws -> (Data, URLResponse)
}
extension URLSession: HTTPClient {}

public struct GoogleFreeEngine: TranslationEngine {
    public init(client: HTTPClient = URLSession.shared, limiter: RateLimiter = RateLimiter(minInterval: 0.5))
    // id="google", isUnofficial=true, perRequestCharLimit=5000
}
```

- [ ] **Step 1: 写测试**——`MockHTTPClient`(记录 request、返回预置 JSON)。断言:①请求 URL 为 `https://translate.googleapis.com/translate_a/single` 且 query 含 `client=gtx`、`sl=en`、`tl=zh-CN`、`q=Hello`;②Google 返回体 `[[["你好","Hello",null,null,10]],null,"en"]` 解析出 `["你好"]`;③HTTP 429 抛 `engineRateLimited`;④非 2xx 抛 `engineUnavailable("google")`;⑤超 5000 字符文本自动经 TextChunker 分块、多次请求、结果拼接。
- [ ] **Step 2: 确认失败**
- [ ] **Step 3: 实现**

```swift
import Foundation

public struct GoogleFreeEngine: TranslationEngine {
    public let id = "google", isUnofficial = true, perRequestCharLimit = 5000
    private let client: HTTPClient
    private let limiter: RateLimiter
    public init(client: HTTPClient = URLSession.shared, limiter: RateLimiter = RateLimiter(minInterval: 0.5)) {
        self.client = client; self.limiter = limiter
    }

    public func translate(_ texts: [String], direction: TranslationDirection) async throws -> [String] {
        var results: [String] = []
        for text in texts {
            var translated = ""
            for chunk in TextChunker.split(text, limit: perRequestCharLimit) {
                await limiter.waitTurn()
                translated += try await translateChunk(chunk, direction: direction)
            }
            results.append(translated)
        }
        return results
    }

    private func translateChunk(_ q: String, direction: TranslationDirection) async throws -> String {
        let (sl, tl) = direction == .enToZh ? ("en", "zh-CN") : ("zh-CN", "en")
        var comps = URLComponents(string: "https://translate.googleapis.com/translate_a/single")!
        comps.queryItems = [.init(name: "client", value: "gtx"), .init(name: "sl", value: sl),
                            .init(name: "tl", value: tl), .init(name: "dt", value: "t"), .init(name: "q", value: q)]
        let (data, resp): (Data, URLResponse)
        do { (data, resp) = try await client.data(for: URLRequest(url: comps.url!)) }
        catch { throw PDFLabError.networkError(error.localizedDescription) }
        guard let http = resp as? HTTPURLResponse else { throw PDFLabError.engineUnavailable(engineID: id) }
        if http.statusCode == 429 { throw PDFLabError.engineRateLimited }
        guard (200..<300).contains(http.statusCode) else { throw PDFLabError.engineUnavailable(engineID: id) }
        guard let root = try? JSONSerialization.jsonObject(with: data) as? [Any],
              let sentences = root.first as? [[Any]] else { throw PDFLabError.engineUnavailable(engineID: id) }
        return sentences.compactMap { $0.first as? String }.joined()
    }
}
```
(`TranslationEngine.swift` 单独放协议 + `HTTPClient`。)

- [ ] **Step 4: `make test` 全绿**
- [ ] **Step 5: Commit** `feat: engine protocol and Google free (gtx) engine`

---

### Task 10: DeepLX 引擎与有道免 Key 引擎

**Files:**
- Create: `Sources/PDFLabCore/DeepLXEngine.swift`, `Sources/PDFLabCore/YoudaoFreeEngine.swift`
- Test: `Tests/PDFLabCoreTests/FreeEnginesTests.swift`

**Interfaces:**
- Consumes: `TranslationEngine`, `HTTPClient`, `RateLimiter`, `TextChunker`
- Produces: `DeepLXEngine`(id="deepl", isUnofficial=true, perRequestCharLimit=3000, minInterval=2.0——DeepL 封控最严)、`YoudaoFreeEngine`(id="youdao", isUnofficial=true, perRequestCharLimit=4000, minInterval=1.0)

- [ ] **Step 1: 写测试**——同 Task 9 的 Mock 模式:
  - DeepLX:断言 POST `https://www2.deepl.com/jsonrpc`,body 为 `LMT_handle_texts` JSON-RPC(含 `params.texts[0].text`、`source_lang`/`target_lang` EN/ZH),预置响应 `{"jsonrpc":"2.0","result":{"texts":[{"text":"你好"}]}}` 解析出 `["你好"]`;429 抛 `engineRateLimited`。
  - 有道:先测签名函数 `youdaoSign(query:salt:time:)`(md5 链路,输入固定则输出固定,断言 32 位 hex);再断言 POST `https://dict.youdao.com/webtranslate` 表单含 sign 字段;预置响应解析;非 2xx 抛 `engineUnavailable("youdao")`。
- [ ] **Step 2: 确认失败**
- [ ] **Step 3: 实现**——结构与 GoogleFreeEngine 相同(init 注入 client/limiter,translate 走 chunk 循环);DeepLX 的 id 字段用时间戳生成规则(`(ts / iCount) * iCount` 经典算法);有道签名用 CryptoKit 的 `Insecure.MD5`。两个引擎的端点与签名细节以运行期实测为准——**实现后必须真实调用一次验证**(见 Step 4)。
- [ ] **Step 4: Mock 测试全绿后,写一个手动集成脚本** `scripts/probe_engines.swift`(swift 脚本,各引擎真实翻译 "Hello world" 一次并打印),运行确认 Google 可用;DeepLX/有道若被封或签名失效,在引擎内抛 `engineUnavailable`,UI 会提示切换——不阻塞本任务
- [ ] **Step 5: Commit** `feat: DeepLX and Youdao free engines with probe script`

---

### Task 11: LLM(OpenAI 兼容)引擎 + Keychain

**Files:**
- Create: `Sources/PDFLabCore/OpenAICompatEngine.swift`, `Sources/PDFLabCore/KeychainStore.swift`
- Test: `Tests/PDFLabCoreTests/OpenAICompatEngineTests.swift`, `Tests/PDFLabCoreTests/KeychainStoreTests.swift`

**Interfaces:**
- Produces:

```swift
public struct LLMConfig: Codable, Equatable, Sendable {
    public var baseURL: String    // 如 https://api.deepseek.com/v1
    public var model: String
    public init(baseURL: String, model: String)
}
public struct OpenAICompatEngine: TranslationEngine {
    public init(config: LLMConfig, apiKey: String, client: HTTPClient = URLSession.shared)
    // id="llm", isUnofficial=false, perRequestCharLimit=8000
    /// 设置面板"测试连接":发一条 "ping"→期待非空回复;失败按状态码映射 engineInvalidKey/networkError。
    public func testConnection() async throws
}
public enum KeychainStore {
    public static func save(key: String, value: String) throws
    public static func load(key: String) -> String?
    public static func delete(key: String)
}
```

- [ ] **Step 1: 写测试**——Mock 断言:①POST `{baseURL}/chat/completions`,`Authorization: Bearer <key>`,body.messages[0] 为翻译 system prompt(含"翻译为中文/英文"按 direction)、messages[1].content 为原文;②响应 `choices[0].message.content` 取出;③401 抛 `engineInvalidKey`;④429 抛 `engineRateLimited`。KeychainStore:save→load round-trip、delete 后 load 为 nil(key 用 "test.pdflab.\(UUID())" 避免污染)。
- [ ] **Step 2: 确认失败**
- [ ] **Step 3: 实现**——system prompt 固定为:`You are a professional translator. Translate the user's text to {Chinese|English}. Output ONLY the translation, no explanations.`;多段落合并策略:每个段落独立一次请求(保证顺序对应,v1 不做合批)。Keychain 用 `SecItemAdd/SecItemCopyMatching/SecItemDelete`,service 固定 `"com.pdflab.app"`。
- [ ] **Step 4: `make test` 全绿**
- [ ] **Step 5: Commit** `feat: OpenAI-compatible LLM engine and Keychain store`

---

### Task 12: Apple 本地翻译引擎(双路径)

**Files:**
- Create: `Sources/PDFLabCore/AppleLocalEngine.swift`
- Create: `Sources/PDFLabApp/AppleTranslationHost.swift`
- Test: `Tests/PDFLabCoreTests/AppleLocalEngineTests.swift`(仅测调度逻辑,真实翻译手动验证)

**Interfaces:**
- Produces:

```swift
/// macOS15 路径:App 层用 .translationTask 拿到 session 后履行请求;Core 只依赖此协议。
public protocol AppleSessionRunner: Sendable {
    func run(texts: [String], direction: TranslationDirection) async throws -> [String]
}
public struct AppleLocalEngine: TranslationEngine {
    /// runner 仅在 macOS 15-25 使用;macOS 26+ 内部直接 TranslationSession(installedSource:target:)。
    public init(legacyRunner: AppleSessionRunner?)
    // id="apple", isUnofficial=false, perRequestCharLimit=6000
}
```
- App 层 `AppleTranslationHost`:0×0 隐藏 SwiftUI 视图,持有 `@Published var pendingConfig: TranslationSession.Configuration?`,`.translationTask(pendingConfig) { session in ... }` 内执行 `session.translate(batch:)` 并回填 continuation;实现 `AppleSessionRunner`,注册为单例 `AppleTranslationHost.shared`,由主窗口常驻挂载。首次调用若语言包未下载,捕获错误转 `PDFLabError.languagePackMissing`(UI 引导 `session.prepareTranslation()`)。

- [ ] **Step 1: 写测试**——`FakeRunner`(回显 `"[zh]" + text`)注入 `AppleLocalEngine(legacyRunner:)`,在 macOS 15 上断言 translate 走 runner、输出顺序与输入一致、runner 为 nil 且系统 <26 时抛 `engineUnavailable("apple")`。
- [ ] **Step 2: 确认失败**
- [ ] **Step 3: 实现**——26 分支:`let session = TranslationSession(installedSource: src, target: tgt)`,`session.translate(batch: requests)` 流式收集按 clientIdentifier 排序回填;15 分支:委托 legacyRunner。方向映射:enToZh → source en / target zh-Hans。
- [ ] **Step 4: `make test` 全绿;再 `make run` 手动冒烟:主窗口挂 Host 后调 apple 引擎翻译 "Hello",确认返回中文(首次会触发语言包下载引导)**
- [ ] **Step 5: Commit** `feat: Apple local translation with macOS 26/15 dual path`

---

### Task 13: 文档组装器 DocumentComposer

**Files:**
- Create: `Sources/PDFLabCore/DocumentComposer.swift`
- Test: `Tests/PDFLabCoreTests/DocumentComposerTests.swift`

**Interfaces:**
- Consumes: `ParsedDocument`, `ExportOptions`, `ComposedDocument`
- Produces:

```swift
public enum DocumentComposer {
    /// translations 与 doc.paragraphs 一一对应;extractionOnly 时 translations 传 []。
    public static func compose(doc: ParsedDocument, translations: [String],
                               options: ExportOptions, direction: TranslationDirection?) -> ComposedDocument
}
```
组装规则(需求 3.6):`continuous` 不产生 pageBreak;`pageAligned` 在段落归属页变化处插入 `.pageBreak(pageIndex:)`(首页也插,方便导出器统一处理)。`translationOnly` 只出 translatedText;`bilingual` 每段先 sourceText 后 translatedText;`extractionOnly` 只出 sourceText。

- [ ] **Step 1: 写测试**——3 段(页 0,0,1)输入,枚举断言:①bilingual+pageAligned 输出 `[pageBreak(0), src, tr, src, tr, pageBreak(1), src, tr]`;②translationOnly+continuous 输出 3 个 translatedText 无 pageBreak;③extractionOnly 输出 3 个 sourceText;④translations 数量不符时 precondition 失败(用 bilingual+空 translations 验证——改为抛错不崩溃:返回仅源文)。
- [ ] **Step 2: 确认失败**
- [ ] **Step 3: 实现**(纯函数,~40 行,按规则逐段追加)
- [ ] **Step 4: `make test` 全绿**
- [ ] **Step 5: Commit** `feat: document composer for content x page-mode matrix`

---

### Task 14: Markdown 导出器

**Files:**
- Create: `Sources/PDFLabCore/MarkdownExporter.swift`
- Test: `Tests/PDFLabCoreTests/MarkdownExporterTests.swift`

**Interfaces:**
- Produces:

```swift
public protocol Exporter {
    /// 写文件;磁盘/权限失败抛 exportWriteFailed(原因)。
    func export(_ doc: ComposedDocument, to url: URL, uiLanguageChinese: Bool) throws
}
public struct MarkdownExporter: Exporter { public init() }
```
规则:`.pageBreak(n)` → `## 第 N+1 页`(界面英文时 `## Page N+1`);sourceText/translatedText → 段落 + 空行;文件 UTF-8。

- [ ] **Step 1: 写测试**——组一个 ComposedDocument 断言输出文本逐字符匹配:

```
## 第 1 页

Hello world.

你好世界。

## 第 2 页

Second.

第二。
```
另测英文界面出 `## Page 1`;写入只读目录(`/`)抛 `exportWriteFailed`。
- [ ] **Step 2: 确认失败** → **Step 3: 实现**(字符串拼接 + `write(to:atomically:encoding:)` 包 try/catch)→ **Step 4: 全绿** → **Step 5: Commit** `feat: markdown exporter`

---

### Task 15: PDF 导出器

**Files:**
- Create: `Sources/PDFLabCore/PDFExporter.swift`
- Test: `Tests/PDFLabCoreTests/PDFExporterTests.swift`

**Interfaces:**
- Produces: `public struct PDFExporter: Exporter`。A4(595×842pt),边距 54pt,正文 12pt 系统字体,译文与原文同样式;`CTFramesetter` 逐块排版,列满换页;`.pageBreak` 强制开新页(块级分页 = 需求"按页对应",译文超长自然溢出到下页)。

- [ ] **Step 1: 写测试**——导出 bilingual+pageAligned 两页文档后用 PDFKit 重新打开,断言:`pageCount >= 2`;第 1 页 `string` 含第一段原文前 10 字符;pageBreak(1) 后的内容不出现在第 1 页;超长段(重复 500 次的句子)导出不崩溃且页数 > 1。
- [ ] **Step 2: 确认失败**
- [ ] **Step 3: 实现**——`CGContext(url:mediaBox:)` PDF 上下文;维护 `cursorY`;每块转 NSAttributedString(源/译可用不同灰度区分:源 0.35 灰、译纯黑,bilingual 阅读性更好),`CTFramesetterSuggestFrameSizeWithConstraints` 量高,放不下则 `endPDFPage/beginPDFPage`;遇 `.pageBreak` 且当前页非空强制换页。
- [ ] **Step 4: `make test` 全绿** → **Step 5: Commit** `feat: PDF exporter with CoreText pagination`

---

### Task 16: DOCX 导出器

**Files:**
- Create: `Sources/PDFLabCore/DocxExporter.swift`
- Test: `Tests/PDFLabCoreTests/DocxExporterTests.swift`

**Interfaces:**
- Produces: `public struct DocxExporter: Exporter`。最小 OOXML:`[Content_Types].xml`、`_rels/.rels`、`word/document.xml`(每块一个 `<w:p>`;`.pageBreak` → `<w:p><w:r><w:br w:type="page"/></w:r></w:p>`;XML 转义 &<>"');打包用 `Process` 调 `/usr/bin/zip -X -r`(先写临时目录再压缩,失败抛 `exportWriteFailed`)。

- [ ] **Step 1: 写测试**——导出后:①`unzip -l` 列表含三个成员文件;②解压 document.xml 含 `<w:t>Hello &amp; world</w:t>`(验证转义)与 `w:type="page"`;③文件头两字节为 "PK"。
- [ ] **Step 2: 确认失败** → **Step 3: 实现**(document.xml 模板字符串 + 块循环)→ **Step 4: 全绿** → **Step 5: Commit** `feat: minimal OOXML docx exporter`

---

### Task 17: 翻译管线编排

**Files:**
- Create: `Sources/PDFLabCore/TranslationPipeline.swift`
- Test: `Tests/PDFLabCoreTests/TranslationPipelineTests.swift`

**Interfaces:**
- Consumes: 任务 3/5/6/7/8/13 全部 + `TranslationEngine`
- Produces:

```swift
public struct PipelineInput: Sendable {
    public var url: URL
    public var password: String?
    public var options: ExportOptions
    public var forcedDirection: TranslationDirection?   // 语言检测失败时用户强制指定
    public init(url: URL, password: String?, options: ExportOptions, forcedDirection: TranslationDirection? = nil)
}
public struct SoftLimitCheck: Sendable { public var exceeds: Bool; public var pageCount: Int; public var fileSizeMB: Int }

public final class TranslationPipeline: @unchecked Sendable {
    public init(engine: TranslationEngine, ocr: (Bool) -> OCRService = OCRService.init)
    /// 开始前独立调用,UI 据此弹软上限警告(>300 页或 >100MB)。
    public static func softLimitCheck(url: URL, password: String?) throws -> SoftLimitCheck
    /// 全流程:解析→OCR→段落重建→语言检测→翻译→组装。progress 回调在任意线程。
    /// Task 取消时抛 PDFLabError.cancelled。检测非中英且未强制指定时抛 unsupportedLanguage。
    public func run(_ input: PipelineInput,
                    progress: @escaping @Sendable (PipelineProgress) -> Void) async throws -> (ComposedDocument, ParsedDocument)
}
```

- [ ] **Step 1: 写测试**——用 Task 5 的 makePDF 生成 2 页文本 PDF + `EchoEngine`(回显 "译:"+text):①run 后 ComposedDocument 含 "译:" 块;②progress 依次出现 parsing→translating→composing 且 currentPage 单调不减;③包 Task 里跑并立刻 `task.cancel()`,抛 `cancelled`;④日文 PDF(makePDF 写日文)不带 forcedDirection 抛 `unsupportedLanguage`,带 `.enToZh` 则正常;⑤`softLimitCheck` 对 2 页小文件 `exceeds == false`。
- [ ] **Step 2: 确认失败**
- [ ] **Step 3: 实现**——逐页循环:`extractPage` → 扫描页则 `PageRasterizer.rasterize` + `ocr.recognizePage`(低置信度页计入 lowQualityPages),每页 `try Task.checkCancellation()` 并回调 progress;全部行 → `buildParagraphs` → `mergeAcrossPages`;取全文样本 `detectDirection`,nil 且无 forced 则抛;`extractionOnly` 跳过翻译;否则按段落数组调 `engine.translate`(每 10 段一批,批间回调 translating 进度);最后 `DocumentComposer.compose`。
- [ ] **Step 4: `make test` 全绿** → **Step 5: Commit** `feat: end-to-end translation pipeline with progress and cancel`

---

### Task 18: 历史记录存储

**Files:**
- Create: `Sources/PDFLabCore/HistoryStore.swift`
- Test: `Tests/PDFLabCoreTests/HistoryStoreTests.swift`

**Interfaces:**
- Produces:

```swift
public struct HistoryEntry: Codable, Equatable, Sendable {
    public var path: String
    public var fileName: String
    public var openedAt: Date
}
public final class HistoryStore: @unchecked Sendable {
    public init(defaults: UserDefaults = .standard, maxEntries: Int = 20)
    public func record(url: URL)          // 去重(同 path 更新时间),超 20 条裁掉最旧
    public func entries() -> [HistoryEntry]  // 最新在前
    public func remove(path: String)
    public func clear()
}
```

- [ ] **Step 1: 写测试**——用 `UserDefaults(suiteName: "test.\(UUID())")`:record 3 个 → entries 最新在前;重复 record 同一 path 不增条数、时间更新;record 21 个 → 只留 20 且最旧被裁;remove/clear 生效。
- [ ] **Step 2: 确认失败** → **Step 3: 实现**(JSONEncoder 存 defaults key `"pdflab.history"`)→ **Step 4: 全绿** → **Step 5: Commit** `feat: history store with dedupe and 20-entry cap`

---

### Task 19: App 壳——主界面、设置、本地化

**Files:**
- Create: `Sources/PDFLabApp/L10n.swift`, `Sources/PDFLabApp/MainView.swift`, `Sources/PDFLabApp/SettingsView.swift`, `Sources/PDFLabApp/AppState.swift`
- Modify: `Sources/PDFLabApp/PDFLabApp.swift`

**Interfaces:**
- Produces:
  - `AppState: ObservableObject`——`@AppStorage` 键:`appearance`("system"/"light"/"dark")、`uiLanguage`("system"/"zh"/"en")、`engineID`("apple"/"llm"/"google"/"deepl"/"youdao")、`llmBaseURL`、`llmModel`(Key 走 KeychainStore,key 名 `"llm.apiKey"`);计算属性 `func makeEngine() -> TranslationEngine`(按 engineID 构造,apple 注入 `AppleTranslationHost.shared`)、`var uiChinese: Bool`
  - `enum L10n`——`static func t(_ key: String) -> String`,内置 `[String: (zh: String, en: String)]` 字典,按 `AppState.uiLanguage`(system 时跟 `Locale.current`)取值。**所有 UI 文案 key 集中此处**,首批 key:`main.view`、`main.translate`、`history.empty`("暂无最近打开的文件"/"No recent files")、`history.clear`、`history.missing`("文件已被移动或删除"/...)、`settings.*`、`error.*`(与 `PDFLabError` 各 case 一一对应)、`privacy.cloudNotice`("文档内容将发送至第三方翻译服务…")、`engine.unofficialBadge`("非官方接口,可能不稳定")
  - `MainView`:左右两卡片(查看/翻译)+ 历史列表(空状态文案、右键删除单条、丢失文件弹提示可移除)
  - `SettingsView`(`Settings` scene):外观 Picker(即时切 `NSApp.appearance`)、语言 Picker、引擎 Picker(免 Key 引擎行尾 badge;选 llm 展开 baseURL/model/Key 输入 + "测试连接"按钮调 `testConnection()` 显示 ✓/✗;首次选云端引擎弹 `privacy.cloudNotice` 确认)、数据管理(清空历史)

- [ ] **Step 1: 实现 L10n + AppState**(纯逻辑可测的 `L10n.t` 与 engine 工厂放 App target,不写单测,靠编译与 Step 3 人工检查)
- [ ] **Step 2: 实现 MainView / SettingsView / App scene**(`WindowGroup` + `Settings`;窗口最小 900×600;主窗口常驻挂载 `AppleTranslationHost.shared` 的隐藏视图)
- [ ] **Step 3: `make run` 人工验收**——检查:两卡片显示;历史空状态;设置四组项齐全;切亮暗即时生效;切中英文全部文案变化;选 Google 出现非官方 badge;选 LLM 展开配置且测试连接按钮可点
- [ ] **Step 4: Commit** `feat: app shell with main view, settings, l10n`

---

### Task 20: 查看模块(单文档 + 对照同步滚动)

**Files:**
- Create: `Sources/PDFLabCore/ScrollSyncMath.swift`
- Create: `Sources/PDFLabApp/ViewerView.swift`, `Sources/PDFLabApp/DualPaneController.swift`
- Test: `Tests/PDFLabCoreTests/ScrollSyncMathTests.swift`

**Interfaces:**
- Produces(Core,纯数学,TDD):

```swift
public struct ScrollSyncMath: Sendable {
    /// ratioA/ratioB ∈ [0.5, 2.0](UI 以 % 呈现,步进 10%)。
    public init(ratioA: Double, ratioB: Double)
    /// A 侧滚动进度(0...1,offset/(contentH-viewportH))→ B 侧目标进度,截断到 0...1。
    /// 公式:progressB = progressA * (ratioA / ratioB)
    public func targetProgress(fromA progressA: Double) -> Double
    public func targetProgress(fromB progressB: Double) -> Double   // 反向:* (ratioB/ratioA)
    /// 页锚点模式:两侧页数相同时,A 的当前页+页内进度 → B 相同页+相同页内进度。
    public static func pageAnchored(page: Int, inPage: Double, pageCount: Int) -> Double
}
```
- App 层:
  - `ViewerView`:单文档态(PDF 用 `PDFView`,md/txt 读文本入 `ScrollView`+`Text`;不支持格式弹 `L10n.t("viewer.unsupported")`;加密 PDF 弹密码框复用 `PDFTextExtractor.openDocument` 逻辑);工具栏"添加译文文件"按钮 → 变对照态;打开成功即 `HistoryStore.record`
  - `DualPaneController`:`HSplitView` 左右两个滚动文档;NSScrollView `boundsDidChangeNotification` 双向监听(用 `isSyncing` 标志防回环);两侧均 PDF 且页数相同走 `pageAnchored`,否则走进度比例;工具栏两个 Stepper(50%–200%,步进 10%,默认 100%)

- [ ] **Step 1: 写 ScrollSyncMath 测试**——`ratioA=1.2, ratioB=1.0` 时 fromA(0.5) == 0.6;fromB(0.6) == 0.5(往返一致);默认 1.0/1.0 恒等;fromA(0.99) 超 1 截断为 1.0;pageAnchored(page:2, inPage:0.5, pageCount:10) == 0.25。
- [ ] **Step 2: 确认失败** → **Step 3: 实现 Core 数学(10 行)+ 全绿**
- [ ] **Step 4: 实现 App 层视图与控制器**
- [ ] **Step 5: `make run` 人工验收**——打开 PDF 单文档阅读;添加 md 译文进对照;滚左右任一侧另一侧跟随;调比例 120% 后左滚一屏右滚 1.2 屏;两个页数相同的 PDF 呈页对页对齐;加密 PDF 弹密码;打开 .docx 提示不支持;历史列表出现刚打开的文件,点击可重开
- [ ] **Step 6: Commit** `feat: viewer module with synced dual-pane scrolling`

---

### Task 21: 翻译模块 UI 流程

**Files:**
- Create: `Sources/PDFLabApp/TranslateFlowView.swift`, `Sources/PDFLabApp/PreviewView.swift`

**Interfaces:**
- Consumes: `TranslationPipeline`, `ExportOptions`, `MarkdownExporter/PDFExporter/DocxExporter`, `HistoryStore`, `AppState.makeEngine()`
- Produces: 完整状态机视图 `TranslateFlowView`,状态枚举:`idle(拖拽/选择) → optionsReady(三组 Picker) → running(ProgressView + 取消按钮) → previewing → saved`。要点:
  - 选文件后立即 `softLimitCheck`,超限弹"预计耗时较长,是否继续"
  - 加密 PDF 弹密码输入(错误可重试);`unsupportedLanguage` 弹"仅支持中英文档"+ 手动选方向(中文/英文)重试
  - running 态:`Task { pipeline.run(...) }` 持引用,取消按钮 `task.cancel()`;progress 映射为 `阶段名 + 第 X/Y 页` 文案(L10n)
  - `previewing`:左右分栏列出 ComposedDocument(源块左、译块右;extractionOnly 单栏);`lowQualityPages` 非空时顶部黄条提示"第 N 页识别质量低"
  - 保存:`NSSavePanel`(allowedContentTypes 按格式),Exporter 抛 `exportWriteFailed` 时提示并允许重选位置(已生成内容保留在内存);成功后展示"立即对照查看"按钮 → 调 ViewerView 打开原 PDF + 刚保存的文件,并 `HistoryStore.record(原PDF)`
  - 所有 `PDFLabError` case 经 `L10n.t("error.\(case)")` 呈现,engine 类错误附"建议切换本地翻译或其他引擎"

- [ ] **Step 1: 实现状态机与各子视图**
- [ ] **Step 2: `make run` 人工验收**——英文 PDF 走完全程(选项:双文+MD+按页)保存并立即对照查看;取消一次确认回 idle;改错 LLM Key 跑一次确认报"Key 无效";扫描件 PDF 走 OCR 全程;日文 PDF 弹方向选择
- [ ] **Step 3: Commit** `feat: translate flow UI with preview, save, and viewer bridge`

---

### Task 22: 打包脚本与验收

**Files:**
- Create: `scripts/bundle_app.sh`, `docs/验收清单.md`

- [ ] **Step 1: 写 bundle_app.sh**——`swift build -c release` 后组 `PDFlab.app/Contents/{MacOS,Resources}`,写 Info.plist(CFBundleIdentifier `com.pdflab.app`、LSMinimumSystemVersion 15.0、NSHumanReadableCopyright),`codesign --force --deep -s -`(ad-hoc);产出 `dist/PDFlab.app`
- [ ] **Step 2: `make bundle` 并双击启动验证**
- [ ] **Step 3: 写 docs/验收清单.md**——需求文档第八节样例集展开成逐条勾选表:8 类样例文件 × (翻译导出全流程 / 查看对照 / 同步滚动比例) + 设置四项 + 全部错误分支,含"300+ 页大文件不卡 UI、内存平稳"一条
- [ ] **Step 4: 按清单人工验收,发现的问题各自开修复 commit**
- [ ] **Step 5: Commit** `chore: app bundling script and acceptance checklist`

---

## Self-Review 记录

- **Spec 覆盖检查**:需求 3.1→任务18/19;3.2→任务20;3.3→任务5/21;3.4→任务3/5/6/7;3.5→任务4/9/10/11/12;3.6→任务13/14/15/16;3.7→任务17/21;3.8→任务21;3.9→任务19;第四节交互→任务19/20/21;第五节→任务17(softLimitCheck)+22(实测);第六节错误表→PDFLabError 各 case 在任务2定义、任务21呈现;第七节隐私→任务19(privacy.cloudNotice);第八节→任务22。无缺口。
- **类型一致性**:`TranslationEngine`/`Exporter`/`ComposedBlock`/`PipelineProgress` 等跨任务签名已在各任务 Interfaces 重复声明,以任务2/9/14 首次定义为准。
- **已知风险前置**:DeepLX/有道端点细节以任务10 Step 4 的 probe 实测为准,失效不阻塞主线(引擎可插拔,Google/本地兜底)。
