import Testing
@testable import PDFLabApp
@testable import PDFLabCore

@Suite struct PreviewRowTests {
    @Test func cleanupSummaryFormatsIntegerCountsForEveryLocalization() {
        let summary = TextCleanupSummary(
            repeatedEdgeLines: 12,
            pageNumbers: 3,
            ocrJunkLines: 45
        )
        let expected = [
            "已过滤：页眉页脚 12 条，页码 3 条，OCR 垃圾行 45 条",
            "Filtered: 12 header/footer, 3 page number, 45 OCR junk line(s)"
        ]

        let formatted = L10n.allLocalizedValues("translate.cleanupSummary")
            .map { PreviewView.cleanupSummaryText(summary, format: $0) }

        #expect(formatted == expected)
    }

    @Test func translationOnlyPreviewGroupsParagraphsWithinEachPage() {
        let document = ComposedDocument(
            blocks: [
                .pageBreak(pageIndex: 0),
                .translatedText("页面一第一段"),
                .translatedText("页面一第二段"),
                .pageBreak(pageIndex: 1),
                .translatedText("页面二第一段")
            ],
            direction: .enToZh
        )

        let rows = PreviewRow.rows(from: document, content: .translationOnly)

        #expect(rows == [
            PreviewRow(pageIndex: 0),
            PreviewRow(translation: "页面一第一段\n\n页面一第二段"),
            PreviewRow(pageIndex: 1),
            PreviewRow(translation: "页面二第一段")
        ])
    }

    @Test func bilingualPreviewGroupsSourceAndTranslationWithinEachPage() {
        let document = ComposedDocument(
            blocks: [
                .pageBreak(pageIndex: 0),
                .sourceText("Source 1"),
                .translatedText("译文 1"),
                .sourceText("Source 2"),
                .translatedText("译文 2")
            ],
            direction: .enToZh
        )

        let rows = PreviewRow.rows(from: document, content: .bilingual)

        #expect(rows == [
            PreviewRow(pageIndex: 0),
            PreviewRow(source: "Source 1\n\nSource 2", translation: "译文 1\n\n译文 2")
        ])
    }


    @Test func semanticRowsRemainSeparateAndPreserveKind() {
        let document = ComposedDocument(blocks: [
            .sourceText(.init(text: "Title", groupID: .init("h"), kind: .heading(level: 1))),
            .translatedText(.init(text: "标题", groupID: .init("h"), kind: .heading(level: 1))),
            .sourceText(.init(text: "Footnote", kind: .footnote)),
        ], direction: .enToZh)
        #expect(PreviewRow.rows(from: document, content: .bilingual) == [
            PreviewRow(source: "Title", translation: "标题", kind: .heading(level: 1)),
            PreviewRow(source: "Footnote", kind: .footnote),
        ])
    }
}
