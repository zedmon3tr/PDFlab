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
public enum SourceParagraphKind: Equatable, Sendable {
    case body
    case heading(level: Int)
    case listItem(marker: String)
    case footnote
}

public struct SourceParagraph: Equatable, Sendable {
    public var text: String
    public var pageIndex: Int
    public var ocrConfidence: Double?   // nil = 来自文本层非 OCR
    public var kind: SourceParagraphKind
    public var listMarker: String? {
        guard case let .listItem(marker) = kind, !marker.isEmpty else { return nil }
        return marker
    }
    public var translationUnitID: TranslationUnitID?
    public var sourceBlockIDs: [LayoutBlockID]
    public var firstLineBBox: CGRect?
    public var lastLineBBox: CGRect?
    public var regionBodyRightEdge: CGFloat?
    public var lastLineIsShort: Bool
    public init(
        text: String,
        pageIndex: Int,
        ocrConfidence: Double? = nil,
        kind: SourceParagraphKind? = nil,
        listMarker: String? = nil,
        translationUnitID: TranslationUnitID? = nil,
        sourceBlockIDs: [LayoutBlockID] = [],
        firstLineBBox: CGRect? = nil,
        lastLineBBox: CGRect? = nil,
        regionBodyRightEdge: CGFloat? = nil,
        lastLineIsShort: Bool = false
    ) {
        self.text = text
        self.pageIndex = pageIndex
        self.ocrConfidence = ocrConfidence
        self.kind = kind ?? listMarker.map(SourceParagraphKind.listItem(marker:)) ?? .body
        self.sourceBlockIDs = sourceBlockIDs
        self.firstLineBBox = firstLineBBox
        self.lastLineBBox = lastLineBBox
        self.regionBodyRightEdge = regionBodyRightEdge
        self.lastLineIsShort = lastLineIsShort
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

public enum ComposedTextKind: Equatable, Sendable {
    case body
    case heading(level: Int)
    case listItem(marker: String)
    case footnote
}

public struct ComposedTextBlock: Equatable, Sendable {
    public var text: String
    public var groupID: TranslationUnitID?
    public var kind: ComposedTextKind

    public init(text: String, groupID: TranslationUnitID? = nil, kind: ComposedTextKind = .body) {
        self.text = text
        self.groupID = groupID
        self.kind = kind
    }
}

public struct ComposedTableRegion: Equatable, Sendable {
    public var groupID: TranslationUnitID
    public var pageIndex: Int
    public var sourceRows: [String]
    public var translatedRows: [String]
    public var content: OutputContent

    public init(
        groupID: TranslationUnitID,
        pageIndex: Int,
        sourceRows: [String],
        translatedRows: [String],
        content: OutputContent
    ) {
        self.groupID = groupID
        self.pageIndex = pageIndex
        self.sourceRows = sourceRows
        self.translatedRows = translatedRows
        self.content = content
    }

    public var displayedRows: [String] {
        switch content {
        case .translationOnly: return translatedRows
        case .bilingual: return sourceRows + (translatedRows.isEmpty ? [] : [""]) + translatedRows
        case .extractionOnly: return sourceRows
        }
    }
}

/// 组装后待渲染的块(任务13产出,任务14-16消费)。
public enum ComposedBlock: Equatable, Sendable {
    case pageBreak(pageIndex: Int)        // 按页模式的页边界(pageIndex 为新页,0 计)
    case sourceText(ComposedTextBlock)
    case translatedText(ComposedTextBlock)
    case tableRegion(ComposedTableRegion)

    public static func sourceText(_ text: String) -> ComposedBlock {
        .sourceText(ComposedTextBlock(text: text))
    }

    public static func translatedText(_ text: String) -> ComposedBlock {
        .translatedText(ComposedTextBlock(text: text))
    }
}
public struct ComposedDocument: Equatable, Sendable {
    public var blocks: [ComposedBlock]
    public var direction: TranslationDirection?
    public init(blocks: [ComposedBlock], direction: TranslationDirection?) {
        self.blocks = blocks
        self.direction = direction
    }
}

/// 按页导出时，一个逻辑原文页实际占用的连续译文 PDF 页组（均为 0 计）。
public struct PageGroup: Codable, Equatable, Sendable {
    public let sourcePageIndex: Int
    public let outputStartPageIndex: Int
    public let outputPageCount: Int

    public init(sourcePageIndex: Int, outputStartPageIndex: Int, outputPageCount: Int) {
        self.sourcePageIndex = sourcePageIndex
        self.outputStartPageIndex = outputStartPageIndex
        self.outputPageCount = outputPageCount
    }

    public var outputPageRange: ClosedRange<Int> {
        outputStartPageIndex...(outputStartPageIndex + max(outputPageCount, 1) - 1)
    }
}

/// 译文 PDF 内嵌的原文页 → 译文物理页映射。
/// 构造器只接受从第 0 页开始、无缺口且完整覆盖两份文档的映射，损坏元数据不会进入查看器。
public struct PageGroupMap: Codable, Equatable, Sendable {
    public static let currentVersion = 1

    public let version: Int
    public let sourcePageCount: Int
    public let outputPageCount: Int
    public let sourceFingerprint: String
    public let groups: [PageGroup]

    public init?(
        version: Int = PageGroupMap.currentVersion,
        sourcePageCount: Int,
        outputPageCount: Int,
        sourceFingerprint: String,
        groups: [PageGroup]
    ) {
        guard Self.isValid(
            version: version,
            sourcePageCount: sourcePageCount,
            outputPageCount: outputPageCount,
            sourceFingerprint: sourceFingerprint,
            groups: groups
        ) else { return nil }
        self.version = version
        self.sourcePageCount = sourcePageCount
        self.outputPageCount = outputPageCount
        self.sourceFingerprint = sourceFingerprint
        self.groups = groups
    }

    public func group(forSourcePage index: Int) -> PageGroup? {
        guard groups.indices.contains(index), groups[index].sourcePageIndex == index else { return nil }
        return groups[index]
    }

    public func group(containingOutputPage index: Int) -> PageGroup? {
        groups.first { $0.outputPageRange.contains(index) }
    }

    private static func isValid(
        version: Int,
        sourcePageCount: Int,
        outputPageCount: Int,
        sourceFingerprint: String,
        groups: [PageGroup]
    ) -> Bool {
        guard version == currentVersion,
              sourcePageCount > 0,
              outputPageCount > 0,
              groups.count == sourcePageCount,
              sourceFingerprintIsValid(sourceFingerprint)
        else { return false }

        var expectedOutputStart = 0
        for (expectedSourceIndex, group) in groups.enumerated() {
            guard group.sourcePageIndex == expectedSourceIndex,
                  group.outputStartPageIndex == expectedOutputStart,
                  group.outputPageCount > 0,
                  group.outputPageCount <= outputPageCount - expectedOutputStart
            else { return false }
            expectedOutputStart += group.outputPageCount
        }
        return expectedOutputStart == outputPageCount
    }

    private static func sourceFingerprintIsValid(_ fingerprint: String) -> Bool {
        return fingerprint.count == 64 && fingerprint.allSatisfy { $0.isHexDigit }
    }

    private enum CodingKeys: String, CodingKey {
        case version, sourcePageCount, outputPageCount, sourceFingerprint, groups
    }

    public init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        let version = try values.decode(Int.self, forKey: .version)
        let sourcePageCount = try values.decode(Int.self, forKey: .sourcePageCount)
        let outputPageCount = try values.decode(Int.self, forKey: .outputPageCount)
        let sourceFingerprint = try values.decode(String.self, forKey: .sourceFingerprint)
        let groups = try values.decode([PageGroup].self, forKey: .groups)
        guard let valid = PageGroupMap(
            version: version,
            sourcePageCount: sourcePageCount,
            outputPageCount: outputPageCount,
            sourceFingerprint: sourceFingerprint,
            groups: groups
        ) else {
            throw DecodingError.dataCorrupted(.init(
                codingPath: decoder.codingPath,
                debugDescription: "Invalid PDF page-group mapping"
            ))
        }
        self = valid
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
