import CoreGraphics
import Foundation

/// 一行文本及几何信息(OCR 或文本层均产出此结构;bbox 为页内归一化坐标,原点左下)。
public struct TextLine: Equatable, Sendable {
    public var text: String
    public var pageIndex: Int
    public var bbox: CGRect
    public var confidence: Double?
    public init(text: String, pageIndex: Int, bbox: CGRect, confidence: Double? = nil) {
        self.text = text
        self.pageIndex = pageIndex
        self.bbox = bbox
        self.confidence = confidence
    }
}

public enum ParagraphBuilder {
    private static let sentenceEnders: Set<Character> = ["。", ".", "!", "?", "！", "？", ";", "；", ":", "：", "」", "”", "\"", "』"]

    public static func buildParagraphs(from lines: [TextLine]) -> [SourceParagraph] {
        let block = LayoutBlock(id: .init("compat-lines"), kind: .text, lines: lines)
        let region = LayoutRegion(id: "compat-lines", kind: .body, source: .heuristic, blocks: [block])
        return buildParagraphs(
            from: [PageLayout(pageIndex: lines.first?.pageIndex ?? 0, regions: [region])],
            assignsStableMetadata: false
        )
    }

    public static func buildParagraphs(from blocks: [LayoutBlock]) -> [SourceParagraph] {
        let regions = blocks.enumerated().map { index, block in
            LayoutRegion(id: "compat-block-\(index)", kind: .body, source: .heuristic, blocks: [block])
        }
        return buildParagraphs(
            from: [PageLayout(pageIndex: blocks.first?.lines.first?.pageIndex ?? 0, regions: regions)],
            assignsStableMetadata: true
        )
    }

    public static func buildParagraphs(from layouts: [PageLayout]) -> [SourceParagraph] {
        buildParagraphs(from: layouts, assignsStableMetadata: true)
    }

    private static func buildParagraphs(
        from layouts: [PageLayout],
        assignsStableMetadata: Bool
    ) -> [SourceParagraph] {
        let allLines = layouts.flatMap { $0.regions.flatMap(\.flattenedLines) }
        let baseline = documentBodyLineHeight(in: allLines)
        let headingLevels = documentHeadingLevels(in: allLines, baseline: baseline)
        var paragraphs: [SourceParagraph] = []

        for layout in layouts {
            var pageBody: [SourceParagraph] = []
            var pageFootnotes: [SourceParagraph] = []
            for region in layout.regions where region.kind != .table {
                let regionLines = region.blocks.flatMap(\.lines)
                let threshold = adaptiveGapThreshold(for: verticalGaps(
                    in: regionLines,
                    regionKind: region.kind,
                    baseline: baseline,
                    headingLevels: headingLevels
                ))
                let bodyLines = region.blocks.filter { $0.kind != .title }.flatMap(\.lines)
                let leftEdge = modalEdge(bodyLines.map(\.bbox.minX), tolerance: baseline * 0.5)
                let rightEdge = modalEdge(bodyLines.map(\.bbox.maxX), tolerance: baseline * 0.5)

                for block in region.blocks where block.kind != .tableRow {
                    let built = buildBlock(
                        block,
                        region: region,
                        baseline: baseline,
                        headingLevels: headingLevels,
                        gapThreshold: threshold,
                        leftEdge: leftEdge,
                        rightEdge: rightEdge,
                        assignsStableMetadata: assignsStableMetadata
                    )
                    for paragraph in built {
                        if paragraph.kind == .footnote { pageFootnotes.append(paragraph) }
                        else { pageBody.append(paragraph) }
                    }
                }
            }
            paragraphs.append(contentsOf: pageBody)
            paragraphs.append(contentsOf: pageFootnotes)
        }
        return paragraphs
    }

