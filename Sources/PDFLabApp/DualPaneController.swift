import AppKit
import PDFKit
import SwiftUI
import PDFLabCore

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

struct DualPaneController: NSViewRepresentable {
    var left: ViewerDocument
    var right: ViewerDocument?
    var ratioA: Double
    var ratioB: Double

    func makeCoordinator() -> Coordinator {
        Coordinator()
    }

    func makeNSView(context: Context) -> NSSplitView {
        let splitView = NSSplitView()
        splitView.isVertical = true
        splitView.dividerStyle = .thin
        splitView.autoresizesSubviews = true
        return splitView
    }

    func updateNSView(_ splitView: NSSplitView, context: Context) {
        context.coordinator.update(
            splitView,
            left: left,
            right: right,
            ratioA: ratioA,
            ratioB: ratioB
        )
    }

    static func dismantleNSView(_ splitView: NSSplitView, coordinator: Coordinator) {
        coordinator.detachObservers()
    }

    final class Coordinator {
        private enum Side {
            case left
            case right
        }

        private final class Pane {
            let view: NSView
            weak var scrollView: NSScrollView?
            weak var pdfView: PDFView?

            init(view: NSView, scrollView: NSScrollView?, pdfView: PDFView?) {
                self.view = view
                self.scrollView = scrollView
                self.pdfView = pdfView
            }

            var pageCount: Int? {
                pdfView?.document?.pageCount
            }

            func refreshScrollView() {
                if scrollView == nil {
                    scrollView = Coordinator.findScrollView(in: view)
                }
                scrollView?.contentView.postsBoundsChangedNotifications = true
            }
        }

        private var signature: String?
        private var leftPane: Pane?
        private var rightPane: Pane?
        private var observers: [NSObjectProtocol] = []
        private var math = ScrollSyncMath(ratioA: 1, ratioB: 1)
        /// 同步守卫:仅在程序化设置对侧位置的同步调用栈内为 true,阻断同步派发的通知。
        private var isSyncing = false
        /// 各侧最近一次被程序化设置后的滚动偏移。迟到的 boundsDidChange 通知若仍停在该值,
        /// 判定为回声(被动滚动),不是用户滚动,直接丢弃——这是防互踢环路的主防线。
        private var lastSetOffset: [Side: CGFloat] = [:]
        /// 各侧上次观察到的滚动偏移,用于按屏增量同步计算 Δ。
        /// 回声通知也会更新此值(但不触发反向同步),避免下次误把回声位移当用户增量。
        private var lastObservedOffset: [Side: CGFloat] = [:]

        /// 偏移比较容差(pt):小于一个滚轮刻度,既能吸收浮点/布局微调,又不会吞掉真实滚动。
        private static let offsetTolerance: CGFloat = 2.0
        /// 页内位置容差(页高的千分之二,A4 渲染下约 1–2pt):目标已在期望位置邻域内就不再设置。
        private static let inPageTolerance = 0.002

        func update(
            _ splitView: NSSplitView,
            left: ViewerDocument,
            right: ViewerDocument?,
            ratioA: Double,
            ratioB: Double
        ) {
            math = ScrollSyncMath(ratioA: ratioA, ratioB: ratioB)

            let newSignature = "\(left.id)|\(right?.id ?? "nil")"
            guard newSignature != signature else { return }
            signature = newSignature

            detachObservers()
            lastSetOffset.removeAll()
            lastObservedOffset.removeAll()
            splitView.subviews.forEach { $0.removeFromSuperview() }

            let newLeftPane = makePane(for: left)
            leftPane = newLeftPane
            splitView.addSubview(newLeftPane.view)

            if let right {
                let newRightPane = makePane(for: right)
                rightPane = newRightPane
                splitView.addSubview(newRightPane.view)
            } else {
                rightPane = nil
            }

            splitView.adjustSubviews()
            if splitView.subviews.count == 2 {
                splitView.setPosition(splitView.bounds.width / 2, ofDividerAt: 0)
            }
            attachObservers()

            DispatchQueue.main.async { [weak self] in
                self?.attachObservers()
            }
        }

        func detachObservers() {
            for observer in observers {
                NotificationCenter.default.removeObserver(observer)
            }
            observers.removeAll()
        }

        private func attachObservers() {
            detachObservers()
            guard let leftPane, let rightPane else { return }
            register(pane: leftPane, side: .left)
            register(pane: rightPane, side: .right)
        }

