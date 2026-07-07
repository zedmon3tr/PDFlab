import AppKit
import PDFKit
import SwiftUI
import PDFLabCore

struct SingleDocumentView: View {
    var document: ViewerDocument
    var readingLayout: ViewerReadingLayout
    let translation: ViewerTranslationService

    var body: some View {
        switch document.kind {
        case .pdf:
            SinglePDFView(document: document, readingLayout: readingLayout, translation: translation)
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

    func makeCoordinator() -> Coordinator {
        Coordinator(translation: translation)
    }

    func makeNSView(context: Context) -> PDFView {
        let pdfView = PDFView()
        configure(pdfView, context: context)
        context.coordinator.selectionTranslation.attach(to: pdfView)
        return pdfView
    }

    func updateNSView(_ pdfView: PDFView, context: Context) {
        configure(pdfView, context: context)
    }

    static func dismantleNSView(_ pdfView: PDFView, coordinator: Coordinator) {
        coordinator.selectionTranslation.detach()
    }

    private func configure(_ pdfView: PDFView, context: Context) {
        let documentChanged = context.coordinator.documentID != document.id
        if documentChanged {
            context.coordinator.documentID = document.id

            pdfView.autoScales = true
            pdfView.backgroundColor = .textBackgroundColor
            pdfView.document = try? PDFTextExtractor.openDocument(at: document.url, password: document.password)
        }
        readingLayout.apply(to: pdfView)
    }

    final class Coordinator {
        var documentID: String?
        let selectionTranslation: SelectionTranslationController

        init(translation: ViewerTranslationService) {
            self.selectionTranslation = SelectionTranslationController(translation: translation)
        }
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
