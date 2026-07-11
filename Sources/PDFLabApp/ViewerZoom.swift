import AppKit
import PDFKit

/// 缩放按钮的刻度数学。范围单一事实源是 `PDFPreviewConfiguration`(0.25–8,
/// 与触控板捏合共用),这里只补充 10% 刻度对齐与显示格式化。
enum ViewerZoom {
    static let minimumScale = Double(PDFPreviewConfiguration.minimumScale)
    static let maximumScale = Double(PDFPreviewConfiguration.maximumScale)
    /// 加减按钮步进:10%。
    static let stepPercent = 10
    /// 浮点脏值容差(以"格"为单位):0.199999… 视同 20% 刻度。
    private static let tickTolerance = 0.001

    static func clampedScale(_ scale: Double) -> Double {
        min(max(scale, minimumScale), maximumScale)
    }

    static func percentLabel(for scale: Double) -> String {
        "\(Int((clampedScale(scale) * 100).rounded()))%"
    }

    /// 放大:非刻度值先对齐到上方最近刻度(19% → 20%),刻度值再进一格(20% → 30%)。
    static func steppedUp(from scale: Double) -> Double {
        let tick = Int(floor(scale * 100 / Double(stepPercent) + tickTolerance))
        return clampedScale(Double((tick + 1) * stepPercent) / 100)
    }

    /// 缩小:非刻度值先对齐到下方最近刻度(31% → 30%),刻度值再退一格(30% → 20%),
    /// 结果不低于支持下限。
    static func steppedDown(from scale: Double) -> Double {
        let tick = Int(ceil(scale * 100 / Double(stepPercent) - tickTolerance))
        return clampedScale(Double((tick - 1) * stepPercent) / 100)
    }
}

/// 一次缩放命令:按钮点击产生,SinglePDFView 按 revision 幂等施加
/// (SwiftUI 重渲染重复走 updateNSView 时不重复设置 scaleFactor)。
struct ViewerZoomCommand: Equatable {
    var scale: Double
    var revision: Int
}

/// PDFView `scaleFactor` 回显观察者:KVO + `PDFViewScaleChanged` 通知双保险,
/// 捏合/按钮/自动适配任何来源的缩放变化都汇入 `onScale`。
/// 防回环三件套:程序化施加期间 `isSuspended` 挂起;相同值去重(lastReported);
/// 回显只更新显示值、绝不派生新命令(由调用方约定,见 `ViewerSession.noteObservedZoomScale`)。
final class PDFScaleEchoObserver {
    var onScale: ((Double) -> Void)?
    /// 程序化施加缩放期间置 true,阻断自己触发的 KVO/通知回显。
    var isSuspended = false

    private var observation: NSKeyValueObservation?
    private var notificationObserver: NSObjectProtocol?
    private var lastReported: Double?

    func attach(to pdfView: PDFView) {
        detach()
        observation = pdfView.observe(\.scaleFactor, options: [.new]) { [weak self] view, _ in
            self?.report(Double(view.scaleFactor))
        }
        notificationObserver = NotificationCenter.default.addObserver(
            forName: .PDFViewScaleChanged,
            object: pdfView,
            queue: nil
        ) { [weak self] notification in
            guard let view = notification.object as? PDFView else { return }
            self?.report(Double(view.scaleFactor))
        }
    }

    /// 挂起解除后由调用方补报当前真实值(如按钮施加后的实际 clamp 结果)。
    func reportCurrentScale(of pdfView: PDFView) {
        report(Double(pdfView.scaleFactor))
    }

    func detach() {
        observation?.invalidate()
        observation = nil
        if let notificationObserver {
            NotificationCenter.default.removeObserver(notificationObserver)
        }
        notificationObserver = nil
        lastReported = nil
    }

    deinit {
        detach()
    }

    private func report(_ scale: Double) {
        guard !isSuspended else { return }
        if let lastReported, abs(lastReported - scale) < 0.0001 { return }
        lastReported = scale
        onScale?(scale)
    }
}
