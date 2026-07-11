import AppKit
import PDFKit

enum ViewerReadingLayout: String, CaseIterable, Identifiable {
    case singlePage
    case twoPage
    case continuous

    static let defaultLayout: ViewerReadingLayout = .continuous

    var id: Self { self }

    var titleKey: String {
        switch self {
        case .singlePage:
            return "viewer.layoutSinglePage"
        case .twoPage:
            return "viewer.layoutTwoPage"
        case .continuous:
            return "viewer.layoutContinuous"
        }
    }

    var iconName: String {
        switch self {
        case .singlePage:
            return "doc"
        case .twoPage:
            return "book.pages"
        case .continuous:
            return "scroll"
        }
    }

    var pdfDisplayMode: PDFDisplayMode {
        switch self {
        case .singlePage:
            return .singlePage
        case .twoPage:
            return .twoUp
        case .continuous:
            return .singlePageContinuous
        }
    }

    func apply(to pdfView: PDFView) {
        let modeChanged = pdfView.displayMode != pdfDisplayMode
        let destination = modeChanged ? Self.visibleDestination(in: pdfView) : nil

        // Only touch PDFKit setters when the value actually differs: apply(to:)
        // runs on every SwiftUI re-render,
        // and unconditional writes here fire PDFKit relayout/redraw churn even
        // when nothing about the reading layout changed.
        if pdfView.displayMode != pdfDisplayMode {
            pdfView.displayMode = pdfDisplayMode
        }
        if pdfView.displayDirection != .vertical {
            pdfView.displayDirection = .vertical
        }
        if pdfView.displaysPageBreaks != true {
            pdfView.displaysPageBreaks = true
        }

        guard modeChanged else { return }
        pdfView.layoutDocumentView()
        if let destination {
            pdfView.go(to: destination)
        }
    }

    private static func visibleDestination(in pdfView: PDFView) -> PDFDestination? {
        guard let page = pdfView.currentPage else { return nil }
        let viewPoint = NSPoint(x: pdfView.bounds.midX, y: pdfView.bounds.midY)
        let pagePoint = pdfView.convert(viewPoint, to: page)
        return PDFDestination(page: page, at: pagePoint)
    }
}
