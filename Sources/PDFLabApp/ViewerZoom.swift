import AppKit
import PDFKit

enum ViewerZoomSelection: Equatable {
    case free
    case fitPage
    case fitWidth
    case fitHeight
}

enum ViewerZoomMenuItem: Equatable {
    case preset(Double)
    case fitPage
    case fitWidth
    case fitHeight
}

enum ViewerZoomDimension {
    case width
    case height
}

/// 菜单、按钮与触控板缩放的单一事实源。
enum ViewerZoom {
    static let minimumScale = Double(PDFPreviewConfiguration.minimumScale)
    static let maximumScale = Double(PDFPreviewConfiguration.maximumScale)
    /// 加减按钮步进:10%。
    static let stepPercent = 10
    /// 浮点脏值容差(以"格"为单位):0.199999… 视同 20% 刻度。
    private static let tickTolerance = 0.001
    static let presets: [Double] = [64, 32, 24, 16, 8, 4, 2, 1.5, 1.25, 1, 0.75, 0.5, 0.25, 0.1, 0.05]

    static func clampedScale(_ scale: Double) -> Double {
        min(max(scale, minimumScale), maximumScale)
    }

    static func percentLabel(for scale: Double) -> String {
        "\(Int((clampedScale(scale) * 100).rounded()))%"
    }

    static func checkedMenuItem(selection: ViewerZoomSelection, scale: Double) -> ViewerZoomMenuItem? {
        switch selection {
        case .fitPage: return .fitPage
        case .fitWidth: return .fitWidth
        case .fitHeight: return .fitHeight
        case .free:
            guard let preset = presets.first(where: { abs($0 - scale) <= 0.001 }) else { return nil }
            return .preset(preset)
        }
    }

    static func fittedScale(
        available: Double,
        page: Double,
        pagesAcross: Int,
        interPageSpacing: Double = 0
    ) -> Double {
        guard available > 0, page > 0, pagesAcross > 0 else { return 1 }
        let totalPageSize = page * Double(pagesAcross) + interPageSpacing * Double(max(0, pagesAcross - 1))
        return clampedScale(available / totalPageSize)
    }

    static func fittedScale(for pdfView: PDFView, dimension: ViewerZoomDimension) -> Double {
        guard let page = pdfView.currentPage ?? pdfView.document?.page(at: 0) else { return 1 }
        let pageBounds = page.bounds(for: pdfView.displayBox)
        let viewport = PDFPreviewConfiguration.viewportView(in: pdfView)?.bounds.size ?? pdfView.bounds.size
        let pagesAcross = (pdfView.displayMode == .twoUp || pdfView.displayMode == .twoUpContinuous) ? 2 : 1
        switch dimension {
        case .width:
            return fittedScale(
                available: Double(viewport.width),
                page: Double(pageBounds.width),
                pagesAcross: pagesAcross,
                interPageSpacing: pagesAcross == 2 ? 16 : 0
            )
        case .height:
            return fittedScale(available: Double(viewport.height), page: Double(pageBounds.height), pagesAcross: 1)
        }
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

enum ViewerZoomAction: Equatable {
    case scale(Double)
    case fitPage
    case fitWidth
    case fitHeight
}

/// 一次缩放命令:控制条操作产生,SinglePDFView 按 revision 幂等施加
/// (SwiftUI 重渲染重复走 updateNSView 时不重复设置 scaleFactor)。
struct ViewerZoomCommand: Equatable {
    var action: ViewerZoomAction
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

/// 一次翻页命令:与 ViewerZoomCommand 同构(revision 幂等施加,重建视图时重放恢复页码)。
struct ViewerPageCommand: Equatable {
    var pageIndex: Int
    var revision: Int
}
