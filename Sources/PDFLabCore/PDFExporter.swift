import CoreText
import CoreGraphics

/// 将 ComposedDocument 渲染为 PDF:A4 页面,CoreText 逐块排版,列满自动换页,
/// 遇 .pageBreak 按页号差值换页,空白源页保留为空白输出页(按页对应模式)。
public struct PDFExporter: Exporter {
    public init() {}

    public func export(_ doc: ComposedDocument, to url: URL, uiLanguageChinese: Bool) throws {
        var mediaBox = CGRect(
            x: 0,
            y: 0,
            width: ExportTypography.pageWidth,
            height: ExportTypography.pageHeight
        )

        guard let context = CGContext(url as CFURL, mediaBox: &mediaBox, nil) else {
            throw PDFLabError.exportWriteFailed("Unable to create PDF context for \(url.path)")
        }

        let contentWidth = ExportTypography.contentWidth
        let contentTop = ExportTypography.pageHeight - ExportTypography.margin
        let contentBottom = ExportTypography.margin

        let state = PageState(context: context, contentTop: contentTop)
        state.beginPage()
        var lastBreakIndex = 0

        for (index, block) in doc.blocks.enumerated() {
            switch block {
            case .pageBreak(let pageIndex):
                // 按页对应:按 pageIndex 差值换页,空白源页成为真实空白输出页,
                // 保持绝对页位(需求 3.6 页对页精确同步)。
                var newPages = pageIndex - lastBreakIndex
                if newPages <= 0, !state.pageIsEmpty {
                    newPages = 1
                }
                lastBreakIndex = max(pageIndex, lastBreakIndex)
                if newPages > 0 {
                    for _ in 0..<newPages {
                        state.endPage()
                        state.beginPage()
                    }
                }
            case .sourceText(let textBlock):
                drawBlock(
                    text: textBlock.text,
                    grayLevel: ExportTypography.sourceGray,
                    spacingAfter: ExportTypography.spacingAfter(blockAt: index, in: doc.blocks),
                    contentWidth: contentWidth,
                    contentBottom: contentBottom,
                    state: state
                )
            case .translatedText(let textBlock):
                drawBlock(
                    text: textBlock.text,
                    grayLevel: 0.0,
                    spacingAfter: ExportTypography.spacingAfter(blockAt: index, in: doc.blocks),
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
        spacingAfter: ExportParagraphSpacing,
        contentWidth: CGFloat,
        contentBottom: CGFloat,
        state: PageState
    ) {
        guard !text.isEmpty else { return }

        let attributed = Self.attributedString(
            for: text,
            grayLevel: grayLevel,
            spacingAfter: spacingAfter
        )
        let framesetter = CTFramesetterCreateWithAttributedString(attributed)
        var charIndex = 0
        let totalLength = attributed.length

        while charIndex < totalLength {
            var availableHeight = state.cursorY - contentBottom

            // 当前页剩余空间过小,直接换页再排版。
            if availableHeight < ExportTypography.lineHeight {
                state.endPage()
                state.beginPage()
                availableHeight = state.cursorY - contentBottom
            }

            let range = CFRangeMake(charIndex, totalLength - charIndex)
            let path = CGPath(
                rect: CGRect(
                    x: ExportTypography.margin,
                    y: contentBottom,
                    width: contentWidth,
                    height: availableHeight
                ),
                transform: nil
            )
            let ctFrame = CTFramesetterCreateFrame(framesetter, range, path, nil)
            let visibleRange = CTFrameGetVisibleStringRange(ctFrame)
            if visibleRange.length == 0, !state.pageIsEmpty {
                state.endPage()
                state.beginPage()
                continue
            }
            guard visibleRange.length > 0 else { break }
            CTFrameDraw(ctFrame, state.context)

            let usedSize = CTFramesetterSuggestFrameSizeWithConstraints(
                framesetter,
                visibleRange,
                nil,
                CGSize(width: contentWidth, height: .greatestFiniteMagnitude),
                nil
            )
            state.cursorY -= min(usedSize.height, availableHeight)
            state.pageIsEmpty = false
            charIndex = visibleRange.location + visibleRange.length

            if charIndex < totalLength {
                state.endPage()
                state.beginPage()
            }
        }
    }

    static func attributedString(
        for text: String,
        grayLevel: CGFloat,
        spacingAfter: ExportParagraphSpacing
    ) -> NSAttributedString {
        let font = CTFontCreateUIFontForLanguage(.system, ExportTypography.fontSize, nil)
            ?? CTFontCreateWithName("Helvetica" as CFString, ExportTypography.fontSize, nil)
        let color = CGColor(gray: grayLevel, alpha: 1.0)
        let layout = ExportTypography.layout(for: text, spacingAfter: spacingAfter)
        var alignment = CTTextAlignment.left
        var minimumLineHeight = layout.lineHeight
        var maximumLineHeight = layout.lineHeight
        var paragraphSpacing = layout.paragraphSpacing
        var firstLineIndent = layout.firstLineIndent
        let paragraphStyle = withUnsafePointer(to: &alignment) { alignmentPointer in
            withUnsafePointer(to: &minimumLineHeight) { minimumPointer in
                withUnsafePointer(to: &maximumLineHeight) { maximumPointer in
                    withUnsafePointer(to: &paragraphSpacing) { spacingPointer in
                        withUnsafePointer(to: &firstLineIndent) { indentPointer in
                            let settings = [
                                CTParagraphStyleSetting(
                                    spec: .alignment,
                                    valueSize: MemoryLayout<CTTextAlignment>.size,
                                    value: alignmentPointer
                                ),
                                CTParagraphStyleSetting(
                                    spec: .minimumLineHeight,
                                    valueSize: MemoryLayout<CGFloat>.size,
                                    value: minimumPointer
                                ),
                                CTParagraphStyleSetting(
                                    spec: .maximumLineHeight,
                                    valueSize: MemoryLayout<CGFloat>.size,
                                    value: maximumPointer
                                ),
                                CTParagraphStyleSetting(
                                    spec: .paragraphSpacing,
                                    valueSize: MemoryLayout<CGFloat>.size,
                                    value: spacingPointer
                                ),
                                CTParagraphStyleSetting(
                                    spec: .firstLineHeadIndent,
                                    valueSize: MemoryLayout<CGFloat>.size,
                                    value: indentPointer
                                ),
                            ]
                            return CTParagraphStyleCreate(settings, settings.count)
                        }
                    }
                }
            }
        }
        let attributes: [NSAttributedString.Key: Any] = [
            .font: font,
            .foregroundColor: color,
            NSAttributedString.Key(rawValue: kCTParagraphStyleAttributeName as String): paragraphStyle,
        ]
        return NSAttributedString(string: text, attributes: attributes)
    }
}
