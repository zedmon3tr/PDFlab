import AppKit
import PDFKit

enum ParagraphClickGate {
    static func isPlainPrimarySingleClick(
        clickCount: Int,
        buttonNumber: Int,
        modifierFlags: NSEvent.ModifierFlags
    ) -> Bool {
        clickCount == 1 &&
            buttonNumber == 0 &&
            modifierFlags.intersection(.deviceIndependentFlagsMask).isEmpty
    }

    static func hasBlockingAnnotation(on page: PDFPage, at point: CGPoint) -> Bool {
        page.annotations.contains { annotation in
            annotation.bounds.contains(point) &&
                !ParagraphHighlightAnnotationStore.isParagraphHighlight(annotation)
        }
    }
}
