import CoreGraphics
import CoreImage

public enum ImagePreprocessor {
    private static let context = CIContext(options: nil)

    /// 灰度 + 对比度增强 + 去斜 + 降噪(CoreImage: CIColorControls/CIDocumentEnhancer 路径),仅供低置信度页重试用。
    public static func enhance(_ image: CGImage) -> CGImage {
        let input = CIImage(cgImage: image)
        let colorControlled = input.applyingFilter("CIColorControls", parameters: [
            kCIInputSaturationKey: 0,
            kCIInputContrastKey: 1.25
        ])
        let denoised = colorControlled.applyingFilter("CINoiseReduction", parameters: [
            "inputNoiseLevel": 0.02,
            "inputSharpness": 0.40
        ])

        let output: CIImage
        if let documentEnhanced = CIFilter(name: "CIDocumentEnhancer", parameters: [
            kCIInputImageKey: denoised
        ])?.outputImage {
            output = documentEnhanced
        } else {
            output = denoised
        }

        let extent = CGRect(x: 0, y: 0, width: image.width, height: image.height)
        return context.createCGImage(output, from: extent) ?? image
    }
}
