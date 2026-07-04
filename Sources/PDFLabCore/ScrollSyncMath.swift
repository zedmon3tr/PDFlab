public struct ScrollSyncMath: Sendable {
    public let ratioA: Double
    public let ratioB: Double

    public init(ratioA: Double, ratioB: Double) {
        self.ratioA = Self.safeRatio(ratioA)
        self.ratioB = Self.safeRatio(ratioB)
    }

    public func targetProgress(fromA progressA: Double) -> Double {
        Self.clamp01(progressA * (ratioA / ratioB))
    }

    public func targetProgress(fromB progressB: Double) -> Double {
        Self.clamp01(progressB * (ratioB / ratioA))
    }

    public static func pageAnchored(page: Int, inPage: Double, pageCount: Int) -> Double {
        guard pageCount > 0 else { return 0 }
        let clampedPage = max(0, min(page, pageCount - 1))
        return clamp01((Double(clampedPage) + clamp01(inPage)) / Double(pageCount))
    }

    private static func safeRatio(_ value: Double) -> Double {
        value.isFinite && value > 0 ? value : 1
    }

    private static func clamp01(_ value: Double) -> Double {
        guard value.isFinite else { return 0 }
        return min(max(value, 0), 1)
    }
}
