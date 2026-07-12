import AppKit
import PDFKit
import SwiftUI
import PDFLabCore

struct SingleDocumentView: View {
    var document: ViewerDocument
    var readingLayout = ViewerReadingLayout.defaultLayout
    var zoomCommand: ViewerZoomCommand?
    var onScaleChange: (Double) -> Void = { _ in }
    var onUserZoom: () -> Void = {}

    var body: some View {
        switch document.kind {
        case .pdf:
            SinglePDFView(
                document: document,
                readingLayout: readingLayout,
                zoomCommand: zoomCommand,
                onScaleChange: onScaleChange,
                onUserZoom: onUserZoom
            )
        case .text:
            SingleTextView(document: document)
        case .unsupported:
            Text(L10n.t("viewer.unsupported"))
                .foregroundStyle(.secondary)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }
}

struct SinglePDFView: NSViewRepresentable {
    var document: ViewerDocument
    var readingLayout: ViewerReadingLayout
    var zoomCommand: ViewerZoomCommand?
    var onScaleChange: (Double) -> Void
    var onUserZoom: () -> Void

    func makeCoordinator() -> Coordinator {
        Coordinator()
    }

    func makeNSView(context: Context) -> PDFView {
        let pdfView = PDFView()
        // 基线配置与 defaultLayout 一致;此后 displayMode 由
        // ViewerReadingLayout.apply(to:) 在 configure 里单点管理,两处不互相覆盖。
        PDFPreviewConfiguration.apply(to: pdfView)
        configure(pdfView, context: context)
        context.coordinator.startMagnificationMonitor(for: pdfView)
        context.coordinator.startScaleObservation(for: pdfView)
        context.coordinator.startViewportObservation(for: pdfView)
        return pdfView
    }

    func updateNSView(_ pdfView: PDFView, context: Context) {
        configure(pdfView, context: context)
    }

    private func configure(_ pdfView: PDFView, context: Context) {
        // 每次更新刷新回显闭包,避免捕获过期上下文。
        context.coordinator.onScaleChange = onScaleChange
        context.coordinator.onUserZoom = onUserZoom

        let documentChanged = context.coordinator.documentID != document.id
        if documentChanged {
            context.coordinator.noteDocumentChanged(to: document.id)
            context.coordinator.suspendingEcho { echo in
                pdfView.document = try? PDFTextExtractor.openDocument(at: document.url, password: document.password)
                pdfView.minScaleFactor = PDFPreviewConfiguration.minimumScale
                pdfView.maxScaleFactor = PDFPreviewConfiguration.maximumScale
                pdfView.layoutDocumentView()
                // 新文档基线 = 中性实际大小 100%(默认缩放语义,不强制 fitPage);
                // 随后 applyZoomCommandIfNeeded 重放该侧记住的命令(可能是 .scale(1.5)
                // 或 .fitWidth),在标签切换/晋升重建视图时恢复该侧后台保留的缩放。
                PDFPreviewConfiguration.apply(.scale(1), to: pdfView)
                echo.scheduleEchoOfCurrentScale(of: pdfView)
            }
        }

        // 幂等:值不变时不重触 PDFKit setter(见 ViewerReadingLayout.apply)。
        let readingLayoutChanged = context.coordinator.readingLayout != readingLayout
        context.coordinator.readingLayout = readingLayout
        readingLayout.apply(to: pdfView)
        if readingLayoutChanged {
            context.coordinator.reapplyActiveFit(to: pdfView)
        }

        applyZoomCommandIfNeeded(to: pdfView, context: context)
    }

    /// 按 revision 幂等施加缩放按钮命令;施加期间挂起回显,完成后补报实际 clamp 结果。
    private func applyZoomCommandIfNeeded(to pdfView: PDFView, context: Context) {
        guard let command = zoomCommand,
              context.coordinator.lastAppliedZoomRevision != command.revision else { return }
        context.coordinator.lastAppliedZoomRevision = command.revision

        context.coordinator.activeZoomAction = command.action
        context.coordinator.apply(command.action, to: pdfView)
    }

    static func dismantleNSView(_ pdfView: PDFView, coordinator: Coordinator) {
        coordinator.stopMagnificationMonitor()
        coordinator.stopScaleObservation()
        coordinator.stopViewportObservation()
    }

    final class Coordinator {
        var documentID: String?
        var readingLayout: ViewerReadingLayout?
        var lastAppliedZoomRevision: Int?
        var activeZoomAction: ViewerZoomAction = .scale(1)
        var onScaleChange: ((Double) -> Void)?
        var onUserZoom: (() -> Void)?

