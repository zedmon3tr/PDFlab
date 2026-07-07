import AppKit
import PDFKit

final class ParagraphHighlightAnnotationStore {
    private static let marker = "com.pdflab.paragraph-highlight"

    private var installed: (page: PDFPage, annotation: PDFAnnotation)?

    static func pageBounds(for highlight: ParagraphHighlight, on page: PDFPage) -> CGRect {
        let pageBounds = page.bounds(for: .mediaBox)
        return CGRect(
            x: pageBounds.minX + highlight.bbox.minX * pageBounds.width,
            y: pageBounds.minY + highlight.bbox.minY * pageBounds.height,
            width: highlight.bbox.width * pageBounds.width,
            height: highlight.bbox.height * pageBounds.height
        )
    }

    func apply(_ highlight: ParagraphHighlight?, in document: PDFDocument) {
        guard let highlight else {
            clear()
            return
        }
        guard let page = document.page(at: highlight.pageIndex) else {
            clear()
            return
        }

        let annotation = Self.makeAnnotation(bounds: Self.pageBounds(for: highlight, on: page))
        clear()
        page.addAnnotation(annotation)
        installed = (page, annotation)
    }

    func clear() {
        if let installed {
            installed.page.removeAnnotation(installed.annotation)
        }
        installed = nil
    }

    static func markAsParagraphHighlight(_ annotation: PDFAnnotation) {
        annotation.contents = marker
    }

    static func isParagraphHighlight(_ annotation: PDFAnnotation) -> Bool {
        annotation.contents == marker
    }

    deinit {
        clear()
    }

    private static func makeAnnotation(bounds: CGRect) -> PDFAnnotation {
        let annotation = PDFAnnotation(bounds: bounds, forType: .square, withProperties: nil)
        markAsParagraphHighlight(annotation)
        annotation.color = NSColor.controlAccentColor.withAlphaComponent(0.55)
        annotation.interiorColor = NSColor.controlAccentColor.withAlphaComponent(0.18)
        annotation.isReadOnly = true

        let border = PDFBorder()
        border.lineWidth = 1
        annotation.border = border
        return annotation
    }
}
