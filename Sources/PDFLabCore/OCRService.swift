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
    private static let lowConfidenceThreshold = 0.5
    private static let nearZeroLineCount = 1
    private static let rotationScoreImprovement = 0.03
    private static let rotationConfidenceTolerance = 0.02

    private enum TextRecognitionLevel {
        case accurate
        case fast
    }

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
        try Task.checkCancellation()
        let first = try await runOnce(image, pageIndex: pageIndex)
        try Task.checkCancellation()
        guard Self.needsCorrection(first) else { return first }

        try Task.checkCancellation()
        let enhancedImage = ImagePreprocessor.enhance(image)
        try Task.checkCancellation()
        let retry = try await runOnce(enhancedImage, pageIndex: pageIndex)
        try Task.checkCancellation()
        let baseline = Self.preferred(first, retry)
        guard Self.needsCorrection(baseline) else { return baseline }

        let screeningLevel = textScreeningLevel()
        var screened: [(degrees: Int, result: OCRPageResult)] = []
        for degrees in [0, 90, 180, 270] {
            try Task.checkCancellation()
            guard let candidateImage = PageRasterizer.rotated(image, clockwiseDegrees: degrees) else { continue }
            let candidate = try await runTextRecognition(
                candidateImage,
                pageIndex: pageIndex,
                level: screeningLevel
            )
            try Task.checkCancellation()
            screened.append((degrees, candidate))
        }

        let screeningMaxCharacters = Self.maxCharacterCount(in: screened.map(\.result))
        guard let zeroScreen = screened.first(where: { $0.degrees == 0 }),
              let screenWinner = screened.max(by: {
                  Self.rotationCandidateScore($0.result, maxCharacterCount: screeningMaxCharacters)
                      < Self.rotationCandidateScore($1.result, maxCharacterCount: screeningMaxCharacters)
              }),
              screenWinner.degrees != 0,
              Self.shouldAcceptRotation(screenWinner.result, over: zeroScreen.result),
              let rotatedImage = PageRasterizer.rotated(image, clockwiseDegrees: screenWinner.degrees) else {
            await recordRotationDiagnostic(pageIndex: pageIndex, triedAngles: screened.map(\.degrees), baseline: baseline, selected: baseline)
            return baseline
        }

        try Task.checkCancellation()
        var rotated = try await runOnce(rotatedImage, pageIndex: pageIndex)
        try Task.checkCancellation()
        if Self.needsCorrection(rotated) {
            let enhancedRotatedImage = ImagePreprocessor.enhance(rotatedImage)
            try Task.checkCancellation()
            let enhancedRotated = try await runOnce(enhancedRotatedImage, pageIndex: pageIndex)
            try Task.checkCancellation()
            rotated = Self.preferred(rotated, enhancedRotated)
        }

        guard Self.shouldAcceptRotation(rotated, over: baseline) else {
            await recordRotationDiagnostic(pageIndex: pageIndex, triedAngles: screened.map(\.degrees), baseline: baseline, selected: baseline)
            return baseline
        }
        rotated.layout.rotationDegrees = screenWinner.degrees
        await recordRotationDiagnostic(pageIndex: pageIndex, triedAngles: screened.map(\.degrees), baseline: baseline, selected: rotated)
        return rotated
    }

    private func runOnce(_ image: CGImage, pageIndex: Int) async throws -> OCRPageResult {
        try Task.checkCancellation()
        if #available(macOS 26.0, *) {
            let result = try await runDocumentRecognition(image, pageIndex: pageIndex)
            try Task.checkCancellation()
            return result
        } else {
            let result = try await runTextRecognition(image, pageIndex: pageIndex, level: .accurate)
            try Task.checkCancellation()
            return result
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
            if let title = document.title, let region = systemTextRegion(
                title, pageIndex: pageIndex, id: "system-p\(pageIndex)-title", regionKind: .title, blockKind: .title
            ) {
                regions.append(region)
            }
            for (tableIndex, table) in document.tables.enumerated() {
                let cellRows = table.rows.map { cells in
                    cells.map { systemLines(from: $0.content.text, pageIndex: pageIndex) }
                }
                guard let region = Self.systemTableRegion(
                    pageIndex: pageIndex, tableIndex: tableIndex, cellRows: cellRows,
                    bbox: table.boundingRegion.boundingBox.cgRect
                ) else { continue }
                regions.append(region)
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
            }
            for (paragraphIndex, paragraph) in document.paragraphs.enumerated() {
                guard let region = systemTextRegion(
                        paragraph, pageIndex: pageIndex,
                        id: "system-p\(pageIndex)-paragraph\(paragraphIndex)", regionKind: .body, blockKind: .paragraph
                      ) else { continue }
                regions.append(region)
            }
        }
        regions = Self.removingBodyRegionsOverlappingSpecializedRegions(regions)
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

    static func removingBodyRegionsOverlappingSpecializedRegions(_ regions: [LayoutRegion]) -> [LayoutRegion] {
        let specializedRegions = regions.filter { $0.kind == .table || $0.kind == .list || $0.kind == .title }
        return regions.compactMap { region in
            guard region.kind == .body else { return region }
            let blocks = region.blocks.compactMap { block -> LayoutBlock? in
                let lines = block.lines.filter { line in
                    !specializedRegions.contains { specialized in
                        isProvenDuplicate(line, of: specialized)
                    }
                }
                guard !lines.isEmpty else { return nil }
                let unchanged = lines.count == block.lines.count
                return LayoutBlock(
                    id: block.id, kind: block.kind, lines: lines,
                    bbox: unchanged ? block.bbox : nil, tableCells: block.tableCells
                )
            }
            guard !blocks.isEmpty else { return nil }
            return LayoutRegion(
                id: region.id, kind: region.kind, source: region.source,
                blocks: blocks, bbox: blocks == region.blocks ? region.bbox : nil
            )
        }
    }

    private static func isProvenDuplicate(_ line: TextLine, of specialized: LayoutRegion) -> Bool {
        if specialized.bbox.contains(line.bbox) { return true }
        let text = normalizedComparisonText(line.text)
        guard !text.isEmpty else { return false }
        return specialized.flattenedLines.contains { specializedLine in
            normalizedComparisonText(specializedLine.text) == text
                && overlapRatio(line.bbox, specializedLine.bbox) >= 0.5
        }
    }

    private static func normalizedComparisonText(_ text: String) -> String {
        text.split(whereSeparator: \.isWhitespace).joined(separator: " ").lowercased()
    }

    static func systemTableRegion(
        pageIndex: Int,
        tableIndex: Int,
        cellRows: [[[TextLine]]],
        bbox: CGRect? = nil
    ) -> LayoutRegion? {
        let blocks = cellRows.enumerated().compactMap { rowIndex, cells -> LayoutBlock? in
            let tableCells = cells.enumerated().map { columnIndex, lines -> LayoutTableCell in
                let ordered = lines.sorted {
                    if $0.bbox.midY != $1.bbox.midY { return $0.bbox.midY > $1.bbox.midY }
                    if $0.bbox.minX != $1.bbox.minX { return $0.bbox.minX < $1.bbox.minX }
                    return $0.text < $1.text
                }
                return LayoutTableCell(columnIndex: columnIndex, lines: ordered)
            }
            guard tableCells.contains(where: { !$0.lines.isEmpty }) else { return nil }
            return LayoutBlock(
                id: .init("system-p\(pageIndex)-table\(tableIndex)-row\(rowIndex)"),
                kind: .tableRow,
                lines: tableCells.flatMap(\.lines),
                tableCells: tableCells
            )
        }
        guard !blocks.isEmpty else { return nil }
        return LayoutRegion(
            id: "system-p\(pageIndex)-table\(tableIndex)", kind: .table, source: .system,
            blocks: blocks, bbox: bbox
        )
    }

    private static func overlapRatio(_ lhs: CGRect, _ rhs: CGRect) -> CGFloat {
        let intersection = lhs.intersection(rhs)
        guard !intersection.isNull, lhs.width > 0, lhs.height > 0 else { return 0 }
        return (intersection.width * intersection.height) / (lhs.width * lhs.height)
    }

    private func runTextRecognition(
        _ image: CGImage,
        pageIndex: Int,
        level: TextRecognitionLevel
    ) async throws -> OCRPageResult {
        try Task.checkCancellation()
        if #available(macOS 26.0, *) {
            return try await runModernTextRecognition(image, pageIndex: pageIndex, level: level)
        }

        return try await runLegacyTextRecognition(image, pageIndex: pageIndex, level: level)
    }

    @available(macOS 15.0, *)
    private func runModernTextRecognition(
        _ image: CGImage,
        pageIndex: Int,
        level: TextRecognitionLevel
    ) async throws -> OCRPageResult {
        var request = RecognizeTextRequest()
        request.recognitionLevel = level == .fast ? .fast : .accurate
        request.usesLanguageCorrection = true
        request.recognitionLanguages = languages

        try Task.checkCancellation()
        let observations = try await request.perform(on: image)
        try Task.checkCancellation()
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

    private func runLegacyTextRecognition(
        _ image: CGImage,
        pageIndex: Int,
        level: TextRecognitionLevel
    ) async throws -> OCRPageResult {
        try Task.checkCancellation()
        let result: OCRPageResult = try await withCheckedThrowingContinuation { continuation in
            let request = VNRecognizeTextRequest { request, error in
                if let error {
                    continuation.resume(throwing: error)
                    return
                }

                let observations = (request.results as? [VNRecognizedTextObservation]) ?? []
                var lines: [TextLine] = []
                var tableCandidates: [TextLine] = []
                for observation in observations {
                    guard let candidate = observation.topCandidates(1).first else { continue }
                    lines.append(TextLine(
                        text: candidate.string,
                        pageIndex: pageIndex,
                        bbox: observation.boundingBox,
                        confidence: Double(candidate.confidence)
                    ))
                    tableCandidates += Self.legacyWordLines(from: candidate, pageIndex: pageIndex)
                }
                continuation.resume(returning: self.normalizedResult(
                    lines,
                    pageIndex: pageIndex,
                    tableCandidates: tableCandidates
                ))
            }
            request.revision = VNRecognizeTextRequestRevision3
            request.recognitionLevel = level == .fast ? .fast : .accurate
            request.usesLanguageCorrection = true
            request.recognitionLanguages = legacyLanguageIdentifiers

            do {
                try VNImageRequestHandler(cgImage: image, options: [:]).perform([request])
            } catch {
                continuation.resume(throwing: error)
            }
        }
        try Task.checkCancellation()
        return result
    }

    private func textScreeningLevel() -> TextRecognitionLevel {
        if #available(macOS 26.0, *) {
            var request = RecognizeTextRequest()
            request.recognitionLevel = .fast
            return request.supportedRecognitionLanguages.contains(languages[0]) ? .fast : .accurate
        }
        let request = VNRecognizeTextRequest()
        request.revision = VNRecognizeTextRequestRevision3
        request.recognitionLevel = .fast
        let supported = (try? request.supportedRecognitionLanguages()) ?? []
        return supported.contains(legacyLanguageIdentifiers[0]) ? .fast : .accurate
    }

    private static func legacyWordLines(from candidate: VNRecognizedText, pageIndex: Int) -> [TextLine] {
        var lines: [TextLine] = []
        let text = candidate.string
        text.enumerateSubstrings(in: text.startIndex..<text.endIndex, options: [.byWords, .substringNotRequired]) {
            _, range, _, _ in
            guard let box = try? candidate.boundingBox(for: range) else { return }
            lines.append(TextLine(
                text: String(text[range]),
                pageIndex: pageIndex,
                bbox: box.boundingBox,
                confidence: Double(candidate.confidence)
            ))
        }
        return lines
    }

    static func needsCorrection(_ result: OCRPageResult) -> Bool {
        result.confidence < lowConfidenceThreshold || result.lines.count <= nearZeroLineCount
    }

    private static func characterCount(_ result: OCRPageResult) -> Int {
        result.lines.reduce(into: 0) { count, line in
            count += line.text.filter { !$0.isWhitespace }.count
        }
    }

    private static func maxCharacterCount(in results: [OCRPageResult]) -> Int {
        results.map(characterCount).max() ?? 0
    }

    static func rotationCandidateScore(_ result: OCRPageResult, maxCharacterCount: Int) -> Double {
        let characterSignal = maxCharacterCount > 0
            ? min(Double(characterCount(result)) / Double(maxCharacterCount), 1)
            : 0
        return 0.8 * result.confidence + 0.2 * characterSignal
    }

    static func shouldAcceptRotation(_ candidate: OCRPageResult, over baseline: OCRPageResult) -> Bool {
        let maxCharacters = maxCharacterCount(in: [baseline, candidate])
        return rotationCandidateScore(candidate, maxCharacterCount: maxCharacters)
                >= rotationCandidateScore(baseline, maxCharacterCount: maxCharacters) + rotationScoreImprovement
            && candidate.confidence >= baseline.confidence - rotationConfidenceTolerance
    }

    private static func preferred(_ lhs: OCRPageResult, _ rhs: OCRPageResult) -> OCRPageResult {
        let maxCharacters = maxCharacterCount(in: [lhs, rhs])
        let lhsScore = rotationCandidateScore(lhs, maxCharacterCount: maxCharacters)
        let rhsScore = rotationCandidateScore(rhs, maxCharacterCount: maxCharacters)
        return rhsScore > lhsScore ? rhs : lhs
    }

    private func recordRotationDiagnostic(
        pageIndex: Int,
        triedAngles: [Int],
        baseline: OCRPageResult,
        selected: OCRPageResult
    ) async {
        #if DEBUG
        await OCRRotationDiagnostics.shared.record(.init(
            pageIndex: pageIndex,
            attemptedDegrees: triedAngles,
            baselineConfidence: baseline.confidence,
            selectedDegrees: selected.layout.rotationDegrees,
            selectedConfidence: selected.confidence
        ))
        #endif
    }

    private func normalizedResult(
        _ lines: [TextLine],
        pageIndex: Int,
        tableCandidates: [TextLine]? = nil
    ) -> OCRPageResult {
        let normalized = Self.normalizeLines(lines)
        let normalizedCandidates = tableCandidates.map(Self.normalizeLines)
        return result(layout: PageReadingOrder.layout(
            normalized,
            pageIndex: pageIndex,
            tableCandidates: normalizedCandidates
        ))
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
