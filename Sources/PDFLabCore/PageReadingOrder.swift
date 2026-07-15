import CoreGraphics

/// Conservative recursive whitespace ordering for visual text lines.
/// Horizontal whitespace creates top-to-bottom zones; vertical whitespace inside
/// a zone creates left-to-right columns. If neither cut is well supported, the
/// original visual bands are kept instead of guessing a column layout.
enum PageReadingOrder {
    static func order(_ lines: [TextLine]) -> [TextLine] {
        guard lines.count > 1 else { return lines }
        return recursiveOrder(lines, depth: 0)
    }

    static func layout(
        _ lines: [TextLine],
        pageIndex: Int,
        orderedLines: [TextLine]? = nil,
        tableCandidates: [TextLine]? = nil
    ) -> PageLayout {
        let detectionLines = tableCandidates ?? lines
        let tableDetections = TableRegionDetector.detect(in: detectionLines)
        let tableIndexes = Set(tableDetections.flatMap { $0.rows.flatMap { $0 } })
        let tableBounds = tableDetections.map { detection in
            detection.rows.flatMap { $0 }.map { detectionLines[$0].bbox }
                .reduce(CGRect.null) { $0.union($1) }.standardized
        }
        let bodyLines: [TextLine]
        if tableCandidates == nil {
            bodyLines = lines.indices.filter { !tableIndexes.contains($0) }.map { lines[$0] }
        } else {
            bodyLines = lines.filter { line in
                !tableBounds.contains { bounds in overlapRatio(line.bbox, bounds) >= 0.98 }
            }
        }
        let groups = tableBounds.reduce(recursiveRegions(bodyLines, depth: 0)) { groups, tableBounds in
            groups.flatMap { group -> [[TextLine]] in
                let above = group.filter { $0.bbox.minY >= tableBounds.maxY }
                let below = group.filter { $0.bbox.maxY <= tableBounds.minY }
                let alongside = group.filter { !above.contains($0) && !below.contains($0) }
                guard alongside.isEmpty, !above.isEmpty, !below.isEmpty else { return [group] }
                return [above, below]
            }
        }
        var regions = groups.enumerated().map { index, group in
            let ordered = orderByBands(group)
            let blockID = LayoutBlockID("p\(pageIndex)-r\(index)-b0")
            let kind = regionKind(for: ordered)
            return LayoutRegion(
                id: "p\(pageIndex)-r\(index)",
                kind: kind,
                source: .heuristic,
                blocks: [LayoutBlock(id: blockID, kind: .text, lines: ordered)]
            )
        }
        let tableRegions = tableDetections.enumerated().map { tableIndex, detection in
            let blocks = detection.rows.enumerated().map { rowIndex, indexes in
                let cells = indexes.map { detectionLines[$0] }.sorted { $0.bbox.minX < $1.bbox.minX }
                return LayoutBlock(
                    id: .init("p\(pageIndex)-table\(tableIndex)-row\(rowIndex)"),
                    kind: .tableRow,
                    lines: cells,
                    tableCells: cells.enumerated().map { .init(columnIndex: $0.offset, lines: [$0.element]) }
                )
            }
            return LayoutRegion(
                id: "p\(pageIndex)-table\(tableIndex)", kind: .table, source: .heuristic, blocks: blocks
            )
        }
        for table in tableRegions.sorted(by: { $0.bbox.maxY > $1.bbox.maxY }) {
            let insertion = regions.firstIndex { table.bbox.minY >= $0.bbox.maxY } ?? regions.endIndex
            regions.insert(table, at: insertion)
        }
        let projection = orderedLines ?? (tableCandidates == nil ? order(lines) : regions.flatMap(\.flattenedLines))
        return PageLayout(pageIndex: pageIndex, regions: regions, orderedLines: projection)
    }

    private static func overlapRatio(_ lhs: CGRect, _ rhs: CGRect) -> CGFloat {
        let intersection = lhs.intersection(rhs)
        guard !intersection.isNull, lhs.width > 0, lhs.height > 0 else { return 0 }
        return intersection.width * intersection.height / (lhs.width * lhs.height)
    }

