import CoreGraphics
import Foundation
import Vision

public struct OCRPageResult: Equatable, Sendable {
    public var layout: PageLayout
    public var confidence: Double
    public var lines: [TextLine] { layout.flattenedLines }

    public init(layout: PageLayout, confidence: Double) {
        self.layout = layout
        self.confidence = confidence
    }
}

public struct OCRService: Sendable {
    private let languages: [Locale.Language]
    private let legacyLanguageIdentifiers: [String]

    public init(primaryChinese: Bool) {
        self.init(language: primaryChinese ? .simplifiedChinese : .english)
    }

    public init(language: OCRLanguage) {
        let zh = (language: Locale.Language(identifier: "zh-Hans"), legacyIdentifier: "zh-Hans")
        let zhHant = (language: Locale.Language(identifier: "zh-Hant"), legacyIdentifier: "zh-Hant")
        let en = (language: Locale.Language(identifier: "en-US"), legacyIdentifier: "en-US")
        let ja = (language: Locale.Language(identifier: "ja"), legacyIdentifier: "ja")
        let ko = (language: Locale.Language(identifier: "ko"), legacyIdentifier: "ko")

        let selected: [(language: Locale.Language, legacyIdentifier: String)]
        switch language {
        case .automatic:
            selected = [en, zh, zhHant, ja, ko]
        case .english:
            selected = [en, zh]
        case .simplifiedChinese:
            selected = [zh, en]
        case .traditionalChinese:
            selected = [zhHant, zh, en]
        case .japanese:
            selected = [ja, en, zh]
        case .korean:
            selected = [ko, en, zh]
        }
        languages = selected.map(\.language)
        legacyLanguageIdentifiers = selected.map(\.legacyIdentifier)
    }

    public func recognizePage(_ image: CGImage, pageIndex: Int) async throws -> OCRPageResult {
        let first = try await runOnce(image, pageIndex: pageIndex)
        if first.confidence < 0.5 {
            let retry = try await runOnce(ImagePreprocessor.enhance(image), pageIndex: pageIndex)
            return retry.confidence > first.confidence ? retry : first
        }
        return first
    }

