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
        var confidenceSum = 0.0

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
                confidenceSum += confidence
            }
        }

        return (lines, lines.isEmpty ? 0 : confidenceSum / Double(lines.count))
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
        var confidenceSum = 0.0

        for observation in observations {
            guard let candidate = observation.topCandidates(1).first else { continue }
            let confidence = Double(candidate.confidence)
            lines.append(TextLine(
                text: candidate.string,
                pageIndex: pageIndex,
                bbox: observation.boundingBox.cgRect,
                confidence: confidence
            ))
            confidenceSum += confidence
        }

        return (lines, lines.isEmpty ? 0 : confidenceSum / Double(lines.count))
    }
}
