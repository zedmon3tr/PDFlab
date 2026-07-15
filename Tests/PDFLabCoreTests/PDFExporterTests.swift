import Testing
import PDFKit
@testable import PDFLabCore

@Suite struct PDFExporterTests {
    @Test func exportsBilingualPageAlignedDocumentAcrossPages() throws {
        let firstParagraphOpening = "The quick brown fox jumps over the lazy dog. "
        let doc = ComposedDocument(
            blocks: [
                .pageBreak(pageIndex: 0),
                .sourceText(firstParagraphOpening + "This is the first page source text."),
                .translatedText("这是第一页的译文。"),
                .pageBreak(pageIndex: 1),
                .sourceText("This text only belongs on the second page."),
                .translatedText("这段文字只应出现在第二页。"),
            ],
            direction: .enToZh
        )
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString)
            .appendingPathExtension("pdf")
        defer { try? FileManager.default.removeItem(at: url) }

        try PDFExporter().export(doc, to: url, uiLanguageChinese: true)

        guard let pdfDoc = PDFDocument(url: url) else {
            Issue.record("Failed to reopen exported PDF")
            return
        }

        #expect(pdfDoc.pageCount >= 2)

        let firstPageText = pdfDoc.page(at: 0)?.string ?? ""
        let openingPrefix = String(firstParagraphOpening.prefix(10))
        #expect(firstPageText.contains(openingPrefix))
        #expect(!firstPageText.contains("only belongs on the second page"))

        var foundSecondPageText = false
        for i in 1..<pdfDoc.pageCount {
            if let text = pdfDoc.page(at: i)?.string, text.contains("only belongs on the second page") {
                foundSecondPageText = true
            }
        }
        #expect(foundSecondPageText)
    }

    @Test func preservesAbsolutePagePositionsAcrossEmptySourcePages() throws {
        // 源页 1 为空:输出页数必须仍等于源页数,页 2 的文本落在输出第 3 页(下标 2)。
        let doc = ComposedDocument(
            blocks: [
                .pageBreak(pageIndex: 0),
                .sourceText("Text that belongs to the first source page."),
                .pageBreak(pageIndex: 2),
                .sourceText("Text that belongs to the third source page."),
            ],
            direction: .enToZh
        )
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString)
            .appendingPathExtension("pdf")
        defer { try? FileManager.default.removeItem(at: url) }

        try PDFExporter().export(doc, to: url, uiLanguageChinese: true)

        guard let pdfDoc = PDFDocument(url: url) else {
            Issue.record("Failed to reopen exported PDF")
            return
        }

        #expect(pdfDoc.pageCount == 3)
        #expect((pdfDoc.page(at: 0)?.string ?? "").contains("first source page"))
        let middle = (pdfDoc.page(at: 1)?.string ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        #expect(middle.isEmpty)
        #expect((pdfDoc.page(at: 2)?.string ?? "").contains("third source page"))
    }

    @Test func trailingPageBreakProducesTrailingBlankPages() throws {
        // 末尾空白源页(composer 补的尾部 break)要成为真实空白输出页。
        let doc = ComposedDocument(
            blocks: [
                .pageBreak(pageIndex: 0),
                .sourceText("Only page one has any content."),
                .pageBreak(pageIndex: 2),
            ],
            direction: .enToZh
        )
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString)
            .appendingPathExtension("pdf")
        defer { try? FileManager.default.removeItem(at: url) }

        try PDFExporter().export(doc, to: url, uiLanguageChinese: true)

        guard let pdfDoc = PDFDocument(url: url) else {
            Issue.record("Failed to reopen exported PDF")
            return
        }

        #expect(pdfDoc.pageCount == 3)
    }

    @Test func exportsVeryLongParagraphWithoutCrashingAndSpansMultiplePages() throws {
        let sentence = "This is a very long repeated sentence used to force pagination overflow. "
        let longText = String(repeating: sentence, count: 500)
        let doc = ComposedDocument(
            blocks: [
                .pageBreak(pageIndex: 0),
                .sourceText(longText),
            ],
            direction: .enToZh
        )
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString)
            .appendingPathExtension("pdf")
        defer { try? FileManager.default.removeItem(at: url) }

        try PDFExporter().export(doc, to: url, uiLanguageChinese: true)

        guard let pdfDoc = PDFDocument(url: url) else {
            Issue.record("Failed to reopen exported PDF")
            return
        }

        #expect(pdfDoc.pageCount > 1)

        let exportedText = (0..<pdfDoc.pageCount)
            .compactMap { pdfDoc.page(at: $0)?.string }
            .joined(separator: " ")
        #expect(exportedText.contains("This is a very long repeated sentence"))
        #expect(exportedText.contains("pagination overflow"))
        let compactText = exportedText.filter { !$0.isWhitespace }
        #expect(compactText.components(separatedBy: "Thisisaverylongrepeatedsentence").count - 1 == 500)
    }

    @Test func pdfParagraphAttributesUseSharedTypography() throws {
        let attributed = PDFExporter.attributedString(
            for: "「这是中文正文」",
            grayLevel: ExportTypography.sourceGray,
            spacingAfter: .outer
        )
        let style = try #require(attributed.attribute(
            NSAttributedString.Key(rawValue: kCTParagraphStyleAttributeName as String),
            at: 0,
            effectiveRange: nil
        )) as! CTParagraphStyle
        var lineSpacing: CGFloat = 0
        var firstLineIndent: CGFloat = 0
        #expect(CTParagraphStyleGetValueForSpecifier(style, .maximumLineHeight, MemoryLayout<CGFloat>.size, &lineSpacing))
        #expect(CTParagraphStyleGetValueForSpecifier(style, .firstLineHeadIndent, MemoryLayout<CGFloat>.size, &firstLineIndent))
        #expect(lineSpacing == ExportTypography.lineHeight)
        #expect(firstLineIndent == 24)
    }

    @Test func semanticPDFAttributesEmphasizeHeadingAndShrinkFootnote() throws {
        let heading = PDFExporter.attributedString(
            for: "Heading", grayLevel: 0, spacingAfter: .outer, kind: .heading(level: 1)
        )
        let footnote = PDFExporter.attributedString(
            for: "1 Note", grayLevel: 0, spacingAfter: .outer, kind: .footnote
        )
        let headingFont = try #require(heading.attribute(.font, at: 0, effectiveRange: nil)) as! CTFont
        let footnoteFont = try #require(footnote.attribute(.font, at: 0, effectiveRange: nil)) as! CTFont
        #expect(CTFontGetSize(headingFont) == 20)
        #expect(CTFontGetSymbolicTraits(headingFont).contains(.traitBold))
        #expect(CTFontGetSize(footnoteFont) == 10)
    }

    @Test func throwsExportWriteFailedWhenPathIsUnwritable() throws {
        let doc = ComposedDocument(blocks: [.sourceText("x")], direction: nil)
        let url = URL(fileURLWithPath: "/this-should-not-be-writable-\(UUID().uuidString).pdf")

        #expect(throws: PDFLabError.self) {
            try PDFExporter().export(doc, to: url, uiLanguageChinese: true)
        }
    }
}
