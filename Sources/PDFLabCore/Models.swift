// CLT 工具链缺少 _Testing_Foundation 跨导入 overlay:测试文件里同时 import Testing 和
// import Foundation 会编译失败(no such module '_Testing_Foundation')。
// 因此由 PDFLabCore 在此统一 @_exported 重导出 Foundation;
// 测试文件一律不要直接 import Foundation,经 @testable import PDFLabCore 传递获得。
@_exported import Foundation

public enum PDFLabCoreInfo { public static let version = "0.1.0" }

/// 一段源文本。pageIndex 从 0 计,是段落起始页(跨页段落归起始页)。
public struct SourceParagraph: Equatable, Sendable {
    public var text: String
    public var pageIndex: Int
    public var ocrConfidence: Double?   // nil = 来自文本层非 OCR
    public init(text: String, pageIndex: Int, ocrConfidence: Double? = nil) {
        self.text = text
        self.pageIndex = pageIndex
        self.ocrConfidence = ocrConfidence
    }
}

/// 解析完成的整篇文档。
public struct ParsedDocument: Equatable, Sendable {
    public var paragraphs: [SourceParagraph]
    public var pageCount: Int
    public var lowQualityPages: [Int]   // 置信度兜底标记的页
    public init(paragraphs: [SourceParagraph], pageCount: Int, lowQualityPages: [Int] = []) {
        self.paragraphs = paragraphs
        self.pageCount = pageCount
        self.lowQualityPages = lowQualityPages
    }
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
    public init(content: OutputContent, format: OutputFormat, pageMode: PageMode) {
        self.content = content
        self.format = format
        self.pageMode = pageMode
    }
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
    public init(blocks: [ComposedBlock], direction: TranslationDirection?) {
        self.blocks = blocks
        self.direction = direction
    }
}

/// 管线进度(任务17产出,UI 消费)。
public enum PipelineStage: String, Sendable { case parsing, ocr, translating, composing }
public struct PipelineProgress: Equatable, Sendable {
    public var stage: PipelineStage
    public var currentPage: Int   // 1 计,用于显示
    public var totalPages: Int
    public init(stage: PipelineStage, currentPage: Int, totalPages: Int) {
        self.stage = stage
        self.currentPage = currentPage
        self.totalPages = totalPages
    }
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
