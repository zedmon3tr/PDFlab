import AppKit
import PDFKit
import SwiftUI
import PDFLabCore

struct SingleDocumentView: View {
    var document: ViewerDocument
    var readingLayout: ViewerReadingLayout
    var zoomScale: Binding<Double>
    var zoomRequest: ViewerZoomRequest

    var body: some View {
        switch document.kind {
        case .pdf:
            SinglePDFView(
                document: document,
                readingLayout: readingLayout,
                zoomScale: zoomScale,
                zoomRequest: zoomRequest
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
    var zoomScale: Binding<Double>
    var zoomRequest: ViewerZoomRequest

    func makeCoordinator() -> Coordinator {
        Coordinator()
    }

    func makeNSView(context: Context) -> PDFView {
        let pdfView = PDFView()
        configure(pdfView, context: context)
        return pdfView
    }

    func updateNSView(_ pdfView: PDFView, context: Context) {
        configure(pdfView, context: context)
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
        context.coordinator.zoom.apply(
            zoomRequest,
            to: pdfView,
            scale: zoomScale,
            force: documentChanged
        )
    }

    final class Coordinator {
        var documentID: String?
        let zoom = PDFZoomController()
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