        private func register(pane: Pane, side: Side) {
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

            // 回声判定:该侧位置仍停留在上次程序化设置的值,说明这是 setProgress/go(to:)
            // 的迟到通知(被动滚动),不是用户滚动,直接丢弃,不再反向同步。
            // 但仍要把观察偏移更新到当前值,否则下一次真实滚动会把回声位移误算进 Δ。
            let sourceOffset = sourceScroll.contentView.bounds.origin.y
            if let programmed = lastSetOffset[side],
               abs(programmed - sourceOffset) < Self.offsetTolerance {
                lastObservedOffset[side] = sourceOffset
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
                // 精确模式:页数相同的两 PDF 走页锚点几何同步(不变)。
                didMove = Self.syncPageAnchored(from: sourcePDF, to: targetPDF)
                // 页锚点模式不依赖增量,但仍同步观察偏移以便切换到增量分支时基线正确。
                lastObservedOffset[side] = sourceOffset
            } else {
                // 兜底:按屏增量同步。源侧 Δ 折算成源侧屏数,乘比例系数,换算成目标点数叠加。
                let previous = lastObservedOffset[side] ?? sourceOffset
                let deltaPts = sourceOffset - previous
                lastObservedOffset[side] = sourceOffset

                let sourceViewport = sourceScroll.contentView.bounds.height
                if deltaPts != 0, sourceViewport > 0 {
                    let sourceScreens = Double(deltaPts) / Double(sourceViewport)
                    let targetScreens = side == .left
                        ? math.targetScreens(fromA: sourceScreens)
                        : math.targetScreens(fromB: sourceScreens)
                    didMove = Self.applyScreenDelta(targetScreens, to: targetScroll)
                } else {
                    didMove = false
                }
            }

            if didMove {
                let targetSide: Side = side == .left ? .right : .left
                let targetOffset = targetScroll.contentView.bounds.origin.y
                lastSetOffset[targetSide] = targetOffset
                lastObservedOffset[targetSide] = targetOffset
            }
        }

        /// 视口顶边锚点:落在哪一页、页内(自页顶起)的比例位置。全部取自 PDFView 真实页面几何。
        private struct PageAnchor {
            var pageIndex: Int
            var fractionFromTop: Double   // 0 = 页顶,1 = 页底
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

        /// 页锚点同步(两侧均为 PDF 且页数相同):源侧按视口几何求"顶边所在页 + 页内比例",
        /// 目标侧用其文档同一页的真实 bounds 换算出目的点,经 PDFDestination 定位。
        /// 全程不经过"均匀页高"的全局进度折算,页高不均/页面尺寸不同也不会跳页。
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

        private func makePane(for document: ViewerDocument) -> Pane {
            switch document.kind {
            case .pdf:
                return makePDFPane(for: document)
            case .text:
                return makeTextPane(for: document)
            case .unsupported:
                return makeMessagePane(L10n.t("viewer.unsupported"))
            }
        }

        private func makePDFPane(for document: ViewerDocument) -> Pane {
            guard let pdfDocument = try? PDFTextExtractor.openDocument(at: document.url, password: document.password) else {
                return makeMessagePane(L10n.t("viewer.openFailed"))
            }

            let pdfView = PDFView()
            pdfView.document = pdfDocument
            pdfView.displayMode = .singlePageContinuous
            pdfView.displayDirection = .vertical
            pdfView.displaysPageBreaks = true
            pdfView.autoScales = true
            pdfView.backgroundColor = .textBackgroundColor
            pdfView.layoutDocumentView()

            return Pane(
                view: pdfView,
                scrollView: Self.findScrollView(in: pdfView),
                pdfView: pdfView
            )
        }

        private func makeTextPane(for document: ViewerDocument) -> Pane {
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
            return Pane(view: scrollView, scrollView: scrollView, pdfView: nil)
        }

        private func makeMessagePane(_ message: String) -> Pane {
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

            return Pane(view: container, scrollView: nil, pdfView: nil)
        }

        /// 按屏增量滚动目标侧:targetScreens 屏 → 目标视口高度 × 屏数 = 目标点数,
        /// 叠加到目标当前偏移,截断到 [0, maxOffset]。已在目标 ε 邻域内则不动(收敛截断,
        /// 断开互踢环路;目标触顶/触底后无法再动也自然停下)。返回是否真正移动。
        @discardableResult
        private static func applyScreenDelta(_ targetScreens: Double, to scrollView: NSScrollView) -> Bool {
            let visible = scrollView.contentView.bounds
            let documentHeight = scrollView.documentView?.bounds.height ?? 0
            let maxOffset = documentHeight - visible.height
            guard maxOffset > 0, visible.height > 0, targetScreens.isFinite else { return false }

            let deltaPts = CGFloat(targetScreens) * visible.height
            let targetY = min(max(visible.origin.y + deltaPts, 0), maxOffset)
            guard abs(targetY - visible.origin.y) >= offsetTolerance else { return false }
            scrollView.contentView.setBoundsOrigin(NSPoint(x: visible.origin.x, y: targetY))
            scrollView.reflectScrolledClipView(scrollView.contentView)
            return true
        }

        private static func findScrollView(in view: NSView) -> NSScrollView? {
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
}
