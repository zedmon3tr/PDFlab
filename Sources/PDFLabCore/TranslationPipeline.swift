import CoreGraphics
import PDFKit

/// 管线输入。forcedDirection:语言检测失败时用户强制指定的翻译方向。
public struct PipelineInput: Sendable {
    public var url: URL
    public var password: String?
    public var options: ExportOptions
    public var forcedDirection: TranslationDirection?
    public init(url: URL, password: String?, options: ExportOptions, forcedDirection: TranslationDirection? = nil) {
        self.url = url
        self.password = password
        self.options = options
        self.forcedDirection = forcedDirection
    }
}

/// 软上限预检结果(>300 页或 >100MB 时 exceeds == true,UI 据此弹警告)。
public struct SoftLimitCheck: Sendable {
    public var exceeds: Bool
    public var pageCount: Int
    public var fileSizeMB: Int
    public init(exceeds: Bool, pageCount: Int, fileSizeMB: Int) {
        self.exceeds = exceeds
        self.pageCount = pageCount
        self.fileSizeMB = fileSizeMB
    }
}

/// 全流程编排:解析 → OCR → 段落重建 → 语言检测 → 翻译 → 组装。
public final class TranslationPipeline: @unchecked Sendable {
    private static let translationBatchSize = 10
    /// 与 OCRService 的重试阈值一致:整页均值 < 0.5 视为低质量页。
    private static let lowConfidenceThreshold = 0.5
    private static let softPageLimit = 300
    private static let softSizeLimitMB = 100

    private let engine: TranslationEngine
    private let makeOCR: (Bool) -> OCRService

    public init(engine: TranslationEngine, ocr: @escaping (Bool) -> OCRService = OCRService.init) {
        self.engine = engine
        self.makeOCR = ocr
    }

    /// 开始前独立调用,UI 据此弹软上限警告。
    public static func softLimitCheck(url: URL, password: String?) throws -> SoftLimitCheck {
        let doc = try PDFTextExtractor.openDocument(at: url, password: password)
        let bytes = (try? FileManager.default.attributesOfItem(atPath: url.path)[.size] as? NSNumber)?.intValue ?? 0
        let sizeMB = bytes / (1024 * 1024)
        return SoftLimitCheck(
            exceeds: doc.pageCount > softPageLimit || sizeMB > softSizeLimitMB,
            pageCount: doc.pageCount,
            fileSizeMB: sizeMB
        )
    }

    /// progress 回调可能在任意线程。Task 取消时抛 PDFLabError.cancelled。
    /// 检测为非中英语言且未强制指定方向时抛 unsupportedLanguage。
    public func run(
        _ input: PipelineInput,
        progress: @escaping @Sendable (PipelineProgress) -> Void
    ) async throws -> (ComposedDocument, ParsedDocument) {
        do {
            return try await runStages(input, progress: progress)
        } catch is CancellationError {
            throw PDFLabError.cancelled
        }
    }

    private func runStages(
        _ input: PipelineInput,
        progress: @escaping @Sendable (PipelineProgress) -> Void
    ) async throws -> (ComposedDocument, ParsedDocument) {
        try Task.checkCancellation()
        let doc = try PDFTextExtractor.openDocument(at: input.url, password: input.password)
        let totalPages = doc.pageCount
        // OCR 语言优先级只能在方向未知前决定:强制中→英时中文优先,其余英文优先。
        let ocr = makeOCR(input.forcedDirection == .zhToEn)

        // 阶段 1/2:逐页解析,扫描页转 OCR。
        var allLines: [TextLine] = []
        var lowQualityPages: [Int] = []
        for pageIndex in 0..<totalPages {
            try Task.checkCancellation()
            progress(PipelineProgress(stage: .parsing, currentPage: pageIndex + 1, totalPages: totalPages))
            let extraction = PDFTextExtractor.extractPage(doc, pageIndex: pageIndex)
            if extraction.isScanned {
                progress(PipelineProgress(stage: .ocr, currentPage: pageIndex + 1, totalPages: totalPages))
                guard let page = doc.page(at: pageIndex),
                      let image = PageRasterizer.rasterize(page: page) else { continue }
                let recognized = try await ocr.recognizePage(image, pageIndex: pageIndex)
                if recognized.confidence < Self.lowConfidenceThreshold {
                    lowQualityPages.append(pageIndex)
                }
                allLines.append(contentsOf: recognized.lines)
            } else {
                allLines.append(contentsOf: extraction.lines)
            }
        }

        // 阶段 3:段落重建 + 跨页合并。
        let paragraphs = ParagraphBuilder.mergeAcrossPages(ParagraphBuilder.buildParagraphs(from: allLines))
        guard !paragraphs.isEmpty else { throw PDFLabError.noTextRecognized }
        let parsed = ParsedDocument(paragraphs: paragraphs, pageCount: totalPages, lowQualityPages: lowQualityPages)

        if input.options.content == .extractionOnly {
            try Task.checkCancellation()
            progress(PipelineProgress(stage: .composing, currentPage: totalPages, totalPages: totalPages))
            let composed = DocumentComposer.compose(
                doc: parsed,
                translations: [],
                options: input.options,
                direction: nil
            )
            return (composed, parsed)
        }

        // 阶段 4:语言检测(LanguageDetector 内部取样本前 4000 字符)。
        let sample = paragraphs.map(\.text).joined(separator: "\n")
        let direction: TranslationDirection
        if let forced = input.forcedDirection {
            direction = forced
        } else if let detected = LanguageDetector.detectDirection(sample: sample) {
            direction = detected
        } else {
            throw PDFLabError.unsupportedLanguage(detected: LanguageDetector.detectedLanguageName(sample: sample))
        }

        // 阶段 5:分批翻译(每批 10 段)。extractionOnly 跳过。
        var translations: [String] = []
        if input.options.content != .extractionOnly {
            var index = 0
            while index < paragraphs.count {
                try Task.checkCancellation()
                let batch = Array(paragraphs[index..<min(index + Self.translationBatchSize, paragraphs.count)])
                translations += try await engine.translate(batch.map(\.text), direction: direction)
                progress(PipelineProgress(
                    stage: .translating,
                    currentPage: (batch.last?.pageIndex ?? 0) + 1,
                    totalPages: totalPages
                ))
                index += Self.translationBatchSize
            }
        }

        // 阶段 6:组装。
        try Task.checkCancellation()
        progress(PipelineProgress(stage: .composing, currentPage: totalPages, totalPages: totalPages))
        let composed = DocumentComposer.compose(
            doc: parsed,
            translations: translations,
            options: input.options,
            direction: direction
        )
        return (composed, parsed)
    }
}
