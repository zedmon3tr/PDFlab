import CoreGraphics
import Foundation
import Vision

public struct OCRService: Sendable {
    private let languages: [Locale.Language]

    public init(primaryChinese: Bool) {
        let zh = Locale.Language(identifier: "zh-Hans")
        let en = Locale.Language(identifier: "en-US")
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
            return try await runDocumentRecognition(image, pageIndex: pageIndex)
        } else {
            return try await runTextRecognition(image, pageIndex: pageIndex)
        }
    }

    @available(macOS 26.0, *)
    private func runDocumentRecognition(_ image: CGImage, pageIndex: Int) async throws -> (lines: [TextLine], confidence: Double) {
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

        return normalizedResult(lines)
    }

    @available(macOS 26.0, *)
    private func paragraphConfidence(_ paragraph: DocumentObservation.Container.Text) -> Double {
        guard !paragraph.lines.isEmpty else {
            return 0.9
        }
        let sum = paragraph.lines.reduce(0.0) { $0 + Double($1.confidence) }
        return sum / Double(paragraph.lines.count)
    }

    private func runTextRecognition(_ image: CGImage, pageIndex: Int) async throws -> (lines: [TextLine], confidence: Double) {
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

        return normalizedResult(lines)
    }

    private func normalizedResult(_ lines: [TextLine]) -> (lines: [TextLine], confidence: Double) {
        let normalized = Self.normalizeReadingOrder(lines)
        let confidences = normalized.compactMap(\.confidence)
        return (normalized, confidences.isEmpty ? 0 : confidences.reduce(0, +) / Double(confidences.count))
    }

    static func normalizeReadingOrder(_ lines: [TextLine]) -> [TextLine] {
        lines.compactMap { line in
            let text = line.text.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !text.isEmpty else { return nil }
            return TextLine(
                text: text,
                pageIndex: line.pageIndex,
                bbox: line.bbox,
                confidence: line.confidence
            )
        }
        .sorted { lhs, rhs in
            let lhsMidY = lhs.bbox.midY
            let rhsMidY = rhs.bbox.midY
            let sameBandTolerance = max(lhs.bbox.height, rhs.bbox.height) * 0.5

            if abs(lhsMidY - rhsMidY) <= sameBandTolerance {
                if lhs.bbox.minX != rhs.bbox.minX {
                    return lhs.bbox.minX < rhs.bbox.minX
                }
                return lhs.text < rhs.text
            }

            if lhs.bbox.maxY != rhs.bbox.maxY {
                return lhs.bbox.maxY > rhs.bbox.maxY
            }
            if lhs.bbox.minY != rhs.bbox.minY {
                return lhs.bbox.minY > rhs.bbox.minY
            }
            if lhs.bbox.minX != rhs.bbox.minX {
                return lhs.bbox.minX < rhs.bbox.minX
            }
            return lhs.text < rhs.text
        }
    }
}
