// CLT 工具链缺少 _Testing_Foundation 跨导入 overlay:测试文件里同时 import Testing 和
// import Foundation 会编译失败(no such module '_Testing_Foundation')。
// 因此由 PDFLabCore 在此统一 @_exported 重导出 Foundation;
// 测试文件一律不要直接 import Foundation,经 @testable import PDFLabCore 传递获得。
@_exported import Foundation

public enum PDFLabCoreInfo { public static let version = "0.1.3" }

public struct LayoutBlockID: RawRepresentable, Hashable, Equatable, Sendable {
    public var rawValue: String
    public init(rawValue: String) { self.rawValue = rawValue }
    public init(_ rawValue: String) { self.rawValue = rawValue }
}

public struct TranslationUnitID: RawRepresentable, Hashable, Equatable, Sendable {
    public var rawValue: String
    public init(rawValue: String) { self.rawValue = rawValue }
    public init(_ rawValue: String) { self.rawValue = rawValue }
}

/// 一段源文本。pageIndex 从 0 计,是段落起始页(跨页段落归起始页)。
public struct SourceParagraph: Equatable, Sendable {
    public var text: String
    public var pageIndex: Int
    public var ocrConfidence: Double?   // nil = 来自文本层非 OCR
    public var listMarker: String?
    public var translationUnitID: TranslationUnitID?
    public var sourceBlockIDs: [LayoutBlockID]
    public var firstLineBBox: CGRect?
    public var lastLineBBox: CGRect?
    public init(
        text: String,
        pageIndex: Int,
        ocrConfidence: Double? = nil,
        listMarker: String? = nil,
        translationUnitID: TranslationUnitID? = nil,
        sourceBlockIDs: [LayoutBlockID] = [],
        firstLineBBox: CGRect? = nil,
        lastLineBBox: CGRect? = nil
    ) {
        self.text = text
        self.pageIndex = pageIndex
        self.ocrConfidence = ocrConfidence
        self.listMarker = listMarker
        self.sourceBlockIDs = sourceBlockIDs
        self.firstLineBBox = firstLineBBox
        self.lastLineBBox = lastLineBBox
        self.translationUnitID = translationUnitID
    }

    public var displayText: String {
        textWithListMarker(text)
    }

    public func textWithListMarker(_ body: String) -> String {
        guard let listMarker, !listMarker.isEmpty else { return body }
        return "\(listMarker) \(body)"
    }

}

public struct SourceTableRow: Equatable, Sendable {
    public var translationUnitID: TranslationUnitID
    public var text: String

    public init(translationUnitID: TranslationUnitID, text: String) {
        self.translationUnitID = translationUnitID
        self.text = text
    }
}

public struct SourceTableRegion: Equatable, Sendable {
    public var translationUnitID: TranslationUnitID
    public var pageIndex: Int
    public var sourceBlockIDs: [LayoutBlockID]
    public var rows: [SourceTableRow]

    public init(translationUnitID: TranslationUnitID, pageIndex: Int, sourceBlockIDs: [LayoutBlockID], rows: [SourceTableRow]) {
        self.translationUnitID = translationUnitID
        self.pageIndex = pageIndex
        self.sourceBlockIDs = sourceBlockIDs
        self.rows = rows
    }
}

public enum ParsedBlock: Equatable, Sendable {
    case paragraph(SourceParagraph)
    case table(SourceTableRegion)
}

/// 解析完成的整篇文档。
public struct ParsedDocument: Equatable, Sendable {
    public var blocks: [ParsedBlock]
    public var paragraphs: [SourceParagraph] {
        blocks.compactMap { if case let .paragraph(paragraph) = $0 { paragraph } else { nil } }
    }
    public var pageCount: Int
    public var lowQualityPages: [Int]   // 置信度兜底标记的页
    public var cleanupSummary: TextCleanupSummary
    public init(paragraphs: [SourceParagraph], pageCount: Int, lowQualityPages: [Int] = [], cleanupSummary: TextCleanupSummary = .init()) {
        self.blocks = paragraphs.map(ParsedBlock.paragraph)
        self.pageCount = pageCount
        self.lowQualityPages = lowQualityPages
        self.cleanupSummary = cleanupSummary
    }
    public init(blocks: [ParsedBlock], pageCount: Int, lowQualityPages: [Int] = [], cleanupSummary: TextCleanupSummary = .init()) {
        self.blocks = blocks
        self.pageCount = pageCount
        self.lowQualityPages = lowQualityPages
        self.cleanupSummary = cleanupSummary
    }
}

public struct TranslatedUnit: Equatable, Sendable {
    public var id: TranslationUnitID
    public var text: String

    public init(id: TranslationUnitID, text: String) {
        self.id = id
        self.text = text
    }
}

public enum TranslationDirection: String, Sendable, CaseIterable {
    case enToZh, zhToEn
}

public enum OCRLanguage: String, Sendable, CaseIterable {
    case automatic
    case english
    case simplifiedChinese
    case traditionalChinese
    case japanese
    case korean
}

public enum TranslationTargetLanguage: String, Sendable, CaseIterable {
    case simplifiedChinese
    case english

    public var legacyDirection: TranslationDirection {
        switch self {
        case .simplifiedChinese:
            return .enToZh
        case .english:
            return .zhToEn
        }
    }
}

public enum OutputContent: String, Sendable, CaseIterable { case translationOnly, bilingual, extractionOnly }
public enum OutputFormat: String, Sendable, CaseIterable { case pdf, docx, markdown }
public enum PageMode: String, Sendable, CaseIterable { case continuous, pageAligned }

/// 用户输入的 1 计页码闭区间。空白输入代表处理整份文档。
public enum TranslationPageRange {
    public static func parse(_ value: String, totalPages: Int) throws -> ClosedRange<Int>? {
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }

        let parts = trimmed.split(separator: "-", omittingEmptySubsequences: false)
        guard parts.count == 2,
              let lower = Int(parts[0].trimmingCharacters(in: .whitespaces)),
              let upper = Int(parts[1].trimmingCharacters(in: .whitespaces)),
              lower >= 1,
              lower <= upper,
              upper <= totalPages else {
            throw PDFLabError.invalidPageRange
        }
        return lower...upper
    }
}

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
    case invalidPageRange
    case unsupportedLanguage(detected: String)
    case languagePackMissing
    case engineInvalidKey
    case engineInsufficientBalance
    case engineOutputTruncated
    case engineContentFiltered
    case engineInvalidRequest
    case keychainFailure(Int32)
    case engineRateLimited
    case engineUnavailable(engineID: String)
    case networkError(String)
    case exportWriteFailed(String)
    case cancelled
}
