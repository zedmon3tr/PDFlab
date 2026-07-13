import AppKit
import PDFKit

/// 查看器 PDF 视图:逐页模式吞掉 scrollWheel(需求:滚轮/触控板不得翻页;
/// 捏合缩放走 app 级 NSEvent magnify monitor,不经 scrollWheel,不受影响)。
final class ViewerPDFView: PDFView {
    var swallowsScrollWheel = false

    override func scrollWheel(with event: NSEvent) {
        guard !swallowsScrollWheel else { return }
        super.scrollWheel(with: event)
    }
}

/// PDFView 当前页回显观察者(`.PDFViewPageChanged`),接口与 PDFScaleEchoObserver 同构:
/// 程序化 go(to:) 期间 `isSuspended` 挂起,防命令→回显→命令回环;
/// 挂起解除后由调用方在下一 runloop 补报真实值(clamp 后落点)。
final class PDFPageEchoObserver {
    var onPage: ((Int, Int) -> Void)?
    var isSuspended = false

    private var notificationObserver: NSObjectProtocol?
    private weak var pdfView: PDFView?

    func attach(to pdfView: PDFView) {
        detach()
        self.pdfView = pdfView
        notificationObserver = NotificationCenter.default.addObserver(
            forName: .PDFViewPageChanged, object: pdfView, queue: nil
        ) { [weak self] notification in
            guard let view = notification.object as? PDFView else { return }
            self?.reportCurrentPage(of: view)
        }
    }

    func reportCurrentPage(of pdfView: PDFView) {
        guard !isSuspended else { return }
        let pageCount = pdfView.document?.pageCount ?? 0
        let index = pdfView.currentPage.flatMap { pdfView.document?.index(for: $0) } ?? 0
        onPage?(index, pageCount)
    }

    func detach() {
        if let notificationObserver {
            NotificationCenter.default.removeObserver(notificationObserver)
        }
        notificationObserver = nil
        pdfView = nil
    }

    deinit { detach() }
}

/// 逐页模式方向键监视器(app 级 local monitor,查看器生命周期内常驻):
/// handler 返回 true 表示本次按键已消费(逐页态且成功翻页),事件吞掉;
/// 否则原样放行(含正在编辑文本时,方向键归输入框)。
@MainActor
final class ViewerPagedKeyMonitor: ObservableObject {
    var handler: ((Int) -> Bool)?
    private var monitor: Any?

    func start() {
        guard monitor == nil else { return }
        monitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            guard let self,
                  self.shouldConsume(
                    keyCode: event.keyCode,
                    isEditingText: Self.isEditingText(in: event.window)
                  ) else { return event }
            return nil
        }
    }

    func stop() {
        if let monitor { NSEvent.removeMonitor(monitor) }
        monitor = nil
    }

    /// 判定 + 派发(拆出便于单测):方向键、非文本编辑、handler 接受三者齐备才消费。
    func shouldConsume(keyCode: UInt16, isEditingText: Bool) -> Bool {
        guard !isEditingText,
              let delta = ViewerPageNavigation.pageDelta(forKeyCode: keyCode) else { return false }
        return handler?(delta) ?? false
    }

    private static func isEditingText(in window: NSWindow?) -> Bool {
        window?.firstResponder is NSTextView
    }

    deinit {
        if let monitor { NSEvent.removeMonitor(monitor) }
    }
}
