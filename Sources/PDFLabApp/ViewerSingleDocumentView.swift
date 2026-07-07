import AppKit
import PDFKit
import SwiftUI
import PDFLabCore

struct SingleDocumentView: View {
    var document: ViewerDocument
    var readingLayout: ViewerReadingLayout
    let translation: ViewerTranslationService
    var paragraphClick: ParagraphClickConfiguration? = nil

    var body: some View {
        switch document.kind {
        case .pdf:
            SinglePDFView(
                document: document,
                readingLayout: readingLayout,
                translation: translation,
                paragraphClick: paragraphClick
            )
        case .text:
            // NSTextView 承载(与对照面板同一构造),划选气泡在单文档文本视图同样生效。
            SingleTextView(document: document, translation: translation)
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
    let translation: ViewerTranslationService
    var paragraphClick: ParagraphClickConfiguration?

    func makeCoordinator() -> Coordinator {
        Coordinator(translation: translation)
    }

    func makeNSView(context: Context) -> PDFView {
        let pdfView = ParagraphClickPDFView()
        configure(pdfView, context: context)
        context.coordinator.selectionTranslation.attach(to: pdfView)
        context.coordinator.paragraphClick.attach(to: pdfView)
        return pdfView
    }

    func updateNSView(_ pdfView: PDFView, context: Context) {
        configure(pdfView, context: context)
    }

    static func dismantleNSView(_ pdfView: PDFView, coordinator: Coordinator) {
        coordinator.selectionTranslation.detach()
        coordinator.paragraphClick.detach()
    }

    private func configure(_ pdfView: PDFView, context: Context) {
        let documentChanged = context.coordinator.documentID != document.id
        if documentChanged {
            context.coordinator.documentID = document.id

            pdfView.autoScales = true
            pdfView.backgroundColor = .textBackgroundColor
            pdfView.document = try? PDFTextExtractor.openDocument(at: document.url, password: document.password)
            context.coordinator.paragraphClick.reset(documentID: document.id)
        }
        readingLayout.apply(to: pdfView)
        context.coordinator.paragraphClick.update(configuration: paragraphClick)
    }

    final class Coordinator {
        var documentID: String?
        let selectionTranslation: SelectionTranslationController
        let paragraphClick = ParagraphClickController()

        init(translation: ViewerTranslationService) {
            self.selectionTranslation = SelectionTranslationController(translation: translation)
        }
    }
}

private final class ParagraphClickPDFView: PDFView {
    var paragraphClickHandler: ((NSEvent, ParagraphClickPDFView) -> Void)?

    override func mouseUp(with event: NSEvent) {
        super.mouseUp(with: event)
        guard ParagraphClickGate.isPlainPrimarySingleClick(
            clickCount: event.clickCount,
            buttonNumber: event.buttonNumber,
            modifierFlags: event.modifierFlags
        ) else { return }
        if let selected = currentSelection?.string, SelectionTranslationText.cleaned(selected) != nil {
            return
        }
        paragraphClickHandler?(event, self)
    }
}

@MainActor
private final class ParagraphClickController {
    private weak var pdfView: ParagraphClickPDFView?
    private var configuration: ParagraphClickConfiguration?
    private var cachedParagraphs: [Int: [PageParagraph]] = [:]
    private var documentID: String?
    private let highlightStore = ParagraphHighlightAnnotationStore()

    nonisolated init() {}

    func attach(to pdfView: ParagraphClickPDFView) {
        self.pdfView = pdfView
        pdfView.paragraphClickHandler = { [weak self] event, pdfView in
            self?.handle(event, in: pdfView)
        }
    }

    func detach() {
        pdfView?.paragraphClickHandler = nil
        removeHighlight()
        pdfView = nil
        configuration = nil
        cachedParagraphs.removeAll()
    }

    func reset(documentID: String) {
        guard self.documentID != documentID else { return }
        self.documentID = documentID
        cachedParagraphs.removeAll()
        removeHighlight()
    }

    func update(configuration: ParagraphClickConfiguration?) {
        self.configuration = configuration
        guard let configuration else {
            removeHighlight()
            return
        }
        updateHighlight(configuration.highlight)
    }

    private func handle(_ event: NSEvent, in pdfView: ParagraphClickPDFView) {
        guard let configuration else { return }
        guard let document = pdfView.document else {
            configuration.onMiss()
            return
        }

        let viewPoint = pdfView.convert(event.locationInWindow, from: nil)
        guard let page = pdfView.page(for: viewPoint, nearest: false) else {
            configuration.onMiss()
            return
        }

        let pagePoint = pdfView.convert(viewPoint, to: page)
        guard !ParagraphClickGate.hasBlockingAnnotation(on: page, at: pagePoint) else {
            return
        }
        let pageBounds = page.bounds(for: .mediaBox)
        guard pageBounds.width > 0, pageBounds.height > 0 else {
            configuration.onMiss()
            return
        }

        let normalized = CGPoint(
            x: (pagePoint.x - pageBounds.minX) / pageBounds.width,
            y: (pagePoint.y - pageBounds.minY) / pageBounds.height
        )
        guard normalized.x >= 0, normalized.x <= 1, normalized.y >= 0, normalized.y <= 1 else {
            configuration.onMiss()
            return
        }

        let pageIndex = document.index(for: page)
        guard pageIndex != NSNotFound else {
            configuration.onMiss()
            return
        }

        let paragraphs = paragraphs(for: pageIndex, in: document)
        guard let paragraphIndex = ParagraphHitTester.hitTest(point: normalized, in: paragraphs) else {
            configuration.onMiss()
            return
        }

        configuration.onSelection(
            ParagraphClickSelection(
                pageIndex: pageIndex,
                paragraphIndex: paragraphIndex,
                paragraph: paragraphs[paragraphIndex]
            )
        )
    }

    private func paragraphs(for pageIndex: Int, in document: PDFDocument) -> [PageParagraph] {
        if let cached = cachedParagraphs[pageIndex] {
            return cached
        }
        let extraction = PDFTextExtractor.extractPage(document, pageIndex: pageIndex)
        let paragraphs = extraction.isScanned ? [] : ParagraphHitTester.paragraphs(from: extraction.lines)
        cachedParagraphs[pageIndex] = paragraphs
        return paragraphs
    }

    private func updateHighlight(_ highlight: ParagraphHighlight?) {
        guard let document = pdfView?.document else {
            removeHighlight()
            return
        }
        highlightStore.apply(highlight, in: document)
    }

    private func removeHighlight() {
        highlightStore.clear()
    }
}

/// 单文档 md/txt 视图:NSScrollView + NSTextView(经 ViewerTextViewFactory,与对照面板一致),
/// 只读可选,挂划选气泡翻译。
private struct SingleTextView: NSViewRepresentable {
    var document: ViewerDocument
    let translation: ViewerTranslationService

    func makeCoordinator() -> Coordinator {
        Coordinator(translation: translation)
    }

    func makeNSView(context: Context) -> NSScrollView {
        let (scrollView, textView) = ViewerTextViewFactory.makeScrollable(text: loadText())
        context.coordinator.documentID = document.id
        context.coordinator.selectionTranslation.attach(to: textView)
        return scrollView
    }

    func updateNSView(_ scrollView: NSScrollView, context: Context) {
        guard context.coordinator.documentID != document.id else { return }
        context.coordinator.documentID = document.id
        (scrollView.documentView as? NSTextView)?.string = loadText()
    }

    static func dismantleNSView(_ scrollView: NSScrollView, coordinator: Coordinator) {
        coordinator.selectionTranslation.detach()
    }

    private func loadText() -> String {
        ViewerTextLoader.load(from: document.url) ?? L10n.t("viewer.openFailed")
    }

    final class Coordinator {
        var documentID: String?
        let selectionTranslation: SelectionTranslationController

        init(translation: ViewerTranslationService) {
            self.selectionTranslation = SelectionTranslationController(translation: translation)
        }
    }
}