    private static func buildBlock(
        _ block: LayoutBlock,
        region: LayoutRegion,
        baseline: CGFloat,
        headingLevels: [(height: CGFloat, level: Int)],
        gapThreshold: CGFloat?,
        leftEdge: CGFloat?,
        rightEdge: CGFloat?,
        assignsStableMetadata: Bool
    ) -> [SourceParagraph] {
        struct Pending {
            var text: String
            var page: Int
            var confs: [Double]
            var firstBox: CGRect
            var lastBox: CGRect
            var kind: SourceParagraphKind
        }
        var result: [SourceParagraph] = []
        var current: Pending?

        func isShort(_ box: CGRect) -> Bool {
            guard let rightEdge else { return false }
            return rightEdge - box.maxX > max(box.height, baseline) * 2
        }
        func flush() {
            guard let value = current else { return }
            let confidence = value.confs.isEmpty ? nil : value.confs.reduce(0, +) / Double(value.confs.count)
            result.append(SourceParagraph(
                text: value.text,
                pageIndex: value.page,
                ocrConfidence: confidence,
                kind: value.kind,
                translationUnitID: assignsStableMetadata ? TranslationUnitID("paragraph:\(block.id.rawValue):\(result.count)") : nil,
                sourceBlockIDs: assignsStableMetadata ? [block.id] : [],
                firstLineBBox: value.firstBox,
                lastLineBBox: value.lastBox,
                regionBodyRightEdge: rightEdge,
                lastLineIsShort: isShort(value.lastBox)
            ))
            current = nil
        }
        func start(_ line: TextLine, text: String? = nil, kind: SourceParagraphKind) {
            current = Pending(
                text: text ?? line.text,
                page: line.pageIndex,
                confs: line.confidence.map { [$0] } ?? [],
                firstBox: line.bbox,
                lastBox: line.bbox,
                kind: kind
            )
        }

        var index = 0
        while index < block.lines.count {
            let line = block.lines[index]
            let lineKind = semanticKind(
                for: line,
                blockKind: block.kind,
                regionKind: region.kind,
                baseline: baseline,
                headingLevels: headingLevels
            )
            let allowsListParsing: Bool
            switch lineKind {
            case .body, .listItem: allowsListParsing = true
            case .heading, .footnote: allowsListParsing = false
            }
            if allowsListParsing,
               let standalone = ParagraphListMarkerParser.standaloneMarker(in: line.text),
               index + 1 < block.lines.count {
                let next = block.lines[index + 1]
                if next.pageIndex == line.pageIndex,
                   isSameVisualLineContinuation(previous: line.bbox, next: next.bbox) {
                    flush()
                    let split = ParagraphListMarkerParser.splitLeadingMarker(in: next.text)
                    start(next, text: split?.body ?? next.text, kind: .listItem(marker: split?.marker ?? standalone))
                    index += 2
                    continue
                }
            }
            if allowsListParsing, ParagraphListMarkerParser.standaloneMarker(in: line.text) != nil {
                flush()
                index += 1
                continue
            }
            if allowsListParsing, let split = ParagraphListMarkerParser.splitLeadingMarker(in: line.text) {
                flush()
                start(line, text: split.body, kind: .listItem(marker: split.marker))
                index += 1
                continue
            }

            guard var pending = current, pending.page == line.pageIndex else {
                flush()
                start(line, kind: lineKind)
                index += 1
                continue
            }
            let sameVisualLine = isSameVisualLineContinuation(previous: pending.lastBox, next: line.bbox)
            let semanticBoundary = pending.kind != lineKind
            let startsIndented = leftEdge.map { line.bbox.minX - $0 > max(line.bbox.height, baseline) } ?? false
            let previousShort = isShort(pending.lastBox)
            let continues = sameVisualLine || (!semanticBoundary && !startsIndented && !previousShort && isNextLineContinuation(
                previous: pending.lastBox,
                next: line.bbox,
                gapThreshold: gapThreshold
            ))
            if continues {
                pending.text = join(pending.text, line.text)
                if let confidence = line.confidence { pending.confs.append(confidence) }
                if sameVisualLine, isSameVisualLineContinuation(previous: pending.firstBox, next: line.bbox) {
                    pending.firstBox = pending.firstBox.union(line.bbox)
                }
                pending.lastBox = sameVisualLine ? pending.lastBox.union(line.bbox) : line.bbox
                current = pending
            } else {
                flush()
                start(line, kind: lineKind)
            }
            index += 1
        }
        flush()
        return result
    }

