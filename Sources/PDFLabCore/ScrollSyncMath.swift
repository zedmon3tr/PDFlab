/// 按屏(视口高度)的同步滚动比例缩放数学(两侧类型不同或页数不等时使用)。
///
/// 语义:纯比例缩放,对"绝对距顶屏数"和"增量屏数"同样适用。
/// 源侧 `screens` 个视口屏 → 目标侧 `screens × 系数` 个视口屏。
/// A 为源时系数为 `ratioB / ratioA`,B 为源时为 `ratioA / ratioB`(互逆)。
/// 100%/100% 时一屏对一屏,无论文档长短——避免"总进度比例"下短文档滚一点长文档冲一大截。
/// 当前 DualPaneView 用绝对映射(距顶屏数 × 系数 = 目标距顶屏数),消除长距离累积漂移。
///
/// 两侧均为 PDF、页数相同且左右比例一致时,App 层(DualPaneView)直接用 PDFKit 页面几何做页锚点同步;
/// 只要左右比例不同,就退回按屏同步以尊重用户手动校准。
public struct ScrollSyncMath: Sendable {
    public let ratioA: Double
    public let ratioB: Double

    public init(ratioA: Double, ratioB: Double) {
        self.ratioA = Self.safeRatio(ratioA)
        self.ratioB = Self.safeRatio(ratioB)
    }

    /// A 侧滚动的屏数 → B 侧应滚动的屏数。
    public func targetScreens(fromA screensA: Double) -> Double {
        Self.finite(screensA * (ratioB / ratioA))
    }

    /// B 侧滚动的屏数 → A 侧应滚动的屏数。
    public func targetScreens(fromB screensB: Double) -> Double {
        Self.finite(screensB * (ratioA / ratioB))
    }

    public func usesPageAnchoredSync(sourcePageCount: Int?, targetPageCount: Int?) -> Bool {
        guard let sourcePageCount,
              let targetPageCount,
              sourcePageCount > 0,
              sourcePageCount == targetPageCount else { return false }
        return abs(ratioA - ratioB) < 1e-9
    }

    /// 将 AppKit 原始 y 偏移转换为"视觉上距顶部"的偏移。
    public static func visualOffsetFromTop(rawOffset: Double, maxOffset: Double, isFlipped: Bool) -> Double {
        let maxOffset = max(Self.finite(maxOffset), 0)
        let rawOffset = min(max(Self.finite(rawOffset), 0), maxOffset)
        return isFlipped ? rawOffset : maxOffset - rawOffset
    }

    /// 将"视觉上距顶部"的偏移转换回 AppKit 原始 y 偏移。
    public static func rawOffset(fromVisualOffset visualOffset: Double, maxOffset: Double, isFlipped: Bool) -> Double {
        let maxOffset = max(Self.finite(maxOffset), 0)
        let visualOffset = min(max(Self.finite(visualOffset), 0), maxOffset)
        return isFlipped ? visualOffset : maxOffset - visualOffset
    }

    private static func safeRatio(_ value: Double) -> Double {
        value.isFinite && value > 0 ? value : 1
    }

    private static func finite(_ value: Double) -> Double {
        value.isFinite ? value : 0
    }
}
