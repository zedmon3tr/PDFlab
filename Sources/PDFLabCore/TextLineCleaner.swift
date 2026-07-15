import Foundation

public struct TextCleanupSummary: Equatable, Sendable {
    public var repeatedEdgeLines: Int
    public var pageNumbers: Int
    public var ocrJunkLines: Int
    public var tableRegions: Int

    public init(repeatedEdgeLines: Int = 0, pageNumbers: Int = 0, ocrJunkLines: Int = 0, tableRegions: Int = 0) {
        self.repeatedEdgeLines = repeatedEdgeLines
        self.pageNumbers = pageNumbers
        self.ocrJunkLines = ocrJunkLines
        self.tableRegions = tableRegions
    }

    public var hasFilteredLines: Bool {
        repeatedEdgeLines + pageNumbers + ocrJunkLines + tableRegions > 0
    }

    public var removedLineCount: Int { repeatedEdgeLines + pageNumbers + ocrJunkLines }
}

public struct CleanedTextLines: Equatable, Sendable {
    public var lines: [TextLine]
    public var summary: TextCleanupSummary

    public init(lines: [TextLine], summary: TextCleanupSummary) {
        self.lines = lines
        self.summary = summary
    }
}

public struct CleanedPageLayouts: Equatable, Sendable {
    public var layouts: [PageLayout]
    public var summary: TextCleanupSummary

    public init(layouts: [PageLayout], summary: TextCleanupSummary) {
        self.layouts = layouts
        self.summary = summary
    }
}

/// 聚段前的保守清洗。只移除能从位置与文本/置信度同时确认的非正文行。
public enum TextLineCleaner {
    private struct LineOccurrenceKey: Hashable {
        var text: String
        var pageIndex: Int
        var minX: UInt64
        var minY: UInt64
        var width: UInt64
        var height: UInt64
        var confidence: UInt64?

        init(_ line: TextLine) {
            text = line.text
            pageIndex = line.pageIndex
            minX = Double(line.bbox.minX).bitPattern
            minY = Double(line.bbox.minY).bitPattern
            width = Double(line.bbox.width).bitPattern
            height = Double(line.bbox.height).bitPattern
            confidence = line.confidence?.bitPattern
        }
    }

    public static func clean(_ lines: [TextLine]) -> CleanedTextLines {
        let pages = Dictionary(grouping: lines, by: \.pageIndex)
        let layouts = pages.keys.sorted().map { PageReadingOrder.layout(pages[$0] ?? [], pageIndex: $0) }
        let cleaned = clean(layouts)
        return CleanedTextLines(lines: cleaned.layouts.flatMap(\.flattenedLines), summary: cleaned.summary)
    }

    public static func clean(_ layouts: [PageLayout]) -> CleanedPageLayouts {
        let ordered = layouts.flatMap(\.flattenedLines)
        var occurrenceQueues: [LineOccurrenceKey: [Int]] = [:]
        for (index, line) in ordered.enumerated() {
            occurrenceQueues[LineOccurrenceKey(line), default: []].append(index)
        }
        let tableLineKeys = Set(layouts.flatMap { layout in
            layout.regions.filter { $0.kind == .table }.flatMap(\.flattenedLines).map(LineOccurrenceKey.init)
        })
        // 同值/同框重复无法从值模型反推身份时，连同正文重复项一起豁免；宁可少清理，绝不动表格 cell。
        let protectedTableIndexes = Set(ordered.indices.filter { tableLineKeys.contains(LineOccurrenceKey(ordered[$0])) })
        let pageNumberIndexes = Set(ordered.indices.filter {
            !protectedTableIndexes.contains($0) && isPageNumber(ordered[$0])
        })
        let excludedEdgeIndexes = pageNumberIndexes.union(protectedTableIndexes)
        let repeatedEdgeIndexes = repeatedEdgeLineIndexes(in: ordered, excluding: excludedEdgeIndexes)

        var summary = TextCleanupSummary()
        summary.tableRegions = layouts.reduce(0) { count, layout in
            count + layout.regions.filter { $0.kind == .table }.count
        }
        var removedIndexes = pageNumberIndexes.union(repeatedEdgeIndexes)
        for index in ordered.indices where !protectedTableIndexes.contains(index) && isOCRJunk(ordered[index]) {
            removedIndexes.insert(index)
        }
        var occurrenceCursors: [LineOccurrenceKey: Int] = [:]
        var projectionOffset = 0
        let cleanedLayouts = layouts.map { layout in
            let regions = layout.regions.compactMap { region -> LayoutRegion? in
                let blocks = region.blocks.compactMap { block -> LayoutBlock? in
                    var retained: [TextLine] = []
                    for line in block.lines {
                        let key = LineOccurrenceKey(line)
                        let cursor = occurrenceCursors[key, default: 0]
                        guard let queue = occurrenceQueues[key], cursor < queue.count else {
                            retained.append(line)
                            continue
                        }
                        let lineIndex = queue[cursor]
                        occurrenceCursors[key] = cursor + 1
                        if region.kind == .table || !removedIndexes.contains(lineIndex) { retained.append(line) }
                    }
                    guard !retained.isEmpty else { return nil }
                    let bounds = retained.count == block.lines.count ? block.bbox : nil
                    let retainedCells = block.tableCells.compactMap { cell -> LayoutTableCell? in
                        if cell.lines.isEmpty { return cell }
                        let lines = cell.lines.filter { retained.contains($0) }
                        return lines.isEmpty ? nil : LayoutTableCell(columnIndex: cell.columnIndex, lines: lines)
                    }
                    return LayoutBlock(
                        id: block.id, kind: block.kind, lines: retained, bbox: bounds, tableCells: retainedCells
                    )
                }
                guard !blocks.isEmpty else { return nil }
                return LayoutRegion(id: region.id, kind: region.kind, source: region.source, blocks: blocks, bbox: region.bbox)
            }
            let pageLines = layout.flattenedLines
            let projection = pageLines.enumerated().compactMap { localIndex, line in
                removedIndexes.contains(projectionOffset + localIndex) ? nil : line
            }
            projectionOffset += pageLines.count
            return PageLayout(
                pageIndex: layout.pageIndex,
                rotationDegrees: layout.rotationDegrees,
                regions: regions,
                orderedLines: projection
            )
        }
        summary.pageNumbers = pageNumberIndexes.count
        summary.repeatedEdgeLines = repeatedEdgeIndexes.count
        summary.ocrJunkLines = ordered.indices.filter {
            !protectedTableIndexes.contains($0) && !pageNumberIndexes.contains($0) &&
                !repeatedEdgeIndexes.contains($0) && isOCRJunk(ordered[$0])
        }.count
        return CleanedPageLayouts(layouts: cleanedLayouts, summary: summary)
    }

