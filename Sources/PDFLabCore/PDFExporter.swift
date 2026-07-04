import CoreText
import CoreGraphics

/// 将 ComposedDocument 渲染为 PDF:A4 页面,CoreText 逐块排版,列满自动换页,
/// 遇 .pageBreak 且当前页非空时强制开新页(按页对应模式)。
public struct PDFExporter: Exporter {
    private let pageWidth: CGFloat = 595
    private let pageHeight: CGFloat = 842
    private let margin: CGFloat = 54
    private let fontSize: CGFloat = 12

    public init() {}

    public func export(_ doc: ComposedDocument, to url: URL, uiLanguageChinese: Bool) throws {
        var mediaBox = CGRect(x: 0, y: 0, width: pageWidth, height: pageHeight)

        guard let context = CGContext(url as CFURL, mediaBox: &mediaBox, nil) else {
            throw PDFLabError.exportWriteFailed("Unable to create PDF context for \(url.path)")
        }

        let contentWidth = pageWidth - 2 * margin
        let contentTop = pageHeight - margin
        let contentBottom = margin

        let state = PageState(context: context, contentTop: contentTop)
        state.beginPage()

        for block in doc.blocks {
            switch block {
            case .pageBreak:
                if !state.pageIsEmpty {
                    state.endPage()
                    state.beginPage()
                }
            case .sourceText(let text):
                drawBlock(
                    text: text,
                    grayLevel: 0.35,
                    contentWidth: contentWidth,
                    contentBottom: contentBottom,
                    state: state
                )
            case .translatedText(let text):
                drawBlock(
                    text: text,
                    grayLevel: 0.0,
                    contentWidth: contentWidth,
                    contentBottom: contentBottom,
                    state: state
                )
            }
        }

        state.endPage()
        context.closePDF()
    }

    /// 跟踪当前页排版状态(游标位置、是否为空),用类避免闭包捕获 inout 造成独占访问冲突。
    private final class PageState {
        let context: CGContext
        let contentTop: CGFloat
        var cursorY: CGFloat
        var pageIsEmpty: Bool = true

        init(context: CGContext, contentTop: CGFloat) {
            self.context = context
            self.contentTop = contentTop
            self.cursorY = contentTop
        }

        func beginPage() {
            context.beginPDFPage(nil)
            cursorY = contentTop
            pageIsEmpty = true
        }

        func endPage() {
            context.endPDFPage()
        }
    }

    /// 绘制单个文本块,必要时跨页流式排版。
    private func drawBlock(
        text: String,
        grayLevel: CGFloat,
        contentWidth: CGFloat,
        contentBottom: CGFloat,
        state: PageState
    ) {
        guard !text.isEmpty else { return }

        let attributed = attributedString(for: text, grayLevel: grayLevel)
        let framesetter = CTFramesetterCreateWithAttributedString(attributed)
        var charIndex = 0
        let totalLength = attributed.length

        // 段前留一点垂直间距(除非页面刚开始)。
        if !state.pageIsEmpty {
            state.cursorY -= fontSize * 0.6
        }

        while charIndex < totalLength {
            var availableHeight = state.cursorY - contentBottom

            // 当前页剩余空间过小,直接换页再排版。
            if availableHeight < fontSize * 1.2 {
                state.endPage()
                state.beginPage()
                availableHeight = state.cursorY - contentBottom
            }

            let range = CFRangeMake(charIndex, totalLength - charIndex)
            let constraint = CGSize(width: contentWidth, height: availableHeight)
            var consumedRange = CFRangeMake(0, 0)

            let suggestedSize = withUnsafeMutablePointer(to: &consumedRange) { fitRangePtr in
                CTFramesetterSuggestFrameSizeWithConstraints(
                    framesetter, range, nil, constraint, fitRangePtr
                )
            }
            var frameHeight = suggestedSize.height

            // 如果一个字符都放不下(极端情况,比如剩余高度太小),强制换页重试。
            if consumedRange.length == 0 {
                state.endPage()
                state.beginPage()
                availableHeight = state.cursorY - contentBottom
                let retryConstraint = CGSize(width: contentWidth, height: availableHeight)
                let retrySize = withUnsafeMutablePointer(to: &consumedRange) { fitRangePtr in
                    CTFramesetterSuggestFrameSizeWithConstraints(
                        framesetter, range, nil, retryConstraint, fitRangePtr
                    )
                }
                frameHeight = retrySize.height
                if consumedRange.length == 0 {
                    // 仍然放不下(理论上不会发生),跳出避免死循环。
                    break
                }
            }

            let frameOriginY = state.cursorY - frameHeight
            let path = CGPath(
                rect: CGRect(x: margin, y: frameOriginY, width: contentWidth, height: frameHeight),
                transform: nil
            )
            let ctFrame = CTFramesetterCreateFrame(framesetter, consumedRange, path, nil)
            CTFrameDraw(ctFrame, state.context)

            state.cursorY = frameOriginY
            state.pageIsEmpty = false
            charIndex += consumedRange.length

            if charIndex < totalLength {
                state.endPage()
                state.beginPage()
            }
        }
    }

    private func attributedString(for text: String, grayLevel: CGFloat) -> NSAttributedString {
        let font = CTFontCreateUIFontForLanguage(.system, fontSize, nil)
            ?? CTFontCreateWithName("Helvetica" as CFString, fontSize, nil)
        let color = CGColor(gray: grayLevel, alpha: 1.0)
        let attributes: [NSAttributedString.Key: Any] = [
            .font: font,
            .foregroundColor: color,
        ]
        return NSAttributedString(string: text, attributes: attributes)
    }
}
