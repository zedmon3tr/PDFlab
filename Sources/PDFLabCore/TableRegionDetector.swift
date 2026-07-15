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
            let numericPageColumn = hasMonotonicRightPageNumbers(run)
            let directorySignals = hasDirectoryTitle || hasLeaderRows(run)
            guard stableGrid(run), !looksLikeFullPageProseColumns(run), !(numericPageColumn && directorySignals) else {
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
        let rowSteps = zip(rows, rows.dropFirst()).map {
            $0.0.lines[0].bbox.midY - $0.1.lines[0].bbox.midY
        }
        guard let minimumStep = rowSteps.min(), let maximumStep = rowSteps.max(), minimumStep > 0,
              maximumStep / minimumStep <= 1.35,
              maximumStep <= medianHeight(of: rows.flatMap(\.lines)) * 4.5 else { return false }
        for row in rows {
            for (left, right) in zip(row.lines, row.lines.dropFirst()) {
                let gap = right.bbox.minX - left.bbox.maxX
                let cellWidth = max(min(left.bbox.width, right.bbox.width), 0.001)
                guard gap / cellWidth >= 0.2, gap / cellWidth <= 4 else { return false }
            }
        }
        return true
    }

    private static func looksLikeFullPageProseColumns(_ rows: [VisualRow]) -> Bool {
        guard rows.count >= 6 else { return false }
        let lines = rows.flatMap(\.lines)
        let bounds = lines.map(\.bbox).reduce(CGRect.null) { $0.union($1) }
        let lengths = lines.map { $0.text.count }.sorted()
        let medianLength = lengths[lengths.count / 2]
        let widths = lines.map(\.bbox.width).sorted()
        let medianWidth = widths[widths.count / 2]
        let first = rows[0].lines
        let pitches = zip(first, first.dropFirst()).map { $0.1.bbox.minX - $0.0.bbox.minX }.sorted()
        let medianPitch = pitches[pitches.count / 2]
        return bounds.height >= 0.45 && medianLength >= 24 && medianWidth / max(medianPitch, 0.001) >= 0.72
    }

    private static func hasLeaderRows(_ rows: [VisualRow]) -> Bool {
        let count = rows.filter { row in row.lines.contains { isLeader($0.text) } }.count
        return count * 4 >= rows.count * 3
    }

    private static func isLeader(_ text: String) -> Bool {
        let marks = text.filter { ".·…_-—".contains($0) }
        return marks.count >= 3 && marks.count * 2 >= text.filter { !$0.isWhitespace }.count
    }

    private static func hasMonotonicRightPageNumbers(_ rows: [VisualRow]) -> Bool {
        let numbers = rows.compactMap { row -> Int? in
            guard let text = row.lines.last?.text.trimmingCharacters(in: .whitespacesAndNewlines),
                  !text.isEmpty, text.allSatisfy(\.isNumber) else { return nil }
            return Int(text)
        }
        guard numbers.count * 4 >= rows.count * 3, numbers.count >= 3 else { return false }
        return zip(numbers, numbers.dropFirst()).allSatisfy { $0.1 >= $0.0 }
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
                    let rawCells = block.tableCells.isEmpty
                        ? block.lines.sorted { $0.bbox.minX < $1.bbox.minX }
                            .enumerated().map { LayoutTableCell(columnIndex: $0.offset, lines: [$0.element]) }
                        : block.tableCells.sorted { $0.columnIndex < $1.columnIndex }
                    let grouped = Dictionary(grouping: rawCells.filter { $0.columnIndex >= 0 }, by: \.columnIndex)
                    guard let lastColumn = grouped.keys.max() else { return nil }
                    let cells = (0...lastColumn).map { columnIndex in
                        LayoutTableCell(
                            columnIndex: columnIndex,
                            lines: (grouped[columnIndex] ?? []).flatMap(\.lines)
                        )
                    }
                    let text = cells.map { cell in
                        cell.lines.reduce("") { text, line in
                            text.isEmpty ? line.text : ParagraphBuilder.join(text, line.text)
                        }
                    }.joined(separator: "\t")
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
