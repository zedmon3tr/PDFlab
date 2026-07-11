import AppKit
import PDFKit
import SwiftUI

enum ViewerZoom {
    static let minimumScale = 0.05
    static let maximumScale = 8.0
    static let step = 0.1
    static let presets: [Double] = [8, 4, 2, 1.5, 1.25, 1, 0.75, 0.5, 0.25, 0.1, 0.05]

    static func clampedScale(_ scale: Double) -> Double {
        min(max(scale, minimumScale), maximumScale)
    }

    static func percentLabel(for scale: Double) -> String {
        "\(Int((clampedScale(scale) * 100).rounded()))%"
    }

    static func fittedScale(
        available: Double,
        page: Double,
        pagesAcross: Int,
        interPageSpacing: Double = 0
    ) -> Double {
        let usable = available - max(interPageSpacing, 0) * Double(max(pagesAcross - 1, 0))
        guard usable > 0, page > 0, pagesAcross > 0 else { return 1 }
        return clampedScale(usable / (page * Double(pagesAcross)))
    }
}

enum ViewerZoomAction: Equatable {
    case scale(Double)
    case fitPage
    case fitWidth
    case fitHeight
}

struct ViewerZoomRequest: Equatable {
    var action: ViewerZoomAction
    var revision: Int

    static let initial = ViewerZoomRequest(action: .scale(1), revision: 0)

    func updatingForObservedScale(_ observedScale: Double, currentScale: Double) -> Self? {
        let scale = ViewerZoom.clampedScale(observedScale)
        guard abs(scale - currentScale) > 0.0001 else { return nil }
        return Self(action: .scale(scale), revision: revision + 1)
    }
}

final class PDFZoomController {
    private var lastRequestRevision: Int?
    private var observation: NSKeyValueObservation?
    private var isApplying = false

    func apply(
        _ request: ViewerZoomRequest,
        to pdfView: PDFView,
        scale: Binding<Double>,
        force: Bool = false
    ) {
        observe(pdfView, scale: scale)
        guard force || lastRequestRevision != request.revision else { return }
        lastRequestRevision = request.revision

        isApplying = true
        defer { isApplying = false }

        pdfView.minScaleFactor = CGFloat(ViewerZoom.minimumScale)
        pdfView.maxScaleFactor = CGFloat(ViewerZoom.maximumScale)

        switch request.action {
        case .scale(let requestedScale):
            setScale(requestedScale, on: pdfView)
        case .fitPage:
            setScale(Double(pdfView.scaleFactorForSizeToFit), on: pdfView)
        case .fitWidth:
            setScale(fittedScale(for: pdfView, dimension: .width), on: pdfView)
        case .fitHeight:
            setScale(fittedScale(for: pdfView, dimension: .height), on: pdfView)
        }

        scale.wrappedValue = Double(pdfView.scaleFactor)
    }

    private func observe(_ pdfView: PDFView, scale: Binding<Double>) {
        guard observation == nil else { return }
        observation = pdfView.observe(\.scaleFactor, options: [.new]) { [weak self] view, _ in
            guard self?.isApplying == false else { return }
            DispatchQueue.main.async {
                scale.wrappedValue = Double(view.scaleFactor)
            }
        }
    }

    private func setScale(_ requestedScale: Double, on pdfView: PDFView) {
        pdfView.autoScales = false
        pdfView.scaleFactor = CGFloat(ViewerZoom.clampedScale(requestedScale))
    }

    private enum Dimension {
        case width
        case height
    }

    private func fittedScale(for pdfView: PDFView, dimension: Dimension) -> Double {
        guard let page = pdfView.currentPage ?? pdfView.document?.page(at: 0) else {
            return 1
        }
        let pageBounds = page.bounds(for: pdfView.displayBox)
        let visibleBounds = visibleBounds(in: pdfView)
        let available = dimension == .width ? visibleBounds.width : visibleBounds.height
        let pageDimension = dimension == .width ? pageBounds.width : pageBounds.height
        let pagesAcross = dimension == .width && pdfView.displayMode == .twoUpContinuous ? 2 : 1
        let interPageSpacing: CGFloat = dimension == .width && pdfView.displaysPageBreaks ? 16 : 0
        return ViewerZoom.fittedScale(
            available: Double(available),
            page: Double(pageDimension),
            pagesAcross: pagesAcross,
            interPageSpacing: Double(interPageSpacing)
        )
    }

    private func visibleBounds(in pdfView: PDFView) -> NSRect {
        guard let scrollView = findScrollView(in: pdfView) else { return .zero }
        return scrollView.contentView.bounds
    }

    private func findScrollView(in view: NSView) -> NSScrollView? {
        if let scrollView = view as? NSScrollView { return scrollView }
        for subview in view.subviews {
            if let scrollView = findScrollView(in: subview) { return scrollView }
        }
        return nil
    }
}
