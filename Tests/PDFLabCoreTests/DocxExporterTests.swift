import Testing
@testable import PDFLabCore

@Suite struct DocxExporterTests {
    private func runProcess(_ path: String, _ args: [String]) throws -> String {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: path)
        process.arguments = args
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = pipe
        try process.run()
        process.waitUntilExit()
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        return String(data: data, encoding: .utf8) ?? ""
    }

    @Test func exportsMinimalValidDocxArchive() throws {
        let doc = ComposedDocument(
            blocks: [
                .pageBreak(pageIndex: 0),
                .sourceText("Hello & world"),
                .translatedText("你好 <世界>"),
                .pageBreak(pageIndex: 1),
                .sourceText("Second page"),
            ],
            direction: .enToZh
        )
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString)
            .appendingPathExtension("docx")
        defer { try? FileManager.default.removeItem(at: url) }

        try DocxExporter().export(doc, to: url, uiLanguageChinese: true)

        // 1. First two bytes are "PK" (zip signature)
        let handle = try FileHandle(forReadingFrom: url)
        let header = handle.readData(ofLength: 2)
        try handle.close()
        #expect(header == Data([0x50, 0x4B]))

        // 2. unzip -l lists the three member files
        let listing = try runProcess("/usr/bin/unzip", ["-l", url.path])
        #expect(listing.contains("[Content_Types].xml"))
        #expect(listing.contains("_rels/.rels"))
        #expect(listing.contains("word/document.xml"))
        #expect(listing.contains("word/styles.xml"))

        // 3. extracted document.xml contains escaped text and page break marker
        let extractDir = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: extractDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: extractDir) }
        _ = try runProcess("/usr/bin/unzip", ["-o", url.path, "-d", extractDir.path])

        let documentXMLURL = extractDir.appendingPathComponent("word/document.xml")
        let documentXML = try String(contentsOf: documentXMLURL, encoding: .utf8)
        #expect(documentXML.contains("<w:t>Hello &amp; world</w:t>"))
        #expect(documentXML.contains("w:type=\"page\""))
    }

    @Test func registersAndUsesHeadingStylesWithOutlineLevels() throws {
        let doc = ComposedDocument(blocks: [
            .sourceText(.init(text: "Heading", kind: .heading(level: 2)))
        ], direction: nil)
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString).appendingPathExtension("docx")
        defer { try? FileManager.default.removeItem(at: url) }
        try DocxExporter().export(doc, to: url, uiLanguageChinese: true)
        let document = try runProcess("/usr/bin/unzip", ["-p", url.path, "word/document.xml"])
        let styles = try runProcess("/usr/bin/unzip", ["-p", url.path, "word/styles.xml"])
        let rels = try runProcess("/usr/bin/unzip", ["-p", url.path, "word/_rels/document.xml.rels"])
        #expect(document.contains("<w:pStyle w:val=\"Heading2\"/>"))
        #expect(styles.contains("w:styleId=\"Heading1\""))
        #expect(styles.contains("<w:outlineLvl w:val=\"2\"/>"))
        #expect(rels.contains("relationships/styles"))
    }

    @Test func preservesAbsolutePagePositionsAcrossEmptySourcePages() throws {
        // 空源页要产生对应数量的分页符:break(0) 不产生(内容本就从第 1 页开始),
        // break(2) 距上一个 break(0) 差 2,须产生两个分页符段落。
        let doc = ComposedDocument(
            blocks: [
                .pageBreak(pageIndex: 0),
                .sourceText("First page text"),
                .pageBreak(pageIndex: 2),
                .sourceText("Third page text"),
            ],
            direction: .enToZh
        )
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString)
            .appendingPathExtension("docx")
        defer { try? FileManager.default.removeItem(at: url) }

        try DocxExporter().export(doc, to: url, uiLanguageChinese: true)

        let extractDir = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: extractDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: extractDir) }
        _ = try runProcess("/usr/bin/unzip", ["-o", url.path, "-d", extractDir.path])

        let documentXML = try String(
            contentsOf: extractDir.appendingPathComponent("word/document.xml"),
            encoding: .utf8
        )
        let breakParagraph = "<w:p><w:r><w:br w:type=\"page\"/></w:r></w:p>"
        let breakCount = documentXML.components(separatedBy: breakParagraph).count - 1
        #expect(breakCount == 2)
        // 两个分页符必须相邻(中间的空白页),且位于两段文本之间。
        #expect(documentXML.contains(breakParagraph + breakParagraph))
        #expect(!documentXML.hasPrefix("<w:p><w:r><w:br"))
    }

    @Test func writesSharedLineParagraphAndChineseIndentMetrics() throws {
        let groupID = TranslationUnitID("paragraph:1")
        let doc = ComposedDocument(blocks: [
            .sourceText(.init(text: "Source paragraph", groupID: groupID, kind: .body)),
            .translatedText(.init(text: "「这是中文译文」", groupID: groupID, kind: .body)),
            .sourceText(.init(text: "Next paragraph", groupID: .init("paragraph:2"), kind: .body)),
        ], direction: .enToZh)
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString).appendingPathExtension("docx")
        defer { try? FileManager.default.removeItem(at: url) }

        try DocxExporter().export(doc, to: url, uiLanguageChinese: true)
        let xml = try runProcess("/usr/bin/unzip", ["-p", url.path, "word/document.xml"])

        #expect(xml.contains("w:line=\"336\""))
        #expect(xml.contains("w:lineRule=\"exact\""))
        #expect(xml.contains("w:firstLine=\"480\""))
        #expect(xml.contains("w:after=\"60\""))
        #expect(xml.contains("w:jc w:val=\"left\""))
        #expect(xml.contains("w:color w:val=\"4D4D4D\""))
        #expect(xml.contains("<w:pgSz w:w=\"11906\" w:h=\"16838\"/>"))
        #expect(xml.contains("<w:pgMar w:top=\"1200\" w:right=\"1200\" w:bottom=\"1200\" w:left=\"1200\"/>"))
    }

    @Test func extractionOnlySourceUsesBlackAndPreservesValidXMLText() throws {
        let text = "  A & 文\u{0001}字  "
        let doc = ComposedDocument(blocks: [.sourceText(.init(
            text: text,
            groupID: .init("paragraph:1")
        ))], direction: nil)
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString).appendingPathExtension("docx")
        defer { try? FileManager.default.removeItem(at: url) }

        try DocxExporter().export(doc, to: url, uiLanguageChinese: true)
        let xml = try runProcess("/usr/bin/unzip", ["-p", url.path, "word/document.xml"])

        #expect(xml.contains("w:color w:val=\"000000\""))
        #expect(!xml.contains("w:color w:val=\"4D4D4D\""))
        #expect(xml.contains("<w:t xml:space=\"preserve\">  A &amp; 文�字  </w:t>"))
        #expect(!xml.unicodeScalars.contains { $0.value == 1 })
    }

    @Test func throwsExportWriteFailedWhenPathIsUnwritable() throws {
        let doc = ComposedDocument(blocks: [.sourceText("x")], direction: nil)
        let url = URL(fileURLWithPath: "/this-should-not-be-writable-\(UUID().uuidString).docx")

        #expect(throws: PDFLabError.self) {
            try DocxExporter().export(doc, to: url, uiLanguageChinese: true)
        }
    }
}
