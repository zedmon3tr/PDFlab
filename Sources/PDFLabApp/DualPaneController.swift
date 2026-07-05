import AppKit
import PDFKit
import SwiftUI
import PDFLabCore

// MARK: - 文档模型(供 ViewerView / 各面板复用)

enum ViewerDocumentKind: Equatable {
    case pdf
    case text
    case unsupported
}

struct ViewerDocument: Equatable, Identifiable {
    var url: URL
    var kind: ViewerDocumentKind
    var password: String?

    var id: String {
        "\(kind)-\(url.path)-\(password == nil ? "no-password" : "password")"
    }

    var title: String {
        url.lastPathComponent
    }
}

enum ViewerTextLoader {
    static func load(from url: URL) -> String? {
        for encoding in candidateEncodings {
            if let text = try? String(contentsOf: url, encoding: encoding) {
                return text
            }
        }
        return nil
    }

    private static let candidateEncodings: [String.Encoding] = [
        .utf8,
        .utf16,
        .unicode,
        .isoLatin1,
        .windowsCP1252,
    ]
}

struct DualPaneSplitMath {
    var dividerThickness: CGFloat
    var minPaneWidth: CGFloat

    func clampedFraction(_ fraction: CGFloat, totalWidth: CGFloat) -> CGFloat {
        guard totalWidth > 0 else { return 0.5 }
        let contentWidth = max(totalWidth - dividerThickness, 1)
        guard contentWidth >= 2 * minPaneWidth else {
            return min(max(fraction, 0), 1)
        }
        let minFraction = minPaneWidth / contentWidth
        let maxFraction = 1 - minFraction
        return min(max(fraction, minFraction), maxFraction)
    }

    func projectedFraction(baseFraction: CGFloat, translation: CGFloat, totalWidth: CGFloat) -> CGFloat {
        let contentWidth = max(totalWidth - dividerThickness, 1)
        return clampedFraction(baseFraction + translation / contentWidth, totalWidth: totalWidth)
    }
}

// MARK: - 对照双栏视图(SwiftUI 原生布局 + 原生 resize 光标分隔条)

/// 左右并排对照两文档,同步滚动。分隔条是真正的 SwiftUI 视图(夹在 HStack 两栏之间),
/// 故能拿到 hover 事件,`.pointerStyle(.columnResize)` 生效——这是从 NSSplitView 迁到
/// SwiftUI 布局的核心原因(见 CHANGELOG:AppKit 分隔条的 resize 光标被 SwiftUI 宿主/PDFView 盖掉)。
struct DualPaneView: View {
    var left: ViewerDocument
    var right: ViewerDocument
    var ratioA: Double
    var ratioB: Double

    /// 左栏占比(0...1),拖动分隔条时更新。
    @State private var dividerFraction: CGFloat = 0.5
    @State private var dragStartFraction: CGFloat?
    @State private var isDraggingDivider = false
    @StateObject private var sync = SyncScrollCoordinator()

    /// 分隔条厚度(命中区 + 视觉留白)。
    private static let dividerThickness: CGFloat = 10
    /// 最小栏宽,窗口过窄时让路。
    private static let minPaneWidth: CGFloat = 200
    private static let splitMath = DualPaneSplitMath(
        dividerThickness: dividerThickness,
        minPaneWidth: minPaneWidth
    )

    var body: some View {
        GeometryReader { geo in
            let width = geo.size.width
            let fraction = clampedFraction(for: width)
            let contentWidth = max(width - Self.dividerThickness, 0)
            let leftWidth = contentWidth * fraction

            HStack(spacing: 0) {
                SinglePaneRepresentable(document: left, side: .left, sync: sync)
                    .frame(width: leftWidth)
                    .id(left.id)

                divider(totalWidth: width)

                SinglePaneRepresentable(document: right, side: .right, sync: sync)
                    .frame(maxWidth: .infinity)
                    .id(right.id)
            }
        }
        .onAppear { sync.setRatios(ratioA: ratioA, ratioB: ratioB) }
        .onChange(of: ratioA) { sync.setRatios(ratioA: ratioA, ratioB: ratioB) }
        .onChange(of: ratioB) { sync.setRatios(ratioA: ratioA, ratioB: ratioB) }
    }

    /// 把 dividerFraction 夹到最小栏宽换算出的允许区间;宽度不足两栏最小宽时不强制,回落到 0.5 附近。
    private func clampedFraction(for width: CGFloat) -> CGFloat {
        Self.splitMath.clampedFraction(dividerFraction, totalWidth: width)
    }

