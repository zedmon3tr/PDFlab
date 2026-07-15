import CoreGraphics
import PDFKit

/// 管线输入。forcedDirection:语言检测失败时用户强制指定的翻译方向。
public struct PipelineInput: Sendable {
    public var url: URL
    public var password: String?
    public var options: ExportOptions
    public var ocrLanguage: OCRLanguage
    public var targetLanguage: TranslationTargetLanguage
    public var forcedDirection: TranslationDirection?
    /// 1 计闭区间;nil 表示处理整个 PDF。
    public var pageRange: ClosedRange<Int>?
    public init(
        url: URL,
        password: String?,
        options: ExportOptions,
        ocrLanguage: OCRLanguage = .automatic,
        targetLanguage: TranslationTargetLanguage = .simplifiedChinese,
        forcedDirection: TranslationDirection? = nil,
        pageRange: ClosedRange<Int>? = nil
    ) {
        self.url = url
        self.password = password
        self.options = options
        self.ocrLanguage = ocrLanguage
        self.targetLanguage = targetLanguage
        self.forcedDirection = forcedDirection
        self.pageRange = pageRange
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
    /// Public so other call sites needing the same "low OCR confidence" cutoff (e.g. the
    /// downstream UI and export layers can reference this
    /// single source of truth instead of duplicating the magic number.
    public static let lowConfidenceThreshold = 0.5
    private static let softPageLimit = 200
    private static let softSizeLimitMB = 50

    private let engine: TranslationEngine
    private let makeOCR: (OCRLanguage) -> OCRService
#if DEBUG
    private let diagnostics: any TranslationDiagnosticSink
#endif

#if DEBUG
    public init(engine: TranslationEngine, ocr: @escaping (OCRLanguage) -> OCRService = OCRService.init(language:),
                diagnostics: any TranslationDiagnosticSink = TranslationDiagnostics.shared) {
        self.engine = engine
        self.makeOCR = ocr
        self.diagnostics = diagnostics
    }
#else
    public init(engine: TranslationEngine, ocr: @escaping (OCRLanguage) -> OCRService = OCRService.init(language:)) {
        self.engine = engine
        self.makeOCR = ocr
    }
#endif

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

    /// OCR 语言优先级判定结果。probedPage:全扫描件为判定语言先行识别的首个扫描页
    /// 结果(仅当其识别所用优先级即最终优先级时保留,供主循环复用)。
    private struct OCRPriority {
        var language: OCRLanguage
        var probedPage: OCRPageResult?
    }

    /// 决定 OCR 语言优先级(需求 3.4:中文为主时 zh-Hans 排首位)。判定顺序:
    /// 1. 用户强制方向(覆盖一切嗅探);
    /// 2. 任一文本层页面能判定方向,按其结果;
    /// 3. 全扫描(或文本层无法判定):用默认英文优先识别首个扫描页,按识别文本嗅探;
    ///    若为中文则返回中文优先(该页由主循环用中文优先服务重新识别)。
    private func resolveOCRPriority(
        doc: PDFDocument,
        pageIndices: [Int],
        forcedDirection: TranslationDirection?,
        requestedLanguage: OCRLanguage
    ) async throws -> OCRPriority {
        if requestedLanguage != .automatic {
            return OCRPriority(language: requestedLanguage, probedPage: nil)
        }

        if let forced = forcedDirection {
            return OCRPriority(language: forced == .zhToEn ? .simplifiedChinese : .english, probedPage: nil)
        }

        // 文本层嗅探:只读 page.string(与 extractPage 相同的 >=20 字符扫描页判据),
        // 不做逐行定位,代价可忽略。
        var firstScannedIndex: Int?
        for pageIndex in pageIndices {
            try Task.checkCancellation()
            guard let text = doc.page(at: pageIndex)?.string,
                  text.trimmingCharacters(in: .whitespacesAndNewlines).count >= 20 else {
                if firstScannedIndex == nil { firstScannedIndex = pageIndex }
                continue
            }
            if let language = LanguageDetector.detectOCRLanguage(sample: text) {
                return OCRPriority(language: language, probedPage: nil)
            }
        }

        // 无可判定文本层:识别首个扫描页判语言;无扫描页则优先级无关紧要,取默认。
        guard let probeIndex = firstScannedIndex,
              let page = doc.page(at: probeIndex),
              let image = PageRasterizer.rasterize(page: page) else {
            return OCRPriority(language: .automatic, probedPage: nil)
        }
        let probe = try await makeOCR(.automatic).recognizePage(image, pageIndex: probeIndex)
        let sample = probe.lines.map(\.text).joined(separator: "\n")
        if let language = LanguageDetector.detectOCRLanguage(sample: sample), language != .automatic {
            return OCRPriority(language: language, probedPage: nil)
        }
        return OCRPriority(
            language: .automatic,
            probedPage: probe
        )
    }

    public static func detectOCRLanguage(
        url: URL,
        password: String?,
        pageRange: ClosedRange<Int>? = nil
    ) async throws -> OCRLanguage? {
        let doc = try PDFTextExtractor.openDocument(at: url, password: password)
        let pageIndices = try selectedPageIndices(totalPages: doc.pageCount, pageRange: pageRange)
        var firstScannedIndex: Int?

        for pageIndex in pageIndices {
            try Task.checkCancellation()
            guard let text = doc.page(at: pageIndex)?.string,
                  text.trimmingCharacters(in: .whitespacesAndNewlines).count >= 20 else {
                if firstScannedIndex == nil { firstScannedIndex = pageIndex }
                continue
            }
            if let language = LanguageDetector.detectOCRLanguage(sample: text) {
                return language
            }
        }

        guard let probeIndex = firstScannedIndex,
              let page = doc.page(at: probeIndex),
              let image = PageRasterizer.rasterize(page: page) else {
            return nil
        }
        let probe = try await OCRService(language: .automatic).recognizePage(image, pageIndex: probeIndex)
        let sample = probe.lines.map(\.text).joined(separator: "\n")
        return LanguageDetector.detectOCRLanguage(sample: sample)
    }

    private func runStages(
        _ input: PipelineInput,
        progress: @escaping @Sendable (PipelineProgress) -> Void
    ) async throws -> (ComposedDocument, ParsedDocument) {
        try Task.checkCancellation()
        let doc = try PDFTextExtractor.openDocument(at: input.url, password: input.password)
        let totalPages = doc.pageCount
        let pageIndices = try Self.selectedPageIndices(totalPages: totalPages, pageRange: input.pageRange)
        let processingPageCount = pageIndices.count
        // 需求 3.4:中文为主的文档,OCR 语言优先级 zh-Hans 必须排首位。
        // 先廉价预判语言(强制方向 > 文本层嗅探 > 首个扫描页试识别)再创建 OCR 服务。
        let priority = try await resolveOCRPriority(
            doc: doc,
            pageIndices: pageIndices,
            forcedDirection: input.forcedDirection,
            requestedLanguage: input.ocrLanguage
        )
        let ocr = makeOCR(priority.language)

        // 阶段 1/2:逐页解析,扫描页转 OCR。
        var pageLayouts: [PageLayout] = []
        var lowQualityPages: [Int] = []
        for (processedIndex, pageIndex) in pageIndices.enumerated() {
            try Task.checkCancellation()
            progress(PipelineProgress(stage: .parsing, currentPage: processedIndex + 1, totalPages: processingPageCount))
            let extraction = PDFTextExtractor.extractPage(doc, pageIndex: pageIndex)
            if extraction.isScanned {
                progress(PipelineProgress(stage: .ocr, currentPage: processedIndex + 1, totalPages: processingPageCount))
                let recognized: OCRPageResult
                if let probe = priority.probedPage, probe.layout.pageIndex == pageIndex {
                    // 优先级判定阶段已用最终优先级识别过该页,直接复用,避免重复 OCR。
                    recognized = probe
                } else {
                    guard let page = doc.page(at: pageIndex),
                          let image = PageRasterizer.rasterize(page: page) else {
                        // 光栅化失败:该页无法 OCR,标记为低质量页而非静默丢弃。
                        lowQualityPages.append(pageIndex)
                        continue
                    }
                    recognized = try await ocr.recognizePage(image, pageIndex: pageIndex)
                }
                if recognized.confidence < Self.lowConfidenceThreshold {
                    lowQualityPages.append(pageIndex)
                }
                pageLayouts.append(recognized.layout)
            } else {
                pageLayouts.append(extraction.layout)
            }
        }

        // 阶段 3:按页几何重排并清理确定的非正文行，再聚段、跨页合并。
        let cleaned = TextLineCleaner.clean(pageLayouts)
        let blocks = ParsedBlockBuilder.build(from: cleaned.layouts)
        guard !blocks.isEmpty else { throw PDFLabError.noTextRecognized }
        let parsed = ParsedDocument(
            blocks: blocks,
            pageCount: totalPages,
            lowQualityPages: lowQualityPages,
            cleanupSummary: cleaned.summary
        )

        if input.options.content == .extractionOnly {
            try Task.checkCancellation()
            progress(PipelineProgress(stage: .composing, currentPage: processingPageCount, totalPages: processingPageCount))
            let composed = DocumentComposer.compose(
                doc: parsed,
                translations: [],
                options: input.options,
                direction: nil
            )
            return (composed, parsed)
        }

        // 阶段 4:确定翻译目标。源语言检测只作为 OCR 提示,不再作为前置阻断。
        let direction: TranslationDirection
        if let forced = input.forcedDirection {
            direction = forced
        } else {
            direction = input.targetLanguage.legacyDirection
        }

        // 阶段 5:分批翻译(每批 10 段)。extractionOnly 跳过。
        let translationInputs = Self.translationInputs(from: parsed)
        var translatedUnits: [TranslatedUnit] = []
        if input.options.content != .extractionOnly {
#if DEBUG
            let runID = UUID()
#endif
            var index = 0
            while index < translationInputs.count {
                try Task.checkCancellation()
                let batch = Array(translationInputs[index..<min(index + Self.translationBatchSize, translationInputs.count)])
                let texts = batch.map(\.text)
                let batchNumber = index / Self.translationBatchSize + 1
                let pageStart = (batch.first?.pageIndex ?? 0) + 1
                let pageEnd = (batch.last?.pageIndex ?? 0) + 1
#if DEBUG
                let started = Date()
                let context = TranslationDiagnosticContext(runID: runID, batch: batchNumber, pageStart: pageStart, pageEnd: pageEnd)
                do {
                    let translated = try await TranslationDiagnosticScope.$current.withValue(context) {
                        try await engine.translate(texts, direction: direction)
                    }
                    translatedUnits += zip(batch, translated).map { TranslatedUnit(id: $0.0.id, text: $0.1) }
                    await diagnostics.record(.init(runID: runID, engine: engine.id, stage: "batch-complete",
                        direction: direction, batch: batchNumber, pageStart: pageStart, pageEnd: pageEnd,
                        characterCount: texts.reduce(0) { $0 + $1.count },
                        durationMilliseconds: Int(Date().timeIntervalSince(started) * 1000)))
                } catch {
                    await diagnostics.record(.init(runID: runID, engine: engine.id, stage: "batch-failed",
                        direction: direction, batch: batchNumber, pageStart: pageStart, pageEnd: pageEnd,
                        characterCount: texts.reduce(0) { $0 + $1.count },
                        durationMilliseconds: Int(Date().timeIntervalSince(started) * 1000),
                        errorCategory: Self.diagnosticCategory(error)))
                    throw error
                }
#else
                let translated = try await engine.translate(texts, direction: direction)
                translatedUnits += zip(batch, translated).map { TranslatedUnit(id: $0.0.id, text: $0.1) }
#endif
                progress(PipelineProgress(
                    stage: .translating,
                    currentPage: min(pageIndices.lastIndex(where: { $0 < pageEnd })?.advanced(by: 1) ?? processingPageCount, processingPageCount),
                    totalPages: processingPageCount
                ))
                index += Self.translationBatchSize
            }
        }

        // 阶段 6:组装。
        try Task.checkCancellation()
        progress(PipelineProgress(stage: .composing, currentPage: processingPageCount, totalPages: processingPageCount))
        let composed = DocumentComposer.compose(
            doc: parsed,
            translatedUnits: translatedUnits,
            options: input.options,
            direction: direction
        )
        return (composed, parsed)
    }

    private struct TranslationInputUnit {
        var id: TranslationUnitID
        var text: String
        var pageIndex: Int
    }

    private static func translationInputs(from doc: ParsedDocument) -> [TranslationInputUnit] {
        var paragraphIndex = 0
        return doc.blocks.flatMap { block -> [TranslationInputUnit] in
            switch block {
            case .paragraph(let paragraph):
                defer { paragraphIndex += 1 }
                return [TranslationInputUnit(
                    id: paragraph.translationUnitID ?? .init("compat-paragraph:\(paragraphIndex)"),
                    text: paragraph.text,
                    pageIndex: paragraph.pageIndex
                )]
            case .table(let table):
                return table.rows.map { .init(id: $0.translationUnitID, text: $0.text, pageIndex: table.pageIndex) }
            }
        }
    }

    static func selectedPageIndices(
        totalPages: Int,
        pageRange: ClosedRange<Int>?
    ) throws -> [Int] {
        guard totalPages > 0 else {
            throw PDFLabError.invalidPageRange
        }
        let range = pageRange ?? 1...totalPages
        guard
              range.lowerBound >= 1,
              range.upperBound <= totalPages else {
            throw PDFLabError.invalidPageRange
        }
        return range.map { $0 - 1 }
    }

#if DEBUG
    private static func diagnosticCategory(_ error: Error) -> String {
        if error is CancellationError { return "cancelled" }
        guard let error = error as? PDFLabError else { return "unexpected" }
        switch error {
        case .engineRateLimited: return "rate-limited"
        case .networkError: return "network"
        case .cancelled: return "cancelled"
        case .engineInvalidKey: return "invalid-key"
        default: return "engine-or-data"
        }
    }
#endif
}
