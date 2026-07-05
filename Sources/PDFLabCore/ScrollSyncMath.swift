/// 按屏(视口高度)的同步滚动比例缩放数学(两侧类型不同或页数不等时使用)。
///
/// 语义:纯比例缩放,对"绝对距顶屏数"和"增量屏数"同样适用。
/// 源侧 `screens` 个视口屏 → 目标侧 `screens × 系数` 个视口屏。
/// A 为源时系数为 `ratioA / ratioB`,B 为源时为 `ratioB / ratioA`(互逆)。
/// 100%/100% 时一屏对一屏,无论文档长短——避免"总进度比例"下短文档滚一点长文档冲一大截。
/// 当前 DualPaneView 用绝对映射(距顶屏数 × 系数 = 目标距顶屏数),消除长距离累积漂移。
///
/// 两侧均为 PDF 且页数相同时,App 层(DualPaneView)直接用 PDFKit 页面几何做页锚点同步,
/// 不再经过本类——原 `pageAnchored(page:inPage:pageCount:)` 与 `targetProgress` 均已废弃移除。
public struct ScrollSyncMath: Sendable {
    public let ratioA: Double
    public let ratioB: Double

    public init(ratioA: Double, ratioB: Double) {
        self.ratioA = Self.safeRatio(ratioA)
        self.ratioB = Self.safeRatio(ratioB)
    }

    /// A 侧滚动的屏数 → B 侧应滚动的屏数。
    public func targetScreens(fromA screensA: Double) -> Double {
        Self.finite(screensA * (ratioA / ratioB))
    }

    /// B 侧滚动的屏数 → A 侧应滚动的屏数。
    public func targetScreens(fromB screensB: Double) -> Double {
        Self.finite(screensB * (ratioB / ratioA))
    }

    private static func safeRatio(_ value: Double) -> Double {
        value.isFinite && value > 0 ? value : 1
    }

    private static func finite(_ value: Double) -> Double {
        value.isFinite ? value : 0
    }
}