    /// SwiftUI 分隔条:透明命中区 + 居中 capsule 把手(默认隐藏,hover/拖动时显示),
    /// 原生 columnResize 光标 + tooltip + 拖动手势。
    private func divider(totalWidth: CGFloat) -> some View {
        DividerHandle(
            isDragging: isDraggingDivider,
            thickness: Self.dividerThickness
        )
        .gesture(
            DragGesture(minimumDistance: 0)
                .onChanged { value in
                    isDraggingDivider = true
                    guard totalWidth > 0 else { return }
                    if dragStartFraction == nil {
                        dragStartFraction = clampedFraction(for: totalWidth)
                    }
                    let baseFraction = dragStartFraction ?? dividerFraction
                    dividerFraction = Self.splitMath.projectedFraction(
                        baseFraction: baseFraction,
                        translation: value.translation.width,
                        totalWidth: totalWidth
                    )
                }
                .onEnded { _ in
                    isDraggingDivider = false
                    dragStartFraction = nil
                    // 落定后归一化保存,避免拖出界的累积。
                    dividerFraction = clampedFraction(for: totalWidth)
                }
        )
    }
}

// MARK: - 分隔条把手(SwiftUI)

/// HStack 中间的分隔条:全高透明命中区,居中一根 capsule 把手。
/// 默认隐藏,hover 显示淡灰,拖动显示更亮一档。`.pointerStyle(.columnResize)` 给原生左右拖光标。
private struct DividerHandle: View {
    var isDragging: Bool
    var thickness: CGFloat

    @State private var isHovering = false

    private static let handleWidth: CGFloat = 6
    private static let handleHeight: CGFloat = 64

    var body: some View {
        ZStack {
            // 透明命中区,撑满全高,确保 hover / drag 命中整条。
            Color.clear
                .contentShape(Rectangle())

            Capsule()
                .fill(handleColor)
                .frame(width: Self.handleWidth, height: Self.handleHeight)
        }
        .frame(width: thickness)
        .frame(maxHeight: .infinity)
        .pointerStyle(.columnResize)
        .onHover { isHovering = $0 }
        .help(L10n.t("viewer.divider.resize"))
    }

    private var handleColor: Color {
        if isDragging {
            return Color.secondary.opacity(0.8)
        } else if isHovering {
            return Color.secondary.opacity(0.45)
        } else {
            return Color.clear
        }
    }
}

// MARK: - 单面板(NSViewRepresentable,按 kind 建 PDFView / NSTextView / 提示 label)

/// 单侧文档面板。makeNSView 按 document.kind 建视图,并把该侧 scrollView/pdfView 注册进 sync;
/// dismantle 时注销。PDFView 的 scrollView 递归查找,首帧可能未就绪,下一 runloop 再找一次。
private struct SinglePaneRepresentable: NSViewRepresentable {
    let document: ViewerDocument
    let side: SyncScrollCoordinator.Side
    let sync: SyncScrollCoordinator

    func makeCoordinator() -> Coordinator {
        Coordinator(sync: sync, side: side)
    }

    func makeNSView(context: Context) -> NSView {
        let built = build(for: document)
        context.coordinator.attach(view: built.view, scrollView: built.scrollView, pdfView: built.pdfView)
        return built.view
    }

    func updateNSView(_ nsView: NSView, context: Context) {
        // 文档不变时无需重建;文档本身随 ViewerView 的 sideBySide 切换携带,identity 变化会触发新的 makeNSView。
        context.coordinator.refresh()
    }

    static func dismantleNSView(_ nsView: NSView, coordinator: Coordinator) {
        coordinator.detach()
    }

    // MARK: 建视图

    private func build(for document: ViewerDocument) -> (view: NSView, scrollView: NSScrollView?, pdfView: PDFView?) {
        switch document.kind {
        case .pdf:
            return buildPDF(for: document)
        case .text:
            return buildText(for: document)
        case .unsupported:
            return (buildMessage(L10n.t("viewer.unsupported")), nil, nil)
        }
    }