    public static func mergeAcrossPages(_ paragraphs: [SourceParagraph]) -> [SourceParagraph] {
        var out: [SourceParagraph] = []
        for paragraph in paragraphs {
            var candidateIndex = out.indices.last
            while let index = candidateIndex, out[index].kind == .footnote {
                candidateIndex = index > out.startIndex ? out.index(before: index) : nil
            }
            let candidate = candidateIndex.map { ($0, out[$0]) }
            if let (candidateIndex, initialPrevious) = candidate,
               initialPrevious.kind == .body, paragraph.kind == .body,
               !initialPrevious.lastLineIsShort,
               initialPrevious.pageIndex < paragraph.pageIndex,
               let lastCharacter = initialPrevious.text.last, !sentenceEnders.contains(lastCharacter),
               let firstCharacter = paragraph.text.first, isContinuation(firstCharacter) {
                var previous = initialPrevious
                previous.text = join(previous.text, paragraph.text)
                previous.sourceBlockIDs.append(contentsOf: paragraph.sourceBlockIDs.filter { !previous.sourceBlockIDs.contains($0) })
                previous.lastLineBBox = paragraph.lastLineBBox
                previous.regionBodyRightEdge = paragraph.regionBodyRightEdge
                previous.lastLineIsShort = paragraph.lastLineIsShort
                out[candidateIndex] = previous
            } else {
                out.append(paragraph)
            }
        }
        return out
    }

    private static func semanticKind(
        for line: TextLine,
        blockKind: LayoutBlockKind,
        regionKind: LayoutRegionKind,
        baseline: CGFloat,
        headingLevels: [(height: CGFloat, level: Int)]
    ) -> SourceParagraphKind {
        if blockKind == .title || regionKind == .title { return .heading(level: 1) }
        if blockKind == .listItem || regionKind == .list {
            return .listItem(marker: ParagraphListMarkerParser.splitLeadingMarker(in: line.text)?.marker ?? "")
        }
        if line.bbox.height >= baseline * 1.3 {
            let closest = headingLevels.min { abs($0.height - line.bbox.height) < abs($1.height - line.bbox.height) }
            return .heading(level: closest?.level ?? 1)
        }
        if line.bbox.minY <= 0.12,
           line.bbox.height <= baseline * 0.85,
           hasFootnotePrefix(line.text) {
            return .footnote
        }
        return .body
    }

    private static func hasFootnotePrefix(_ text: String) -> Bool {
        guard let character = text.first, let scalar = character.unicodeScalars.first else { return false }
        if scalar.properties.numericType != nil { return true }
        switch scalar.properties.generalCategory {
        case .mathSymbol, .otherSymbol, .modifierSymbol, .otherPunctuation:
            return true
        default:
            return false
        }
    }

    private static func documentBodyLineHeight(in lines: [TextLine]) -> CGFloat {
        let heights = lines.map { max($0.bbox.height, 0.001) }.sorted()
        guard !heights.isEmpty else { return 0.03 }
        // 标题通常是少数大字号；中位数是保守的文档正文基线。
        return median(heights)
    }

    private static func documentHeadingLevels(in lines: [TextLine], baseline: CGFloat) -> [(height: CGFloat, level: Int)] {
        let candidates = lines.map(\.bbox.height).filter { $0 >= baseline * 1.3 }.sorted(by: >)
        var clusters: [CGFloat] = []
        for height in candidates where !clusters.contains(where: { abs($0 - height) <= max($0, height) * 0.1 }) {
            clusters.append(height)
        }
        return clusters.prefix(3).enumerated().map { (height: $0.element, level: $0.offset + 1) }
    }

