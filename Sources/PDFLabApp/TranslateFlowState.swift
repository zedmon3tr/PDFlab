import PDFLabCore

struct TranslateFlowState: Equatable {
    enum Phase: Equatable {
        case idle
        case optionsReady
        case running
        case previewing
        case saved
    }

    var phase: Phase = .idle
    var sourceURL: URL?
    var password: String?
    var options = ExportOptions(content: .translationOnly, format: .pdf, pageMode: .pageAligned)
    var ocrLanguage: OCRLanguage = .automatic
    var ocrLanguageIsAutoDetected = false
    private var ocrLanguageWasChangedByUser = false
    var targetLanguage: TranslationTargetLanguage = .simplifiedChinese
    var pageRangeText = ""
    var forcedDirection: TranslationDirection?
    var progress: PipelineProgress?
    var runStartedAt: Date?
    var composed: ComposedDocument?
    var parsed: ParsedDocument?
    var outputURL: URL?
    var previewPageIndex = 0
    var previewPageCount = 1

    mutating func acceptFile(_ url: URL, password: String? = nil, pageCount: Int = 1) {
        sourceURL = url
        self.password = password
        ocrLanguage = .automatic
        ocrLanguageIsAutoDetected = false
        ocrLanguageWasChangedByUser = false
        targetLanguage = .simplifiedChinese
        pageRangeText = ""
        forcedDirection = nil
        progress = nil
        runStartedAt = nil
        composed = nil
        parsed = nil
        outputURL = nil
        previewPageIndex = 0
        previewPageCount = max(1, pageCount)
        phase = .optionsReady
    }

    mutating func startRunning(now: Date = Date()) {
        progress = nil
        runStartedAt = now
        outputURL = nil
        phase = .running
    }

    mutating func update(progress: PipelineProgress) {
        self.progress = progress
    }

    mutating func markPreview(composed: ComposedDocument, parsed: ParsedDocument) {
        self.composed = composed
        self.parsed = parsed
        runStartedAt = nil
        phase = .previewing
    }

    mutating func markSaved(outputURL: URL) {
        self.outputURL = outputURL
        phase = .saved
    }

    mutating func reset() {
        self = TranslateFlowState()
    }

    var previewPageDisplayText: String {
        "\(previewPageIndex + 1)/\(previewPageCount)"
    }

    var canMoveToPreviousPreviewPage: Bool {
        previewPageIndex > 0
    }

    var canMoveToNextPreviewPage: Bool {
        previewPageIndex < previewPageCount - 1
    }

    mutating func movePreviewPage(by delta: Int) {
        let upperBound = max(0, previewPageCount - 1)
        previewPageIndex = min(max(previewPageIndex + delta, 0), upperBound)
    }

    mutating func applyDetectedOCRLanguage(_ language: OCRLanguage?) {
        guard !ocrLanguageWasChangedByUser else { return }
        guard let language, language != .automatic else {
            ocrLanguage = .automatic
            ocrLanguageIsAutoDetected = false
            return
        }
        ocrLanguage = language
        ocrLanguageIsAutoDetected = true
    }

    mutating func setOCRLanguage(_ language: OCRLanguage) {
        ocrLanguage = language
        ocrLanguageIsAutoDetected = false
        ocrLanguageWasChangedByUser = true
    }

    func ocrLanguageLabel(for language: OCRLanguage) -> String {
        let base = Self.ocrLanguageName(for: language)
        if language == ocrLanguage, ocrLanguageIsAutoDetected {
            return String(format: L10n.t("translate.ocrLanguage.autoFormat"), base)
        }
        return base
    }

    static func ocrLanguageName(for language: OCRLanguage) -> String {
        switch language {
        case .automatic: return L10n.t("translate.ocrLanguage.automatic")
        case .english: return L10n.t("translate.ocrLanguage.english")
        case .simplifiedChinese: return L10n.t("translate.ocrLanguage.simplifiedChinese")
        case .traditionalChinese: return L10n.t("translate.ocrLanguage.traditionalChinese")
        case .japanese: return L10n.t("translate.ocrLanguage.japanese")
        case .korean: return L10n.t("translate.ocrLanguage.korean")
        }
    }

