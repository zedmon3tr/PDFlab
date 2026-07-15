import Testing
@testable import PDFLabCore

@Suite struct MarkdownExporterTests {
    @Test func rendersBilingualDocumentWithChinesePageHeadings() throws {
        let doc = ComposedDocument(
            blocks: [
                .pageBreak(pageIndex: 0),
                .sourceText("Hello world."),
                .translatedText("你好世界。"),
                .pageBreak(pageIndex: 1),
                .sourceText("Second."),
                .translatedText("第二。"),
            ],
            direction: .enToZh
        )
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString)
            .appendingPathExtension("md")
        defer { try? FileManager.default.removeItem(at: url) }

        try MarkdownExporter().export(doc, to: url, uiLanguageChinese: true)

        let expected = """
        ## 第 1 页

        Hello world.

        你好世界。

        ## 第 2 页

        Second.

        第二。

        """
        let actual = try String(contentsOf: url, encoding: .utf8)
        #expect(actual == expected)
    }

    @Test func rendersEnglishPageHeadingsWhenUILanguageIsNotChinese() throws {
        let doc = ComposedDocument(
            blocks: [
                .pageBreak(pageIndex: 0),
                .sourceText("Hello world."),
            ],
            direction: .enToZh
        )
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString)
            .appendingPathExtension("md")
        defer { try? FileManager.default.removeItem(at: url) }

        try MarkdownExporter().export(doc, to: url, uiLanguageChinese: false)

        let expected = """
        ## Page 1

        Hello world.

        """
        let actual = try String(contentsOf: url, encoding: .utf8)
        #expect(actual == expected)
    }

    @Test func throwsExportWriteFailedWhenPathIsUnwritable() throws {
        let doc = ComposedDocument(blocks: [.sourceText("x")], direction: nil)
        let url = URL(fileURLWithPath: "/this-should-not-be-writable-\(UUID().uuidString).md")

        #expect(throws: PDFLabError.self) {
            try MarkdownExporter().export(doc, to: url, uiLanguageChinese: true)
        }
    }

    @Test func rendersSemanticHeadingLevels() throws {
        let doc = ComposedDocument(blocks: [
            .sourceText(.init(text: "Title", kind: .heading(level: 1))),
            .translatedText(.init(text: "标题", kind: .heading(level: 1))),
            .sourceText(.init(text: "Body")),
        ], direction: .enToZh)
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: url) }
        try MarkdownExporter().export(doc, to: url, uiLanguageChinese: true)
        #expect(try String(contentsOf: url, encoding: .utf8) == "# Title\n\n# 标题\n\nBody\n")
    }
}
