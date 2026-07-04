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
        private var isSyncing = false

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

            let sourceProgress = Self.progress(for: sourceScroll)
            let targetProgress: Double

            if let sourcePageCount = source.pageCount,
               let targetPageCount = target.pageCount,
               sourcePageCount > 0,
               sourcePageCount == targetPageCount {
                targetProgress = pageAnchoredProgress(from: source, progress: sourceProgress, pageCount: sourcePageCount)
            } else {
                targetProgress = side == .left
                    ? math.targetProgress(fromA: sourceProgress)
                    : math.targetProgress(fromB: sourceProgress)
            }

            isSyncing = true
            Self.setProgress(targetProgress, for: targetScroll)
            DispatchQueue.main.async { [weak self] in
                self?.isSyncing = false
            }
        }

        private func pageAnchoredProgress(from source: Pane, progress: Double, pageCount: Int) -> Double {
            let fallbackPage = min(max(Int((progress * Double(pageCount)).rounded(.down)), 0), pageCount - 1)
            let page: Int
            if let pdfView = source.pdfView,
               let document = pdfView.document,
               let currentPage = pdfView.currentPage {
                page = max(0, min(document.index(for: currentPage), pageCount - 1))
            } else {
                page = fallbackPage
            }

            let inPage = progress * Double(pageCount) - Double(page)
            return ScrollSyncMath.pageAnchored(page: page, inPage: inPage, pageCount: pageCount)
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

        private static func progress(for scrollView: NSScrollView) -> Double {
            let visible = scrollView.contentView.bounds
            let documentHeight = scrollView.documentView?.bounds.height ?? 0
            let maxOffset = documentHeight - visible.height
            guard maxOffset > 0 else { return 0 }
            return min(max(visible.origin.y / maxOffset, 0), 1)
        }

        private static func setProgress(_ progress: Double, for scrollView: NSScrollView) {
            let visible = scrollView.contentView.bounds
            let documentHeight = scrollView.documentView?.bounds.height ?? 0
            let maxOffset = documentHeight - visible.height
            guard maxOffset > 0 else { return }

            let targetY = min(max(progress, 0), 1) * maxOffset
            scrollView.contentView.setBoundsOrigin(NSPoint(x: visible.origin.x, y: targetY))
            scrollView.reflectScrolledClipView(scrollView.contentView)
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
