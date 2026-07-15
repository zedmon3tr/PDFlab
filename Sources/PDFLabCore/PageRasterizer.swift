import CoreGraphics
import PDFKit

public enum PageRasterizer {
    private static let defaultDPI: CGFloat = 350
    private static let minDPI: CGFloat = 300
    private static let maxDPI: CGFloat = 400
    private static let maxPixels = 6000

    /// 按 targetDPI(默认 350,夹在 300...400)渲染页面;单边超过 maxPixels(6000)时整体降比例。
    public static func rasterize(page: PDFPage, targetDPI: CGFloat = 350) -> CGImage? {
        let bounds = page.bounds(for: .mediaBox)
        guard bounds.width > 0, bounds.height > 0 else {
            return nil
        }

        let normalizedDPI = targetDPI.isFinite ? targetDPI : defaultDPI
        let clampedDPI = min(max(normalizedDPI, minDPI), maxDPI)
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
        page.draw(with: .mediaBox, to: context)
        context.restoreGState()

        return context.makeImage()
    }

    /// Returns a new image rotated clockwise by a right angle.
    public static func rotated(_ image: CGImage, clockwiseDegrees: Int) -> CGImage? {
        let degrees = ((clockwiseDegrees % 360) + 360) % 360
        guard degrees == 0 || degrees == 90 || degrees == 180 || degrees == 270 else { return nil }
        if degrees == 0 { return image }

        let swapsDimensions = degrees == 90 || degrees == 270
        let width = swapsDimensions ? image.height : image.width
        let height = swapsDimensions ? image.width : image.height
        guard let context = CGContext(
            data: nil,
            width: width,
            height: height,
            bitsPerComponent: 8,
            bytesPerRow: 0,
            space: image.colorSpace ?? CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ) else { return nil }

        switch degrees {
        case 90:
            context.translateBy(x: 0, y: CGFloat(height))
            context.rotate(by: -.pi / 2)
        case 180:
            context.translateBy(x: CGFloat(width), y: CGFloat(height))
            context.rotate(by: .pi)
        case 270:
            context.translateBy(x: CGFloat(width), y: 0)
            context.rotate(by: .pi / 2)
        default:
            break
        }
        context.interpolationQuality = .high
        context.draw(image, in: CGRect(x: 0, y: 0, width: image.width, height: image.height))
        return context.makeImage()
    }
}
