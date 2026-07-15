import CoreGraphics

/// TextLine 几何上的保守表格检测。只接受至少 3x3、列左缘稳定且行高一致的片段网格；
/// 证据不足时返回空，调用方保持原正文布局。
enum TableRegionDetector {
    struct Detection: Equatable {
        var rows: [[Int]]
    }

    private struct VisualRow {
        var indices: [Int]
        var lines: [TextLine]
    }

    static func detect(in lines: [TextLine]) -> [Detection] {
        let bands = visualRows(in: lines)
        var runs: [[VisualRow]] = []
        var current: [VisualRow] = []
        for band in bands {
            guard isSeparatedRow(band) else {
                if current.count >= 3 { runs.append(current) }
                current.removeAll(keepingCapacity: true)
                continue
            }
            if let previous = current.last,
               previous.lines[0].bbox.midY - band.lines[0].bbox.midY > medianHeight(of: previous.lines) * 3 {
                if current.count >= 3 { runs.append(current) }
                current.removeAll(keepingCapacity: true)
            }
            current.append(band)
        }
        if current.count >= 3 { runs.append(current) }

        let hasDirectoryTitle = lines.contains { line in
            let key = line.text.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
            return line.bbox.midY >= 0.75 && ["contents", "table of contents", "目录", "目錄", "index", "索引"].contains(key)
        }
        return runs.compactMap { run in
            guard stableGrid(run), !(hasDirectoryTitle && hasLeaderRows(run) && hasContinuousRightPageNumbers(run)) else {
                return nil
            }
            return Detection(rows: run.map(\.indices))
        }
    }

    private static func visualRows(in lines: [TextLine]) -> [VisualRow] {
        let ordered = lines.indices.sorted {
            if lines[$0].bbox.midY != lines[$1].bbox.midY { return lines[$0].bbox.midY > lines[$1].bbox.midY }
            return lines[$0].bbox.minX < lines[$1].bbox.minX
        }
        var rows: [VisualRow] = []
        for index in ordered {
            let line = lines[index]
            if let anchor = rows.last?.lines.first,
               abs(anchor.bbox.midY - line.bbox.midY) <= min(anchor.bbox.height, line.bbox.height) * 0.5 {
                rows[rows.count - 1].indices.append(index)
                rows[rows.count - 1].lines.append(line)
            } else {
                rows.append(VisualRow(indices: [index], lines: [line]))
            }
        }
        return rows.map { row in
            let sorted = zip(row.indices, row.lines).sorted { $0.1.bbox.minX < $1.1.bbox.minX }
            return VisualRow(indices: sorted.map(\.0), lines: sorted.map(\.1))
        }
    }

    private static func isSeparatedRow(_ row: VisualRow) -> Bool {
        guard row.lines.count >= 3 else { return false }
        let height = medianHeight(of: row.lines)
        return zip(row.lines, row.lines.dropFirst()).allSatisfy { next in
            next.1.bbox.minX - next.0.bbox.maxX >= max(height, 0.008)
        }
    }

    private static func stableGrid(_ rows: [VisualRow]) -> Bool {
        guard rows.count >= 3, let first = rows.first, first.lines.count >= 3,
              rows.allSatisfy({ $0.lines.count == first.lines.count }) else { return false }
        let heights = rows.flatMap { $0.lines.map(\.bbox.height) }
        guard let minimum = heights.min(), let maximum = heights.max(), minimum > 0,
              maximum / minimum <= 1.25 else { return false }
        let tolerance = max(medianHeight(of: rows.flatMap(\.lines)), 0.015)
        for column in first.lines.indices {
            let anchors = rows.map { $0.lines[column].bbox.minX }
            guard (anchors.max() ?? 0) - (anchors.min() ?? 0) <= tolerance else { return false }
        }
        return true
    }

    private static func hasLeaderRows(_ rows: [VisualRow]) -> Bool {
        let count = rows.filter { row in row.lines.contains { isLeader($0.text) } }.count
        return count * 4 >= rows.count * 3
    }

    private static func isLeader(_ text: String) -> Bool {
        let marks = text.filter { ".·…_-—".contains($0) }
        return marks.count >= 3 && marks.count * 2 >= text.filter { !$0.isWhitespace }.count
    }

    private static func hasContinuousRightPageNumbers(_ rows: [VisualRow]) -> Bool {
        let numbers = rows.compactMap { row -> Int? in
            guard let text = row.lines.last?.text.trimmingCharacters(in: .whitespacesAndNewlines),
                  !text.isEmpty, text.allSatisfy(\.isNumber) else { return nil }
            return Int(text)
        }
        guard numbers.count * 4 >= rows.count * 3, numbers.count >= 3 else { return false }
        return zip(numbers, numbers.dropFirst()).allSatisfy { $0.1 == $0.0 + 1 }
    }

    private static func medianHeight(of lines: [TextLine]) -> CGFloat {
        let values = lines.map { max($0.bbox.height, 0.001) }.sorted()
        guard !values.isEmpty else { return 0.001 }
        let middle = values.count / 2
        return values.count.isMultiple(of: 2) ? (values[middle - 1] + values[middle]) / 2 : values[middle]
    }
}

enum ParsedBlockBuilder {
    static func build(from layouts: [PageLayout]) -> [ParsedBlock] {
        let paragraphs = ParagraphBuilder.mergeAcrossPages(ParagraphBuilder.buildParagraphs(from: layouts))
        var ordinalByBlockID: [LayoutBlockID: Int] = [:]
        var nextOrdinal = 0
        var tables: [SourceTableRegion] = []

        for layout in layouts {
            for region in layout.regions {
                for block in region.blocks {
                    ordinalByBlockID[block.id] = nextOrdinal
                    nextOrdinal += 1
                }
                guard region.kind == .table else { continue }
                let rows = region.blocks.compactMap { block -> SourceTableRow? in
                    let text = block.lines.sorted { $0.bbox.minX < $1.bbox.minX }
                        .map(\.text).joined(separator: "\t")
                    guard !text.isEmpty else { return nil }
                    let id = TranslationUnitID("table-row:\(block.id.rawValue)")
                    return SourceTableRow(translationUnitID: id, text: text)
                }
                guard !rows.isEmpty else { continue }
                tables.append(SourceTableRegion(
                    translationUnitID: .init("table:\(region.id)"),
                    pageIndex: layout.pageIndex,
                    sourceBlockIDs: region.blocks.map(\.id),
                    rows: rows
                ))
            }
        }

        let blocks = paragraphs.map(ParsedBlock.paragraph) + tables.map(ParsedBlock.table)
        return blocks.enumerated().sorted { lhs, rhs in
            let lhsOrdinal = firstOrdinal(of: lhs.element, in: ordinalByBlockID)
            let rhsOrdinal = firstOrdinal(of: rhs.element, in: ordinalByBlockID)
            return lhsOrdinal == rhsOrdinal ? lhs.offset < rhs.offset : lhsOrdinal < rhsOrdinal
        }.map(\.element)
    }

    private static func firstOrdinal(of block: ParsedBlock, in ordinals: [LayoutBlockID: Int]) -> Int {
        let ids: [LayoutBlockID]
        switch block {
        case .paragraph(let paragraph): ids = paragraph.sourceBlockIDs
        case .table(let table): ids = table.sourceBlockIDs
        }
        return ids.compactMap { ordinals[$0] }.min() ?? Int.max
    }
}
