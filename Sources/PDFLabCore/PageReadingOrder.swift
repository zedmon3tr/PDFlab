import CoreGraphics

/// Conservative recursive whitespace ordering for visual text lines.
/// Horizontal whitespace creates top-to-bottom zones; vertical whitespace inside
/// a zone creates left-to-right columns. If neither cut is well supported, the
/// original visual bands are kept instead of guessing a column layout.
enum PageReadingOrder {
    static func order(_ lines: [TextLine]) -> [TextLine] {
        recursiveRegions(lines, depth: 0).flatMap(orderByBands)
    }

    static func layout(_ lines: [TextLine], pageIndex: Int) -> PageLayout {
        let groups = recursiveRegions(lines, depth: 0)
        let regions = groups.enumerated().map { index, group in
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
        return PageLayout(pageIndex: pageIndex, regions: regions)
    }

    private static func recursiveRegions(_ lines: [TextLine], depth: Int) -> [[TextLine]] {
        guard !lines.isEmpty else { return [] }
        guard lines.count > 1, depth < 12 else { return [lines] }
        let medianHeight = median(lines.map { max($0.bbox.height, 0.001) })

        let headers = lines.filter { $0.bbox.maxY >= 0.95 }
        if !headers.isEmpty, headers.count < lines.count {
            let body = lines.filter { $0.bbox.maxY < 0.95 }
            return recursiveRegions(headers, depth: depth + 1) + recursiveRegions(body, depth: depth + 1)
        }
        let footers = lines.filter { $0.bbox.minY <= 0.08 }
        if !footers.isEmpty, footers.count < lines.count {
            let body = lines.filter { $0.bbox.minY > 0.08 }
            return recursiveRegions(body, depth: depth + 1) + recursiveRegions(footers, depth: depth + 1)
        }

        if let cut = changedLayoutHorizontalCut(in: lines) {
            let upper = lines.filter { $0.bbox.midY > cut }
            let lower = lines.filter { $0.bbox.midY <= cut }
            return recursiveRegions(upper, depth: depth + 1) + recursiveRegions(lower, depth: depth + 1)
        }

        if let cut = largestVerticalCut(in: lines, minimumGap: max(0.008, medianHeight * 0.5)) {
            let left = lines.filter { $0.bbox.midX < cut }
            let right = lines.filter { $0.bbox.midX >= cut }
            if isSupportedColumnSplit(left: left, right: right) {
                return recursiveRegions(left, depth: depth + 1) + recursiveRegions(right, depth: depth + 1)
            }
        }

        if let cut = largestHorizontalCut(in: lines, minimumGap: medianHeight * 1.15) {
            let upper = lines.filter { $0.bbox.midY > cut }
            let lower = lines.filter { $0.bbox.midY <= cut }
            if !upper.isEmpty, !lower.isEmpty {
                return recursiveRegions(upper, depth: depth + 1) + recursiveRegions(lower, depth: depth + 1)
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

    /// Finds a conservative transition from narrow side-by-side columns to a
    /// substantially wider lower text zone. This is only used when several
    /// distinct upper-column left edges support the layout change.
    private static func changedLayoutHorizontalCut(in lines: [TextLine]) -> CGFloat? {
        guard lines.count >= 8 else { return nil }
        let medianWidth = median(lines.map { max($0.bbox.width, 0.001) })
        let sortedByY = lines.sorted { $0.bbox.midY > $1.bbox.midY }
        for (index, line) in sortedByY.enumerated() where index >= 4 && index < sortedByY.count - 1 {
            guard line.bbox.width >= medianWidth * 1.3 else { continue }
            let upper = Array(sortedByY[..<index])
            let leftEdges = upper.map(\.bbox.minX).sorted()
            let distinctGaps = zip(leftEdges, leftEdges.dropFirst()).filter { $1 - $0 >= 0.08 }.count
            guard distinctGaps >= 2 else { continue }
            let upperBottom = upper.map(\.bbox.minY).min() ?? line.bbox.maxY
            guard upperBottom > line.bbox.maxY else { continue }
            return (upperBottom + line.bbox.maxY) / 2
        }
        return nil
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