    private func runOnce(_ image: CGImage, pageIndex: Int) async throws -> OCRPageResult {
        if #available(macOS 26.0, *) {
            return try await runDocumentRecognition(image, pageIndex: pageIndex)
        } else {
            return try await runTextRecognition(image, pageIndex: pageIndex)
        }
    }

    @available(macOS 26.0, *)
    private func runDocumentRecognition(_ image: CGImage, pageIndex: Int) async throws -> OCRPageResult {
        var request = RecognizeDocumentsRequest()
        request.textRecognitionOptions.recognitionLanguages = languages
        request.textRecognitionOptions.useLanguageCorrection = true

        let observations = try await request.perform(on: image)
        var lines: [TextLine] = []

        for observation in observations {
            for paragraph in observation.document.paragraphs {
                let text = paragraph.transcript
                guard !text.isEmpty else { continue }

                let confidence = paragraphConfidence(paragraph)
                lines.append(TextLine(
                    text: text,
                    pageIndex: pageIndex,
                    bbox: paragraph.boundingRegion.boundingBox.cgRect,
                    confidence: confidence
                ))
            }
        }

        let normalized = Self.normalizeLines(lines)
        let blocks = normalized.enumerated().map { index, line in
            LayoutBlock(id: .init("system-p\(pageIndex)-b\(index)"), kind: .paragraph, lines: [line])
        }
        return result(layout: Self.systemPageLayout(pageIndex: pageIndex, blocks: blocks))
    }

    @available(macOS 26.0, *)
    private func paragraphConfidence(_ paragraph: DocumentObservation.Container.Text) -> Double {
        guard !paragraph.lines.isEmpty else {
            // 0.9 is a fallback only when a paragraph reports no per-line confidence; real averaged confidence keeps the <0.5 retry rule meaningful.
            return 0.9
        }
        let sum = paragraph.lines.reduce(0.0) { $0 + Double($1.confidence) }
        return sum / Double(paragraph.lines.count)
    }

    private func runTextRecognition(_ image: CGImage, pageIndex: Int) async throws -> OCRPageResult {
        if #available(macOS 15.0, *) {
            return try await runModernTextRecognition(image, pageIndex: pageIndex)
        }

        return try await runLegacyTextRecognition(image, pageIndex: pageIndex)
    }

    @available(macOS 15.0, *)
    private func runModernTextRecognition(_ image: CGImage, pageIndex: Int) async throws -> OCRPageResult {
        var request = RecognizeTextRequest()
        request.recognitionLevel = .accurate
        request.usesLanguageCorrection = true
        request.recognitionLanguages = languages

        let observations = try await request.perform(on: image)
        var lines: [TextLine] = []

        for observation in observations {
            guard let candidate = observation.topCandidates(1).first else { continue }
            let confidence = Double(candidate.confidence)
            lines.append(TextLine(
                text: candidate.string,
                pageIndex: pageIndex,
                bbox: observation.boundingBox.cgRect,
                confidence: confidence
            ))
        }

        return normalizedResult(lines, pageIndex: pageIndex)
    }

    private func runLegacyTextRecognition(_ image: CGImage, pageIndex: Int) async throws -> OCRPageResult {
        try await withCheckedThrowingContinuation { continuation in
            let request = VNRecognizeTextRequest { request, error in
                if let error {
                    continuation.resume(throwing: error)
                    return
                }

                let observations = (request.results as? [VNRecognizedTextObservation]) ?? []
                let lines = observations.compactMap { observation -> TextLine? in
                    guard let candidate = observation.topCandidates(1).first else { return nil }
                    return TextLine(
                        text: candidate.string,
                        pageIndex: pageIndex,
                        bbox: observation.boundingBox,
                        confidence: Double(candidate.confidence)
                    )
                }
                continuation.resume(returning: self.normalizedResult(lines, pageIndex: pageIndex))
            }
            request.recognitionLevel = .accurate
            request.usesLanguageCorrection = true
            request.recognitionLanguages = legacyLanguageIdentifiers

            do {
                try VNImageRequestHandler(cgImage: image, options: [:]).perform([request])
            } catch {
                continuation.resume(throwing: error)
            }
        }
    }

    private func normalizedResult(_ lines: [TextLine], pageIndex: Int) -> OCRPageResult {
        let normalized = Self.normalizeLines(lines)
        return result(layout: PageReadingOrder.layout(normalized, pageIndex: pageIndex))
    }

    private func result(layout: PageLayout) -> OCRPageResult {
        let confidences = layout.flattenedLines.compactMap(\.confidence)
        return OCRPageResult(
            layout: layout,
            confidence: confidences.isEmpty ? 0 : confidences.reduce(0, +) / Double(confidences.count)
        )
    }

    public static func systemPageLayout(pageIndex: Int, blocks: [LayoutBlock]) -> PageLayout {
        guard !blocks.isEmpty else { return PageLayout(pageIndex: pageIndex, regions: []) }
        return PageLayout(pageIndex: pageIndex, regions: [
            LayoutRegion(id: "system-p\(pageIndex)-r0", kind: .body, source: .system, blocks: blocks)
        ])
    }

    static func normalizeReadingOrder(_ lines: [TextLine]) -> [TextLine] {
        let cleaned = normalizeLines(lines)
        let pages = Dictionary(grouping: cleaned, by: \.pageIndex)
        return pages.keys.sorted().flatMap { PageReadingOrder.order(pages[$0] ?? []) }
    }

    private static func normalizeLines(_ lines: [TextLine]) -> [TextLine] {
        let cleaned: [TextLine] = lines.compactMap { line in
            let text = line.text.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !text.isEmpty else { return nil }
            return TextLine(text: text, pageIndex: line.pageIndex, bbox: line.bbox, confidence: line.confidence)
        }
        return cleaned
    }
}
