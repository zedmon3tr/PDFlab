/// 进度比例同步的纯数学(两侧类型不同或页数不等时使用)。
/// 两侧均为 PDF 且页数相同时,App 层(DualPaneController)直接用 PDFKit 页面几何做页锚点同步,
/// 不再经过"均匀页高"的全局进度折算——原 `pageAnchored(page:inPage:pageCount:)` 因此废弃移除。
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

    private static func safeRatio(_ value: Double) -> Double {
        value.isFinite && value > 0 ? value : 1
    }

    private static func clamp01(_ value: Double) -> Double {
        guard value.isFinite else { return 0 }
        return min(max(value, 0), 1)
    }
}