    private static func verticalGaps(
        in lines: [TextLine],
        regionKind: LayoutRegionKind,
        baseline: CGFloat,
        headingLevels: [(height: CGFloat, level: Int)]
    ) -> [CGFloat] {
        guard lines.count > 1 else { return [] }
        return zip(lines, lines.dropFirst()).compactMap { previous, next in
            guard previous.pageIndex == next.pageIndex,
                  semanticKind(for: previous, blockKind: .text, regionKind: regionKind, baseline: baseline, headingLevels: headingLevels) == .body,
                  semanticKind(for: next, blockKind: .text, regionKind: regionKind, baseline: baseline, headingLevels: headingLevels) == .body,
                  !isSameVisualLineContinuation(previous: previous.bbox, next: next.bbox) else { return nil }
            return max(previous.bbox.minY - next.bbox.maxY, 0)
        }
    }

    /// 双峰成立时返回两簇中位数中点；nil 表示沿用 0.6 × 行高规则。
    static func adaptiveGapThreshold(for gaps: [CGFloat]) -> CGFloat? {
        guard gaps.count >= 6 else { return nil }
        let values = gaps.sorted()
        guard values.count >= 4 else { return nil }
        var bestIndex = 0
        var largestJump: CGFloat = -.greatestFiniteMagnitude
        for index in 0..<(values.count - 1) {
            let jump = values[index + 1] - values[index]
            if jump > largestJump {
                largestJump = jump
                bestIndex = index
            }
        }
        let low = Array(values[...bestIndex])
        let high = Array(values[(bestIndex + 1)...])
        guard low.count >= 2, high.count >= 2 else { return nil }
        let lowMedian = median(low)
        let highMedian = median(high)
        guard (lowMedian == 0 ? highMedian > 0 : highMedian / lowMedian >= 1.5) else { return nil }
        return (lowMedian + highMedian) / 2
    }

    private static func modalEdge(_ values: [CGFloat], tolerance: CGFloat) -> CGFloat? {
        guard !values.isEmpty else { return nil }
        var best: [CGFloat] = []
        for candidate in values {
            let group = values.filter { abs($0 - candidate) <= tolerance }
            if group.count > best.count { best = group }
        }
        return best.count >= 2 ? median(best) : nil
    }

    private static func median(_ values: [CGFloat]) -> CGFloat {
        let sorted = values.sorted()
        guard !sorted.isEmpty else { return 0 }
        let middle = sorted.count / 2
        return sorted.count.isMultiple(of: 2) ? (sorted[middle - 1] + sorted[middle]) / 2 : sorted[middle]
    }

    private static func isContinuation(_ character: Character) -> Bool {
        character.isLowercase || character.unicodeScalars.first.map { (0x4E00...0x9FFF).contains($0.value) } ?? false
    }

    static func isNextLineContinuation(previous: CGRect, next: CGRect, gapThreshold: CGFloat? = nil) -> Bool {
        let gap = previous.minY - next.maxY
        let overlaps = max(previous.minX, next.minX) < min(previous.maxX, next.maxX)
        return gap <= (gapThreshold ?? next.height * 0.6) && overlaps
    }

    static func isSameVisualLineContinuation(previous: CGRect, next: CGRect) -> Bool {
        let verticalOverlap = min(previous.maxY, next.maxY) - max(previous.minY, next.minY)
        let requiredOverlap = min(previous.height, next.height) * 0.5
        let horizontalGap = next.minX - previous.maxX
        return verticalOverlap >= requiredOverlap && horizontalGap >= 0 && horizontalGap <= next.height * 2
    }

    static func join(_ first: String, _ second: String) -> String {
        if first.hasSuffix("-") { return String(first.dropLast()) + second }
        let firstCJK = first.last.map(isCJK) ?? false
        let secondCJK = second.first.map(isCJK) ?? false
        return (firstCJK && secondCJK) ? first + second : first + " " + second
    }

    public static func isCJK(_ character: Character) -> Bool {
        guard let scalar = character.unicodeScalars.first else { return false }
        return (0x2E80...0x9FFF).contains(scalar.value) || (0xFF00...0xFFEF).contains(scalar.value)
    }
}