    static func targetLanguageName(for language: TranslationTargetLanguage) -> String {
        switch language {
        case .simplifiedChinese: return L10n.t("translate.targetLanguage.simplifiedChinese")
        case .english: return L10n.t("translate.targetLanguage.english")
        }
    }

    static func fileExtension(for format: OutputFormat) -> String {
        switch format {
        case .markdown: return "md"
        case .pdf: return "pdf"
        case .docx: return "docx"
        }
    }

    static func defaultOutputURL(sourceURL: URL, format: OutputFormat) -> URL {
        sourceURL
            .deletingLastPathComponent()
            .appendingPathComponent(defaultOutputName(sourceURL: sourceURL, format: format))
    }

    static func defaultOutputName(sourceURL: URL, format: OutputFormat) -> String {
        let base = sourceURL.deletingPathExtension().lastPathComponent
        return "\(base)-translated.\(fileExtension(for: format))"
    }
}

enum TranslateProgressFormatter {
    private static let parseAndOCRShare = 0.45
    private static let translationStart = 0.45
    private static let translationShare = 0.50
    private static let composingValue = 0.98

    static func value(for progress: PipelineProgress?) -> Double {
        guard let progress else { return 0 }
        return value(for: progress)
    }

    static func value(for progress: PipelineProgress) -> Double {
        guard progress.totalPages > 0 else { return 0 }
        let pageFraction = min(max(Double(progress.currentPage) / Double(progress.totalPages), 0), 1)
        switch progress.stage {
        case .parsing, .ocr:
            return parseAndOCRShare * pageFraction
        case .translating:
            return translationStart + translationShare * pageFraction
        case .composing:
            return composingValue
        }
    }

    static func text(for progress: PipelineProgress?, startedAt: Date? = nil, now: Date = Date()) -> String {
        guard let progress else {
            return L10n.t("translate.running")
        }
        return text(for: progress, startedAt: startedAt, now: now)
    }

    static func text(for progress: PipelineProgress, startedAt: Date? = nil, now: Date = Date()) -> String {
        let stage = L10n.t("translate.stage.\(progress.stage.rawValue)")
        let percentage = Int((value(for: progress) * 100).rounded())
        let base = "\(stage) \(L10n.t("translate.page.prefix")) \(progress.currentPage)/\(progress.totalPages) (\(percentage)%)"
        guard let startedAt else { return base }
        guard let remainingSeconds = estimatedRemainingSeconds(for: progress, startedAt: startedAt, now: now) else {
            return "\(base) · \(L10n.t("translate.remaining.estimating"))"
        }
        return "\(base) · \(remainingText(for: remainingSeconds))"
    }

    static func estimatedRemainingSeconds(for progress: PipelineProgress, startedAt: Date?, now: Date) -> Int? {
        guard let startedAt else { return nil }
        let elapsed = now.timeIntervalSince(startedAt)
        guard elapsed >= 1 else { return nil }
        let progressValue = value(for: progress)
        guard progressValue > 0 else { return nil }
        if progressValue >= composingValue { return 0 }
        let remaining = elapsed * (1 - progressValue) / progressValue
        return max(0, Int(remaining.rounded()))
    }

    static func remainingText(for seconds: Int) -> String {
        if seconds < 60 {
            return String(format: L10n.t("translate.remaining.seconds"), max(0, seconds))
        }
        let minutes = max(1, Int(ceil(Double(seconds) / 60)))
        if minutes < 60 {
            return String(format: L10n.t("translate.remaining.minutes"), minutes)
        }
        let hours = minutes / 60
        let remainingMinutes = minutes % 60
        if remainingMinutes == 0 {
            return String(format: L10n.t("translate.remaining.hours"), hours)
        }
        return String(format: L10n.t("translate.remaining.hoursMinutes"), hours, remainingMinutes)
    }
}
