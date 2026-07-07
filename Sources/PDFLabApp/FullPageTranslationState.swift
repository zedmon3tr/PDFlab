import PDFLabCore

struct ParagraphPageContext: Equatable {
    var pageIndex: Int
    var paragraphs: [PageParagraph]
}

struct ParagraphPageContextConfiguration {
    var onPageContext: @MainActor (ParagraphPageContext) -> Void
}

struct FullPageTranslationToken: Equatable {
    var generation: Int
    var pageIndex: Int
}

enum FullPageTranslationPageAction: Equatable {
    case ignored
    case showCached([ParagraphTranslationEntry])
    case showLoading([ParagraphTranslationEntry])
    case showEmpty
    case start(token: FullPageTranslationToken, entries: [ParagraphTranslationEntry], texts: [String])
}

struct FullPageTranslationState {
    private(set) var isEnabled = false

    private var generation = 0
    private var active: (token: FullPageTranslationToken, entries: [ParagraphTranslationEntry])?
    private var cache: [Int: [ParagraphTranslationEntry]] = [:]

    mutating func enable() {
        isEnabled = true
    }

    mutating func disable() -> [ParagraphTranslationEntry] {
        isEnabled = false
        generation += 1
        active = nil
        cache.removeAll()
        return []
    }

    mutating func request(_ context: ParagraphPageContext) -> FullPageTranslationPageAction {
        guard isEnabled else { return .ignored }

        if let cached = cache[context.pageIndex] {
            active = nil
            return .showCached(cached)
        }

        if let active, active.token.pageIndex == context.pageIndex {
            return .showLoading(active.entries)
        }

        guard !context.paragraphs.isEmpty else {
            active = nil
            cache[context.pageIndex] = []
            return .showEmpty
        }

        generation += 1
        let token = FullPageTranslationToken(generation: generation, pageIndex: context.pageIndex)
        let entries = context.paragraphs.map { paragraph in
            ParagraphTranslationEntry(
                pageIndex: context.pageIndex,
                sourceText: paragraph.text,
                isLowQualityOCR: paragraph.ocrConfidence.map { $0 < 0.5 } ?? false
            )
        }
        active = (token, entries)
        return .start(token: token, entries: entries, texts: context.paragraphs.map(\.text))
    }

    mutating func succeed(_ token: FullPageTranslationToken, entries: [ParagraphTranslationEntry]) -> [ParagraphTranslationEntry]? {
        guard active?.token == token else { return nil }
        active = nil
        cache[token.pageIndex] = entries
        return entries
    }

    mutating func fail(
        _ token: FullPageTranslationToken,
        message: String,
        suggestsEngineSwitch: Bool
    ) -> [ParagraphTranslationEntry]? {
        guard let active, active.token == token else { return nil }
        let entries = active.entries.map { entry in
            var failed = entry
            failed.state = .failed(message: message, suggestsEngineSwitch: suggestsEngineSwitch)
            return failed
        }
        self.active = nil
        return entries
    }
}
