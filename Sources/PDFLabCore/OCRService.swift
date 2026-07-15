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
        var regions: [LayoutRegion] = []

        for observation in observations {
            let document = observation.document
            var occupied: [CGRect] = []
            if let title = document.title, let region = systemTextRegion(
                title, pageIndex: pageIndex, id: "system-p\(pageIndex)-title", regionKind: .title, blockKind: .title
            ) {
                regions.append(region)
                occupied.append(region.bbox)
            }
            for (tableIndex, table) in document.tables.enumerated() {
                let blocks = table.rows.enumerated().compactMap { rowIndex, cells -> LayoutBlock? in
                    let lines = cells.flatMap { systemLines(from: $0.content.text, pageIndex: pageIndex) }
                    guard !lines.isEmpty else { return nil }
                    return LayoutBlock(id: .init("system-p\(pageIndex)-table\(tableIndex)-row\(rowIndex)"), kind: .tableRow, lines: lines)
                }
                guard !blocks.isEmpty else { continue }
                let region = LayoutRegion(
                    id: "system-p\(pageIndex)-table\(tableIndex)", kind: .table, source: .system,
                    blocks: blocks, bbox: table.boundingRegion.boundingBox.cgRect
                )
                regions.append(region)
                occupied.append(region.bbox)
            }
            for (listIndex, list) in document.lists.enumerated() {
                let blocks = list.items.enumerated().compactMap { itemIndex, item -> LayoutBlock? in
                    let lines = systemLines(from: item.content.text, pageIndex: pageIndex)
                    guard !lines.isEmpty else { return nil }
                    return LayoutBlock(id: .init("system-p\(pageIndex)-list\(listIndex)-item\(itemIndex)"), kind: .listItem, lines: lines)
                }
                guard !blocks.isEmpty else { continue }
                let region = LayoutRegion(
                    id: "system-p\(pageIndex)-list\(listIndex)", kind: .list, source: .system,
                    blocks: blocks, bbox: list.boundingRegion.boundingBox.cgRect
                )
                regions.append(region)
                occupied.append(region.bbox)
            }
            for (paragraphIndex, paragraph) in document.paragraphs.enumerated() {
                let bounds = paragraph.boundingRegion.boundingBox.cgRect
                guard !occupied.contains(where: { overlapRatio(bounds, $0) >= 0.5 }),
                      let region = systemTextRegion(
                        paragraph, pageIndex: pageIndex,
                        id: "system-p\(pageIndex)-paragraph\(paragraphIndex)", regionKind: .body, blockKind: .paragraph
                      ) else { continue }
                regions.append(region)
            }
        }
        regions.sort {
            if $0.bbox.maxY != $1.bbox.maxY { return $0.bbox.maxY > $1.bbox.maxY }
            return $0.bbox.minX < $1.bbox.minX
        }
        return result(layout: PageLayout(pageIndex: pageIndex, regions: regions))
    }

    @available(macOS 26.0, *)
    private func systemTextRegion(
        _ text: DocumentObservation.Container.Text,
        pageIndex: Int,
        id: String,
        regionKind: LayoutRegionKind,
        blockKind: LayoutBlockKind
    ) -> LayoutRegion? {
        let lines = systemLines(from: text, pageIndex: pageIndex)
        guard !lines.isEmpty else { return nil }
        let block = LayoutBlock(id: .init("\(id)-b0"), kind: blockKind, lines: lines, bbox: text.boundingRegion.boundingBox.cgRect)
        return LayoutRegion(id: id, kind: regionKind, source: .system, blocks: [block], bbox: text.boundingRegion.boundingBox.cgRect)
    }

    @available(macOS 26.0, *)
    private func systemLines(from text: DocumentObservation.Container.Text, pageIndex: Int) -> [TextLine] {
        let lines: [TextLine] = text.lines.compactMap { observation -> TextLine? in
            guard let candidate = observation.topCandidates(1).first else { return nil }
            return TextLine(
                text: candidate.string,
                pageIndex: pageIndex,
                bbox: observation.boundingBox.cgRect,
                confidence: Double(candidate.confidence)
            )
        }
        if !lines.isEmpty { return lines }
        let transcript = text.transcript.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !transcript.isEmpty else { return [] }
        return [TextLine(
            text: transcript,
            pageIndex: pageIndex,
            bbox: text.boundingRegion.boundingBox.cgRect,
            confidence: nil
        )]
    }

    private func overlapRatio(_ lhs: CGRect, _ rhs: CGRect) -> CGFloat {
        let intersection = lhs.intersection(rhs)
        guard !intersection.isNull, lhs.width > 0, lhs.height > 0 else { return 0 }
        return (intersection.width * intersection.height) / (lhs.width * lhs.height)
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