    private func buildPDF(for document: ViewerDocument) -> (NSView, NSScrollView?, PDFView?) {
        guard let pdfDocument = try? PDFTextExtractor.openDocument(at: document.url, password: document.password) else {
            return (buildMessage(L10n.t("viewer.openFailed")), nil, nil)
        }

        let pdfView = PDFView()
        pdfView.document = pdfDocument
        pdfView.displayMode = .singlePageContinuous
        pdfView.displayDirection = .vertical
        pdfView.displaysPageBreaks = true
        pdfView.autoScales = true
        pdfView.backgroundColor = .textBackgroundColor
        pdfView.layoutDocumentView()

        return (pdfView, SyncScrollCoordinator.findScrollView(in: pdfView), pdfView)
    }

    private func buildText(for document: ViewerDocument) -> (NSView, NSScrollView?, PDFView?) {
        let scrollView = NSScrollView()
        scrollView.hasVerticalScroller = true
        scrollView.hasHorizontalScroller = false
        scrollView.borderType = .noBorder
        scrollView.drawsBackground = true
        scrollView.backgroundColor = .textBackgroundColor

        let textView = NSTextView()
        textView.isEditable = false
        textView.isSelectable = true
        textView.isRichText = false
        textView.importsGraphics = false
        textView.font = .systemFont(ofSize: 14)
        textView.textColor = .labelColor
        textView.backgroundColor = .textBackgroundColor
        textView.textContainerInset = NSSize(width: 24, height: 24)
        textView.isHorizontallyResizable = false
        textView.isVerticallyResizable = true
        textView.autoresizingMask = [.width]
        textView.minSize = NSSize(width: 0, height: scrollView.contentSize.height)
        textView.maxSize = NSSize(width: CGFloat.greatestFiniteMagnitude, height: CGFloat.greatestFiniteMagnitude)
        textView.textContainer?.containerSize = NSSize(
            width: scrollView.contentSize.width,
            height: CGFloat.greatestFiniteMagnitude
        )
        textView.textContainer?.widthTracksTextView = true
        textView.string = ViewerTextLoader.load(from: document.url) ?? L10n.t("viewer.openFailed")

        scrollView.documentView = textView
        return (scrollView, scrollView, nil)
    }

    private func buildMessage(_ message: String) -> NSView {
        let container = NSView()
        let label = NSTextField(wrappingLabelWithString: message)
        label.alignment = .center
        label.textColor = .secondaryLabelColor
        label.translatesAutoresizingMaskIntoConstraints = false
        container.addSubview(label)

        NSLayoutConstraint.activate([
            label.centerXAnchor.constraint(equalTo: container.centerXAnchor),
            label.centerYAnchor.constraint(equalTo: container.centerYAnchor),
            label.leadingAnchor.constraint(greaterThanOrEqualTo: container.leadingAnchor, constant: 24),
            label.trailingAnchor.constraint(lessThanOrEqualTo: container.trailingAnchor, constant: -24),
        ])

        return container
    }

    // MARK: Coordinator

    final class Coordinator {
        private let sync: SyncScrollCoordinator
        private let side: SyncScrollCoordinator.Side
        private weak var view: NSView?
        private weak var pdfView: PDFView?

        init(sync: SyncScrollCoordinator, side: SyncScrollCoordinator.Side) {
            self.sync = sync
            self.side = side
        }

        func attach(view: NSView, scrollView: NSScrollView?, pdfView: PDFView?) {
            self.view = view
            self.pdfView = pdfView
            sync.register(side: side, view: view, scrollView: scrollView, pdfView: pdfView)
            // PDFView 的 scrollView 首帧常未就绪:下一 runloop 再让 sync 补找一次。
            DispatchQueue.main.async { [weak self] in
                self?.sync.refreshRegistration(side: self?.side ?? .left)
            }
        }

        func refresh() {
            sync.refreshRegistration(side: side)
        }

        func detach() {
            sync.unregister(side: side)
        }
    }
}

// MARK: - 同步滚动协调器

/// 跨两个 SinglePaneRepresentable 承载同步滚动状态。两侧都注册后,
/// 对各自 NSScrollView 的 clipView 挂 boundsDidChange 观察者(逻辑一比一保留自旧 Coordinator):
/// 绝对映射(距顶屏数 × 系数)、回声判定(lastSetOffset)、收敛截断(tolerance)、isSyncing 守卫、
/// 两侧均 PDF 且页数相同走页锚点几何精确模式。
final class SyncScrollCoordinator: ObservableObject {
    enum Side {
        case left
        case right
    }

    private final class Pane {
        weak var view: NSView?
        weak var scrollView: NSScrollView?
        weak var pdfView: PDFView?

        var pageCount: Int? { pdfView?.document?.pageCount }