        /// 文档装入/更换(切标签、晋升、替换同侧文档):基线回中性 100%、
        /// lastAppliedZoomRevision 归 nil——两侧命令流 revision 各自独立,
        /// 新文档的命令即便与旧文档 revision 数值相同也必须重放,恢复该侧记住的缩放。
        func noteDocumentChanged(to documentID: String) {
            self.documentID = documentID
            activeZoomAction = .scale(1)
            lastAppliedZoomRevision = nil
        }
        private var magnificationMonitor: Any?
        private let scaleObserver = PDFScaleEchoObserver()
        private let viewportObserver = PDFViewportResizeObserver()
        private var fitReapplicationScheduled = false

        func startMagnificationMonitor(for pdfView: PDFView) {
            stopMagnificationMonitor()
            magnificationMonitor = NSEvent.addLocalMonitorForEvents(matching: .magnify) { [weak self, weak pdfView] event in
                guard let self, let pdfView else { return event }
                let sameWindow = event.window === pdfView.window
                let location = pdfView.convert(event.locationInWindow, from: nil)
                let insidePDF = pdfView.bounds.contains(location)
                guard sameWindow, insidePDF else { return event }
                self.cancelActiveFit(at: Double(pdfView.scaleFactor))
                self.onUserZoom?()
                PDFPreviewConfiguration.applyMagnification(event.magnification, to: pdfView)
                return nil
            }
        }

        func stopMagnificationMonitor() {
            if let magnificationMonitor {
                NSEvent.removeMonitor(magnificationMonitor)
            }
            magnificationMonitor = nil
        }

        func startViewportObservation(for pdfView: PDFView) {
            guard let viewport = PDFPreviewConfiguration.viewportView(in: pdfView) else { return }
            viewportObserver.onResize = { [weak self, weak pdfView] in
                guard let self, let pdfView else { return }
                self.scheduleActiveFitReapplication(to: pdfView)
            }
            viewportObserver.attach(to: viewport)
        }

        func stopViewportObservation() {
            viewportObserver.detach()
        }

        func scheduleActiveFitReapplication(to pdfView: PDFView) {
            guard activeZoomAction == .fitPage || activeZoomAction == .fitWidth || activeZoomAction == .fitHeight,
                  !fitReapplicationScheduled else { return }
            fitReapplicationScheduled = true
            DispatchQueue.main.async { [weak self, weak pdfView] in
                guard let self else { return }
                self.fitReapplicationScheduled = false
                guard let pdfView else { return }
                self.reapplyActiveFit(to: pdfView)
            }
        }

        func reapplyActiveFit(to pdfView: PDFView) {
            guard activeZoomAction == .fitPage || activeZoomAction == .fitWidth || activeZoomAction == .fitHeight else { return }
            apply(activeZoomAction, to: pdfView)
        }

        /// 用户捏合优先于持续适配；同步退出 fit，避免之后的 viewport/layout 通知撤销手势结果。
        func cancelActiveFit(at scale: Double) {
            activeZoomAction = .scale(ViewerZoom.clampedScale(scale))
            fitReapplicationScheduled = false
        }

        func apply(_ action: ViewerZoomAction, to pdfView: PDFView) {
            suspendingEcho { echo in
                pdfView.minScaleFactor = PDFPreviewConfiguration.minimumScale
                pdfView.maxScaleFactor = PDFPreviewConfiguration.maximumScale
                PDFPreviewConfiguration.apply(action, to: pdfView)
                echo.scheduleEchoOfCurrentScale(of: pdfView)
            }
        }

        // MARK: 缩放回显(KVO + PDFViewScaleChanged 双保险,见 PDFScaleEchoObserver)

        func startScaleObservation(for pdfView: PDFView) {
            scaleObserver.onScale = { [weak self] scale in
                // 异步落回主队列:变化可能发生在 SwiftUI 视图更新栈内
                // (updateNSView 里的文档装载/布局),同步写 @Published 会告警。
                DispatchQueue.main.async {
                    self?.onScaleChange?(scale)
                }
            }
            scaleObserver.attach(to: pdfView)
        }

        func stopScaleObservation() {
            scaleObserver.detach()
        }

        /// 程序化改缩放的统一入口:挂起回显 → 执行 → 恢复,防自触发回环。
        func suspendingEcho(_ body: (Coordinator) -> Void) {
            scaleObserver.isSuspended = true
            defer { scaleObserver.isSuspended = false }
            body(self)
        }

