import AppKit
import PDFKit
import SwiftUI
import PDFLabCore

struct SingleDocumentView: View {
    var document: ViewerDocument
    var readingLayout = ViewerReadingLayout.defaultLayout
    var zoomCommand: ViewerZoomCommand?
    var onScaleChange: (Double) -> Void = { _ in }

    var body: some View {
        switch document.kind {
        case .pdf:
            SinglePDFView(
                document: document,
                readingLayout: readingLayout,
                zoomCommand: zoomCommand,
                onScaleChange: onScaleChange
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

private struct SinglePDFView: NSViewRepresentable {
    var document: ViewerDocument
    var readingLayout: ViewerReadingLayout
    var zoomCommand: ViewerZoomCommand?
    var onScaleChange: (Double) -> Void

    func makeCoordinator() -> Coordinator {
        Coordinator()
    }

    func makeNSView(context: Context) -> PDFView {
        let pdfView = PDFView()
        // 基线配置与 defaultLayout 一致;此后 displayMode 由
        // ViewerReadingLayout.apply(to:) 在 configure 里单点管理,两处不互相覆盖。
        PDFPreviewConfiguration.apply(to: pdfView)
        // 新建视图忽略历史命令(revision 对齐当前值),只响应之后的按钮点击;
        // 否则旧命令会把刚 autoScales 适配好的新文档缩放覆盖掉。
        context.coordinator.lastAppliedZoomRevision = zoomCommand?.revision
        configure(pdfView, context: context)
        context.coordinator.startMagnificationMonitor(for: pdfView)
        context.coordinator.startScaleObservation(for: pdfView)
        return pdfView
    }

    func updateNSView(_ pdfView: PDFView, context: Context) {
        configure(pdfView, context: context)
    }

    private func configure(_ pdfView: PDFView, context: Context) {
        // 每次更新刷新回显闭包,避免捕获过期上下文。
        context.coordinator.onScaleChange = onScaleChange

        let documentChanged = context.coordinator.documentID != document.id
        if documentChanged {
            context.coordinator.documentID = document.id
            context.coordinator.suspendingEcho { echo in
                pdfView.document = try? PDFTextExtractor.openDocument(at: document.url, password: document.password)
                pdfView.autoScales = true
                pdfView.layoutDocumentView()
                echo.scheduleEchoOfCurrentScale(of: pdfView)
            }
        }

        // 幂等:值不变时不重触 PDFKit setter(见 ViewerReadingLayout.apply)。
        readingLayout.apply(to: pdfView)

        applyZoomCommandIfNeeded(to: pdfView, context: context)
    }

    /// 按 revision 幂等施加缩放按钮命令;施加期间挂起回显,完成后补报实际 clamp 结果。
    private func applyZoomCommandIfNeeded(to pdfView: PDFView, context: Context) {
        guard let command = zoomCommand,
              context.coordinator.lastAppliedZoomRevision != command.revision else { return }
        context.coordinator.lastAppliedZoomRevision = command.revision

        context.coordinator.suspendingEcho { echo in
            pdfView.minScaleFactor = PDFPreviewConfiguration.minimumScale
            pdfView.maxScaleFactor = PDFPreviewConfiguration.maximumScale
            pdfView.autoScales = false
            pdfView.scaleFactor = CGFloat(ViewerZoom.clampedScale(command.scale))
            echo.scheduleEchoOfCurrentScale(of: pdfView)
        }
    }

    static func dismantleNSView(_ pdfView: PDFView, coordinator: Coordinator) {
        coordinator.stopMagnificationMonitor()
        coordinator.stopScaleObservation()
    }

    final class Coordinator {
        var documentID: String?
        var lastAppliedZoomRevision: Int?
        var onScaleChange: ((Double) -> Void)?
        private var magnificationMonitor: Any?
        private let scaleObserver = PDFScaleEchoObserver()

        func startMagnificationMonitor(for pdfView: PDFView) {
            stopMagnificationMonitor()
            magnificationMonitor = NSEvent.addLocalMonitorForEvents(matching: .magnify) { [weak pdfView] event in
                guard let pdfView else { return event }
                let sameWindow = event.window === pdfView.window
                let location = pdfView.convert(event.locationInWindow, from: nil)
                let insidePDF = pdfView.bounds.contains(location)
                guard sameWindow, insidePDF else { return event }
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
        }
    }
}

enum PDFPreviewConfiguration {
    static let minimumScale: CGFloat = 0.25
    static let maximumScale: CGFloat = 8

    static func apply(to pdfView: PDFView) {
        pdfView.displayMode = .singlePageContinuous
        pdfView.displayDirection = .vertical
        pdfView.displaysPageBreaks = true
        pdfView.backgroundColor = .textBackgroundColor
    }

    static func applyMagnification(_ magnification: CGFloat, to pdfView: PDFView) {
        let currentScale = pdfView.scaleFactor
        pdfView.minScaleFactor = minimumScale
        pdfView.maxScaleFactor = maximumScale
        pdfView.autoScales = false
        pdfView.scaleFactor = min(max(currentScale + magnification, minimumScale), maximumScale)
    }
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