    private static func recursiveRegions(_ lines: [TextLine], depth: Int) -> [[TextLine]] {
        guard !lines.isEmpty else { return [] }
        guard lines.count > 1, depth < 12 else { return [lines] }
        let medianHeight = median(lines.map { max($0.bbox.height, 0.001) })

        if let cut = largestHorizontalCut(in: lines, minimumGap: medianHeight * 1.15) {
            let upper = lines.filter { $0.bbox.midY > cut }
            let lower = lines.filter { $0.bbox.midY <= cut }
            if !upper.isEmpty, !lower.isEmpty {
                return recursiveRegions(upper, depth: depth + 1) + recursiveRegions(lower, depth: depth + 1)
            }
        }
        let minimumVerticalGap = max(0.018, medianHeight * 1.35)
        if let cut = largestVerticalCut(in: lines, minimumGap: minimumVerticalGap)
            ?? supportedRowVerticalCut(in: lines, minimumGap: minimumVerticalGap, medianHeight: medianHeight) {
            let left = lines.filter { $0.bbox.midX < cut }
            let right = lines.filter { $0.bbox.midX >= cut }
            if isSupportedColumnSplit(left: left, right: right) {
                return recursiveRegions(left, depth: depth + 1) + recursiveRegions(right, depth: depth + 1)
            }
        }
        return [lines]
    }

    private static func regionKind(for lines: [TextLine]) -> LayoutRegionKind {
        guard !lines.isEmpty else { return .body }
        if lines.allSatisfy({ $0.bbox.maxY >= 0.95 }) { return .header }
        if lines.allSatisfy({ $0.bbox.minY <= 0.08 }) { return .footer }
        return .body
    }

    private static func recursiveOrder(_ lines: [TextLine], depth: Int) -> [TextLine] {
        guard lines.count > 1, depth < 12 else { return orderByBands(lines) }
        let medianHeight = median(lines.map { max($0.bbox.height, 0.001) })
        if let cut = largestHorizontalCut(in: lines, minimumGap: medianHeight * 1.15) {
            let upper = lines.filter { $0.bbox.midY > cut }
            let lower = lines.filter { $0.bbox.midY <= cut }
            if !upper.isEmpty, !lower.isEmpty {
                return recursiveOrder(upper, depth: depth + 1) + recursiveOrder(lower, depth: depth + 1)
            }
        }
        let minimumVerticalGap = max(0.018, medianHeight * 1.35)
        if let cut = largestVerticalCut(in: lines, minimumGap: minimumVerticalGap)
            ?? supportedRowVerticalCut(in: lines, minimumGap: minimumVerticalGap, medianHeight: medianHeight) {
            let left = lines.filter { $0.bbox.midX < cut }
            let right = lines.filter { $0.bbox.midX >= cut }
            if isSupportedColumnSplit(left: left, right: right) {
                return recursiveOrder(left, depth: depth + 1) + recursiveOrder(right, depth: depth + 1)
            }
        }
        return orderByBands(lines)
    }

    private static func largestHorizontalCut(in lines: [TextLine], minimumGap: CGFloat) -> CGFloat? {
        let intervals = lines.map { (min: $0.bbox.minY, max: $0.bbox.maxY) }
        let allGaps = whitespaceGaps(in: intervals)
        guard let largest = allGaps.filter({ $0.size >= minimumGap }).max(by: { $0.size < $1.size }),
              let smallest = allGaps.map(\.size).min(),
              largest.size >= smallest * 1.8 else { return nil }
        return largest.midpoint
    }

    private static func largestVerticalCut(in lines: [TextLine], minimumGap: CGFloat) -> CGFloat? {
        largestGap(
            in: lines.map { (min: $0.bbox.minX, max: $0.bbox.maxX) },
            minimumGap: minimumGap
        )
    }