    private static func repeatedEdgeLineIndexes(in lines: [TextLine], excluding excluded: Set<Int>) -> Set<Int> {
        let candidates = lines.indices.filter { !excluded.contains($0) && edgeBucket(for: lines[$0]) != nil }
        return Set(candidates.filter { index in
            guard let edge = edgeBucket(for: lines[index]), let text = repeatedTextKey(lines[index].text) else { return false }
            let pages = candidates.compactMap { other -> Int? in
                guard edgeBucket(for: lines[other]) == edge,
                      let otherText = repeatedTextKey(lines[other].text),
                      repeatedTextIsSimilar(text, otherText) else { return nil }
                return lines[other].pageIndex
            }
            return Set(pages).count >= 3
        })
    }

    private static func edgeBucket(for line: TextLine) -> String? {
        if line.bbox.maxY >= 0.85 { return "top-\(Int((line.bbox.midY * 10).rounded()))" }
        if line.bbox.minY <= 0.15 { return "bottom-\(Int((line.bbox.midY * 10).rounded()))" }
        return nil
    }

    private static func repeatedTextKey(_ text: String) -> String? {
        let key = text.lowercased().filter { $0.isLetter || $0.isNumber }.filter { !$0.isNumber }
        return key.isEmpty ? nil : key
    }

    private static func repeatedTextIsSimilar(_ lhs: String, _ rhs: String) -> Bool {
        guard lhs.count == rhs.count else { return lhs == rhs }
        return zip(lhs, rhs).filter { $0 != $1 }.count <= 1
    }

    private static func isPageNumber(_ line: TextLine) -> Bool {
        guard edgeBucket(for: line) != nil else { return false }
        let text = line.text.trimmingCharacters(in: .whitespacesAndNewlines)
        if !text.isEmpty && text.allSatisfy(\.isNumber) { return true }
        let lower = text.lowercased()
        if lower.hasPrefix("page "), lower.dropFirst(5).trimmingCharacters(in: .whitespaces).allSatisfy(\.isNumber) { return true }
        if text.hasPrefix("第"), text.hasSuffix("页"), text.dropFirst().dropLast().trimmingCharacters(in: .whitespaces).allSatisfy(\.isNumber) { return true }
        if text.hasPrefix("-"), text.hasSuffix("-"), text.trimmingCharacters(in: CharacterSet(charactersIn: "- ")).allSatisfy(\.isNumber) { return true }
        return isValidRomanNumeral(text)
    }

    private static func isValidRomanNumeral(_ text: String) -> Bool {
        let numeral = text.uppercased()
        let values: [Character: Int] = ["I": 1, "V": 5, "X": 10, "L": 50, "C": 100, "D": 500, "M": 1_000]
        let digits = numeral.compactMap { values[$0] }
        guard !digits.isEmpty, digits.count == numeral.count else { return false }

        let value = digits.enumerated().reduce(0) { total, entry in
            let (index, digit) = entry
            return total + (index + 1 < digits.count && digit < digits[index + 1] ? -digit : digit)
        }
        return canonicalRomanNumeral(value) == numeral
    }

    private static func canonicalRomanNumeral(_ value: Int) -> String {
        var remaining = value
        let symbols: [(Int, String)] = [
            (1_000, "M"), (900, "CM"), (500, "D"), (400, "CD"),
            (100, "C"), (90, "XC"), (50, "L"), (40, "XL"),
            (10, "X"), (9, "IX"), (5, "V"), (4, "IV"), (1, "I")
        ]
        var result = ""
        for (amount, symbol) in symbols {
            while remaining >= amount {
                result += symbol
                remaining -= amount
            }
        }
        return result
    }

    private static func isOCRJunk(_ line: TextLine) -> Bool {
        guard let confidence = line.confidence, confidence < TranslationPipeline.lowConfidenceThreshold else { return false }
        let characters = line.text.filter { !$0.isWhitespace }
        guard !characters.isEmpty, characters.count <= 8 else { return false }
        let symbolCount = characters.count - characters.filter { $0.isLetter || $0.isNumber }.count
        return Double(symbolCount) / Double(characters.count) >= 0.5
    }
}