        func refreshScrollView() {
            if scrollView == nil, let view {
                scrollView = SyncScrollCoordinator.findScrollView(in: view)
            }
            scrollView?.contentView.postsBoundsChangedNotifications = true
        }
    }

    private var leftPane: Pane?
    private var rightPane: Pane?
    private var observers: [NSObjectProtocol] = []
    private var math = ScrollSyncMath(ratioA: 1, ratioB: 1)

    /// 同步守卫:仅在程序化设置对侧位置的同步调用栈内为 true,阻断同步派发的通知。
    private var isSyncing = false
    /// 各侧最近一次被程序化设置后的滚动偏移。迟到的 boundsDidChange 通知若仍停在该值,
    /// 判定为回声(被动滚动),直接丢弃——防互踢环路主防线。
    private var lastSetOffset: [Side: CGFloat] = [:]

    /// 偏移比较容差(pt):小于一个滚轮刻度。
    private static let offsetTolerance: CGFloat = 2.0
    /// 页内位置容差(页高的千分之二)。
    private static let inPageTolerance = 0.002

    // MARK: 注册

    func setRatios(ratioA: Double, ratioB: Double) {
        math = ScrollSyncMath(ratioA: ratioA, ratioB: ratioB)
    }

    func register(side: Side, view: NSView, scrollView: NSScrollView?, pdfView: PDFView?) {
        let pane = Pane()
        pane.view = view
        pane.scrollView = scrollView
        pane.pdfView = pdfView
        pane.refreshScrollView()
        switch side {
        case .left: leftPane = pane
        case .right: rightPane = pane
        }
        reattachObservers()
    }

    func refreshRegistration(side: Side) {
        pane(for: side)?.refreshScrollView()
        reattachObservers()
    }

    func unregister(side: Side) {
        switch side {
        case .left: leftPane = nil
        case .right: rightPane = nil
        }
        reattachObservers()
    }

    private func pane(for side: Side) -> Pane? {
        side == .left ? leftPane : rightPane
    }

    // MARK: 观察者

    /// 只有两侧都注册且都拿到 scrollView 才挂观察者;任一缺失先撤下,等下次注册/刷新补齐。
    private func reattachObservers() {
        detachObservers()
        guard let leftPane, let rightPane,
              leftPane.scrollView != nil, rightPane.scrollView != nil else { return }
        attach(pane: leftPane, side: .left)
        attach(pane: rightPane, side: .right)
    }

    private func attach(pane: Pane, side: Side) {
        pane.refreshScrollView()
        guard let clipView = pane.scrollView?.contentView else { return }
        let observer = NotificationCenter.default.addObserver(
            forName: NSView.boundsDidChangeNotification,
            object: clipView,
            queue: .main
        ) { [weak self] _ in
            self?.scrollChanged(from: side)
        }
        observers.append(observer)
    }

    private func detachObservers() {
        for observer in observers {
            NotificationCenter.default.removeObserver(observer)
        }
        observers.removeAll()
    }

    deinit {
        detachObservers()
    }

    // MARK: 同步逻辑(一比一保留)

    private func scrollChanged(from side: Side) {
        guard !isSyncing,
              let leftPane,
              let rightPane else { return }

        let source = side == .left ? leftPane : rightPane
        let target = side == .left ? rightPane : leftPane
        source.refreshScrollView()
        target.refreshScrollView()

        guard let sourceScroll = source.scrollView,
              let targetScroll = target.scrollView else { return }

        // 回声判定:该侧位置仍停留在上次程序化设置的值,说明是 setBoundsOrigin/go(to:)
        // 的迟到通知(被动滚动),丢弃,不反向同步。
        let sourceOffset = sourceScroll.contentView.bounds.origin.y
        if let programmed = lastSetOffset[side],
           abs(programmed - sourceOffset) < Self.offsetTolerance {
            return
        }
        lastSetOffset[side] = nil   // 位置已偏离记录值:确认是真实用户滚动

        isSyncing = true
        defer { isSyncing = false }

        let didMove: Bool
        if let sourcePDF = source.pdfView,
           let targetPDF = target.pdfView,
           let sourcePageCount = source.pageCount,
           let targetPageCount = target.pageCount,
           sourcePageCount > 0,
           sourcePageCount == targetPageCount {
            // 精确模式:页数相同的两 PDF 走页锚点几何同步。
            didMove = Self.syncPageAnchored(from: sourcePDF, to: targetPDF)
        } else {
            // 兜底:按屏绝对映射。目标位置是源位置的纯函数,不累加,长距离不漂移。
            let sourceViewport = sourceScroll.contentView.bounds.height
            if sourceViewport > 0 {
                let sourceScreens = Double(sourceOffset) / Double(sourceViewport)
                let targetScreens = side == .left
                    ? math.targetScreens(fromA: sourceScreens)
                    : math.targetScreens(fromB: sourceScreens)
                didMove = Self.applyAbsoluteScreens(targetScreens, to: targetScroll)
            } else {
                didMove = false
            }
        }

        if didMove {
            let targetSide: Side = side == .left ? .right : .left
            let targetOffset = targetScroll.contentView.bounds.origin.y
            lastSetOffset[targetSide] = targetOffset
        }
    }