        /// 挂起期间的变化不会经观察者上报;这里在下一 runloop 补报真实值
        /// (此时挂起已解除,且已脱离 SwiftUI 视图更新栈)。
        func scheduleEchoOfCurrentScale(of pdfView: PDFView) {
            DispatchQueue.main.async { [weak self, weak pdfView] in
                guard let self, let pdfView else { return }
                self.scaleObserver.reportCurrentScale(of: pdfView)
            }
        }

        deinit {
            stopMagnificationMonitor()
            stopScaleObservation()
            stopViewportObservation()
        }
    }
}

enum PDFPreviewConfiguration {
    static let minimumScale: CGFloat = 0.05
    static let maximumScale: CGFloat = 64

    static func apply(to pdfView: PDFView) {
        pdfView.displayMode = .singlePageContinuous
        pdfView.displayDirection = .vertical
        pdfView.displaysPageBreaks = true
        pdfView.backgroundColor = .textBackgroundColor
    }

    static func apply(_ action: ViewerZoomAction, to pdfView: PDFView) {
        switch action {
        case .scale(let scale):
            pdfView.autoScales = false
            setScaleIfNeeded(CGFloat(ViewerZoom.clampedScale(scale)), on: pdfView)
        case .fitPage:
            pdfView.autoScales = true
            pdfView.layoutDocumentView()
            let fittedScale = pdfView.scaleFactorForSizeToFit
            if fittedScale.isFinite, fittedScale > 0 {
                setScaleIfNeeded(min(max(fittedScale, minimumScale), maximumScale), on: pdfView)
            }
            pdfView.autoScales = true
        case .fitWidth:
            pdfView.autoScales = false
            setScaleIfNeeded(CGFloat(ViewerZoom.fittedScale(for: pdfView, dimension: .width)), on: pdfView)
        case .fitHeight:
            pdfView.autoScales = false
            setScaleIfNeeded(CGFloat(ViewerZoom.fittedScale(for: pdfView, dimension: .height)), on: pdfView)
        }
    }

    static func viewportView(in root: NSView) -> NSClipView? {
        if let clipView = root as? NSClipView { return clipView }
        for subview in root.subviews {
            if let match = viewportView(in: subview) { return match }
        }
        return nil
    }

    private static func setScaleIfNeeded(_ scale: CGFloat, on pdfView: PDFView) {
        guard abs(pdfView.scaleFactor - scale) > 0.0001 else { return }
        pdfView.scaleFactor = scale
    }

    static func applyMagnification(_ magnification: CGFloat, to pdfView: PDFView) {
        let currentScale = pdfView.scaleFactor
        pdfView.minScaleFactor = minimumScale
        pdfView.maxScaleFactor = maximumScale
        pdfView.autoScales = false
        pdfView.scaleFactor = min(max(currentScale + magnification, minimumScale), maximumScale)
    }
}

/// 只观察可视区域尺寸，不观察滚动 origin；适应宽/高由 Coordinator 合并到下一 runloop 重算。
final class PDFViewportResizeObserver {
    var onResize: (() -> Void)?
    private var observation: NSObjectProtocol?
    private weak var view: NSView?
    private var previouslyPostedFrameChanges = false

    func attach(to view: NSView) {
        detach()
        self.view = view
        previouslyPostedFrameChanges = view.postsFrameChangedNotifications
        view.postsFrameChangedNotifications = true
        observation = NotificationCenter.default.addObserver(
            forName: NSView.frameDidChangeNotification,
            object: view,
            queue: .main
        ) { [weak self] _ in
            self?.onResize?()
        }
    }

    func detach() {
        if let observation { NotificationCenter.default.removeObserver(observation) }
        observation = nil
        view?.postsFrameChangedNotifications = previouslyPostedFrameChanges
        view = nil
    }

    deinit { detach() }
}

/// 单文档 md/txt 视图:NSScrollView + NSTextView(经 ViewerTextViewFactory,与对照面板一致),
/// 只读可选。
private struct SingleTextView: NSViewRepresentable {
    var document: ViewerDocument

    func makeCoordinator() -> Coordinator { Coordinator() }

    func makeNSView(context: Context) -> NSScrollView {
        let (scrollView, _) = ViewerTextViewFactory.makeScrollable(text: loadText())
        context.coordinator.documentID = document.id
        return scrollView
    }

    func updateNSView(_ scrollView: NSScrollView, context: Context) {
        guard context.coordinator.documentID != document.id else { return }
        context.coordinator.documentID = document.id
        (scrollView.documentView as? NSTextView)?.string = loadText()
    }

    private func loadText() -> String {
        ViewerTextLoader.load(from: document.url) ?? L10n.t("viewer.openFailed")
    }

    final class Coordinator {
        var documentID: String?
    }
}
