import CoreGraphics
import PDFKit

public enum PageRasterizer {
    private static let minDPI: CGFloat = 300
    private static let maxDPI: CGFloat = 400
    private static let maxPixels = 6000

    /// 按 targetDPI(默认 350,夹在 300...400)渲染页面;单边超过 maxPixels(6000)时整体降比例。
    public static func rasterize(page: PDFPage, targetDPI: CGFloat = 350) -> CGImage? {
        let bounds = page.bounds(for: .mediaBox)
        guard bounds.width > 0, bounds.height > 0 else {
            return nil
        }

        let clampedDPI = min(max(targetDPI, minDPI), maxDPI)
        let dpiScale = clampedDPI / 72
        let rawWidth = bounds.width * dpiScale
        let rawHeight = bounds.height * dpiScale
        let maxDimension = max(rawWidth, rawHeight)
        let fitScale = maxDimension > CGFloat(maxPixels) ? CGFloat(maxPixels) / maxDimension : 1
        let renderScale = dpiScale * fitScale
        let pixelWidth = max(1, Int((bounds.width * renderScale).rounded()))
        let pixelHeight = max(1, Int((bounds.height * renderScale).rounded()))

        guard let context = CGContext(
            data: nil,
            width: pixelWidth,
            height: pixelHeight,
            bitsPerComponent: 8,
            bytesPerRow: 0,
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ) else {
            return nil
        }

        context.setFillColor(CGColor.white)
        context.fill(CGRect(x: 0, y: 0, width: pixelWidth, height: pixelHeight))

        context.saveGState()
        context.scaleBy(x: renderScale, y: renderScale)
        context.translateBy(x: -bounds.origin.x, y: -bounds.origin.y)
        page.draw(with: .mediaBox, to: context)
        context.restoreGState()

        return context.makeImage()
    }
}