    /// 视口顶边锚点:落在哪一页、页内(自页顶起)的比例位置。全部取自 PDFView 真实页面几何。
    private struct PageAnchor {
        var pageIndex: Int
        var fractionFromTop: Double
    }

    private static func viewportTopAnchor(of pdfView: PDFView) -> PageAnchor? {
        guard let document = pdfView.document else { return nil }
        let bounds = pdfView.bounds
        guard bounds.height > 0 else { return nil }
        let topY = pdfView.isFlipped ? bounds.minY + 1 : bounds.maxY - 1
        let topPoint = NSPoint(x: bounds.midX, y: topY)
        guard let page = pdfView.page(for: topPoint, nearest: true) else { return nil }
        let pagePoint = pdfView.convert(topPoint, to: page)
        let pageBounds = page.bounds(for: pdfView.displayBox)
        guard pageBounds.height > 0 else { return nil }
        let fraction = Double((pageBounds.maxY - pagePoint.y) / pageBounds.height)
        return PageAnchor(
            pageIndex: document.index(for: page),
            fractionFromTop: min(max(fraction, 0), 1)
        )
    }

    /// 页锚点同步(两侧均为 PDF 且页数相同)。全程不经均匀页高折算,页高不均也不跳页。
    /// 返回是否真正移动了目标(已在期望位置邻域内则不动,天然断开互踢环路)。
    private static func syncPageAnchored(from sourcePDF: PDFView, to targetPDF: PDFView) -> Bool {
        guard let anchor = viewportTopAnchor(of: sourcePDF),
              let targetDocument = targetPDF.document,
              let targetPage = targetDocument.page(at: anchor.pageIndex) else { return false }

        // 收敛截断:目标侧已停在同页同位置,不再设置。
        if let current = viewportTopAnchor(of: targetPDF),
           current.pageIndex == anchor.pageIndex,
           abs(current.fractionFromTop - anchor.fractionFromTop) < inPageTolerance {
            return false
        }

        let pageBounds = targetPage.bounds(for: targetPDF.displayBox)
        let destY = pageBounds.maxY - CGFloat(anchor.fractionFromTop) * pageBounds.height
        let destination = PDFDestination(
            page: targetPage,
            at: NSPoint(x: pageBounds.minX, y: destY)
        )
        targetPDF.go(to: destination)
        return true
    }

    /// 按屏绝对映射滚动目标侧:targetScreens 屏 × 目标视口高度 = 目标绝对偏移,截断后直接定位。
    /// 已在目标 ε 邻域内则不动(收敛截断,断开互踢环路)。返回是否真正移动。
    @discardableResult
    private static func applyAbsoluteScreens(_ targetScreens: Double, to scrollView: NSScrollView) -> Bool {
        let visible = scrollView.contentView.bounds
        let documentHeight = scrollView.documentView?.bounds.height ?? 0
        let maxOffset = documentHeight - visible.height
        guard maxOffset > 0, visible.height > 0, targetScreens.isFinite else { return false }

        let targetY = min(max(CGFloat(targetScreens) * visible.height, 0), maxOffset)
        guard abs(targetY - visible.origin.y) >= offsetTolerance else { return false }
        scrollView.contentView.setBoundsOrigin(NSPoint(x: visible.origin.x, y: targetY))
        scrollView.reflectScrolledClipView(scrollView.contentView)
        return true
    }

    static func findScrollView(in view: NSView) -> NSScrollView? {
        if let scrollView = view as? NSScrollView {
            return scrollView
        }
        for subview in view.subviews {
            if let found = findScrollView(in: subview) {
                return found
            }
        }
        return nil
    }
}