    /// Finds a gutter repeated across several visual rows even when a small
    /// number of lower-page notes intrude into the otherwise empty corridor.
    private static func supportedRowVerticalCut(
        in lines: [TextLine],
        minimumGap: CGFloat,
        medianHeight: CGFloat
    ) -> CGFloat? {
        struct Evidence {
            var midpoint: CGFloat
            var row: CGFloat
        }
        var evidence: [Evidence] = []
        for left in lines {
            for right in lines where left.bbox.maxX < right.bbox.minX {
                let rowDistance = abs(left.bbox.midY - right.bbox.midY)
                guard rowDistance <= max(left.bbox.height, right.bbox.height),
                      right.bbox.minX - left.bbox.maxX >= minimumGap else { continue }
                evidence.append(Evidence(
                    midpoint: (left.bbox.maxX + right.bbox.minX) / 2,
                    row: (left.bbox.midY + right.bbox.midY) / 2
                ))
            }
        }
        guard evidence.count >= 3 else { return nil }

        var clusters: [[Evidence]] = []
        for item in evidence.sorted(by: { $0.midpoint < $1.midpoint }) {
            if let last = clusters.indices.last,
               item.midpoint - (clusters[last].last?.midpoint ?? item.midpoint) <= medianHeight {
                clusters[last].append(item)
            } else {
                clusters.append([item])
            }
        }
        let supported = clusters.filter { cluster in
            var rows: [CGFloat] = []
            for row in cluster.map(\.row).sorted() where rows.last.map({ row - $0 > medianHeight * 0.5 }) ?? true {
                rows.append(row)
            }
            return rows.count >= 3
        }
        guard let best = supported.max(by: { $0.count < $1.count }) else { return nil }
        return median(best.map(\.midpoint))
    }

    private static func largestGap(
        in intervals: [(min: CGFloat, max: CGFloat)],
        minimumGap: CGFloat
    ) -> CGFloat? {
        let sorted = intervals.sorted { $0.min < $1.min }
        guard var occupiedMax = sorted.first?.max else { return nil }
        var best: (midpoint: CGFloat, size: CGFloat)?
        for interval in sorted.dropFirst() {
            let gap = interval.min - occupiedMax
            if gap >= minimumGap, gap > (best?.size ?? 0) {
                best = ((occupiedMax + interval.min) / 2, gap)
            }
            occupiedMax = max(occupiedMax, interval.max)
        }
        return best?.midpoint
    }

    private static func whitespaceGaps(
        in intervals: [(min: CGFloat, max: CGFloat)]
    ) -> [(midpoint: CGFloat, size: CGFloat)] {
        let sorted = intervals.sorted { $0.min < $1.min }
        guard var occupiedMax = sorted.first?.max else { return [] }
        var gaps: [(midpoint: CGFloat, size: CGFloat)] = []
        for interval in sorted.dropFirst() {
            let size = interval.min - occupiedMax
            if size > 0 { gaps.append(((occupiedMax + interval.min) / 2, size)) }
            occupiedMax = max(occupiedMax, interval.max)
        }
        return gaps
    }

    private static func isSupportedColumnSplit(left: [TextLine], right: [TextLine]) -> Bool {
        guard !left.isEmpty, !right.isEmpty else { return false }
        guard min(left.count, right.count) >= 2 else { return false }

        let leftRange = (min: left.map(\.bbox.minY).min() ?? 0, max: left.map(\.bbox.maxY).max() ?? 0)
        let rightRange = (min: right.map(\.bbox.minY).min() ?? 0, max: right.map(\.bbox.maxY).max() ?? 0)
        guard min(leftRange.max, rightRange.max) > max(leftRange.min, rightRange.min) else { return false }
        let pairedRows = left.filter { leftLine in
            right.contains { rightLine in
                abs(leftLine.bbox.midY - rightLine.bbox.midY) <= max(leftLine.bbox.height, rightLine.bbox.height)
            }
        }
        return pairedRows.count >= 2
    }

    private static func orderByBands(_ lines: [TextLine]) -> [TextLine] {
        let byY = lines.sorted { a, b in
            if a.bbox.midY != b.bbox.midY { return a.bbox.midY > b.bbox.midY }
            if a.bbox.minX != b.bbox.minX { return a.bbox.minX < b.bbox.minX }
            return a.text < b.text
        }
        var bands: [[TextLine]] = []
        for line in byY {
            if let anchor = bands.last?.first,
               abs(anchor.bbox.midY - line.bbox.midY) <= max(anchor.bbox.height, line.bbox.height) * 0.5 {
                bands[bands.count - 1].append(line)
            } else {
                bands.append([line])
            }
        }
        return bands.flatMap { band in
            band.sorted { a, b in
                if a.bbox.minX != b.bbox.minX { return a.bbox.minX < b.bbox.minX }
                return a.text < b.text
            }
        }
    }

    private static func median(_ values: [CGFloat]) -> CGFloat {
        let sorted = values.sorted()
        guard !sorted.isEmpty else { return 0 }
        let middle = sorted.count / 2
        if sorted.count.isMultiple(of: 2) {
            return (sorted[middle - 1] + sorted[middle]) / 2
        }
        return sorted[middle]
    }
}
