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

        if let cut = largestVerticalCut(in: lines, minimumGap: max(0.018, medianHeight * 1.35)) {
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
