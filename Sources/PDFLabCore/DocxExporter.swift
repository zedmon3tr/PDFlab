/// 将 ComposedDocument 渲染为最小合法 OOXML .docx 并写入磁盘。
///
/// 结构:一个包含以下三个成员的 zip 包
///   - [Content_Types].xml
///   - _rels/.rels
///   - word/document.xml
/// 每个 ComposedBlock 渲染为一个 `<w:p>`;`.pageBreak` 渲染为分页符段落。
public struct DocxExporter: Exporter {
    public init() {}

    public func export(_ doc: ComposedDocument, to url: URL, uiLanguageChinese: Bool) throws {
        let documentXML = Self.renderDocumentXML(doc)

        let fileManager = FileManager.default
        let workDir = fileManager.temporaryDirectory.appendingPathComponent(UUID().uuidString)

        do {
            let relsDir = workDir.appendingPathComponent("_rels")
            let wordDir = workDir.appendingPathComponent("word")
            try fileManager.createDirectory(at: relsDir, withIntermediateDirectories: true)
            try fileManager.createDirectory(at: wordDir, withIntermediateDirectories: true)

            try Self.contentTypesXML.write(
                to: workDir.appendingPathComponent("[Content_Types].xml"),
                atomically: true,
                encoding: .utf8
            )
            try Self.relsXML.write(
                to: relsDir.appendingPathComponent(".rels"),
                atomically: true,
                encoding: .utf8
            )
            try documentXML.write(
                to: wordDir.appendingPathComponent("document.xml"),
                atomically: true,
                encoding: .utf8
            )

            if fileManager.fileExists(atPath: url.path) {
                try fileManager.removeItem(at: url)
            }

            let process = Process()
            process.executableURL = URL(fileURLWithPath: "/usr/bin/zip")
            process.currentDirectoryURL = workDir
            process.arguments = [
                "-X", "-r", url.path,
                "[Content_Types].xml", "_rels", "word",
            ]
            let pipe = Pipe()
            process.standardOutput = pipe
            process.standardError = pipe
            try process.run()
            process.waitUntilExit()

            guard process.terminationStatus == 0 else {
                let data = pipe.fileHandleForReading.readDataToEndOfFile()
                let message = String(data: data, encoding: .utf8) ?? "zip failed"
                throw PDFLabError.exportWriteFailed(message)
            }
        } catch let error as PDFLabError {
            try? fileManager.removeItem(at: workDir)
            throw error
        } catch {
            try? fileManager.removeItem(at: workDir)
            throw PDFLabError.exportWriteFailed(error.localizedDescription)
        }

        try? fileManager.removeItem(at: workDir)
    }

    // MARK: - XML rendering

    private static func renderDocumentXML(_ doc: ComposedDocument) -> String {
        var body = ""
        var lastBreakIndex = 0
        for (index, block) in doc.blocks.enumerated() {
            switch block {
            case .pageBreak(let pageIndex):
                // 按 pageIndex 差值补分页符:空白源页保留为空白输出页,
                // 且 break(0) 不再在文档开头多插一页(内容本就从第 1 页开始)。
                let breaks = max(pageIndex - lastBreakIndex, 0)
                lastBreakIndex = max(pageIndex, lastBreakIndex)
                for _ in 0..<breaks {
                    body += "<w:p><w:r><w:br w:type=\"page\"/></w:r></w:p>"
                }
            case .sourceText(let textBlock):
                body += paragraphXML(
                    for: textBlock,
                    grayLevel: ExportTypography.grayLevel(blockAt: index, in: doc.blocks),
                    spacingAfter: ExportTypography.spacingAfter(blockAt: index, in: doc.blocks)
                )
            case .translatedText(let textBlock):
                body += paragraphXML(
                    for: textBlock,
                    grayLevel: 0,
                    spacingAfter: ExportTypography.spacingAfter(blockAt: index, in: doc.blocks)
                )
            }
        }

        return """
        <?xml version="1.0" encoding="UTF-8" standalone="yes"?>
        <w:document xmlns:w="http://schemas.openxmlformats.org/wordprocessingml/2006/main"><w:body>\(body)\(sectionPropertiesXML)</w:body></w:document>
        """
    }

    private static func paragraphXML(
        for block: ComposedTextBlock,
        grayLevel: CGFloat,
        spacingAfter: ExportParagraphSpacing
    ) -> String {
        let layout = ExportTypography.layout(for: block.text, spacingAfter: spacingAfter)
        let line = twips(layout.lineHeight)
        let after = twips(layout.paragraphSpacing)
        let indent = layout.firstLineIndent > 0
            ? "<w:ind w:firstLine=\"\(twips(layout.firstLineIndent))\"/>"
            : ""
        let color = grayLevel > 0 ? "<w:color w:val=\"4D4D4D\"/>" : "<w:color w:val=\"000000\"/>"
        let preserveSpace = block.text.first?.isWhitespace == true || block.text.last?.isWhitespace == true
        let spaceAttribute = preserveSpace ? " xml:space=\"preserve\"" : ""
        return "<w:p><w:pPr><w:spacing w:line=\"\(line)\" w:lineRule=\"exact\" w:after=\"\(after)\"/>\(indent)<w:jc w:val=\"left\"/></w:pPr><w:r><w:rPr><w:sz w:val=\"24\"/>\(color)</w:rPr><w:t\(spaceAttribute)>\(xmlEscape(block.text))</w:t></w:r></w:p>"
    }

    private static func twips(_ points: CGFloat) -> Int {
        Int((points * 20).rounded())
    }

    private static func xmlEscape(_ text: String) -> String {
        var sanitized = ""
        for scalar in text.unicodeScalars {
            let value = scalar.value
            if value == 0x9 || value == 0xA || value == 0xD ||
                (0x20...0xD7FF).contains(value) ||
                (0xE000...0xFFFD).contains(value) ||
                (0x10000...0x10FFFF).contains(value) {
                sanitized.unicodeScalars.append(scalar)
            } else {
                sanitized.append("�")
            }
        }
        var escaped = sanitized
        escaped = escaped.replacingOccurrences(of: "&", with: "&amp;")
        escaped = escaped.replacingOccurrences(of: "<", with: "&lt;")
        escaped = escaped.replacingOccurrences(of: ">", with: "&gt;")
        escaped = escaped.replacingOccurrences(of: "\"", with: "&quot;")
        escaped = escaped.replacingOccurrences(of: "'", with: "&apos;")
        return escaped
    }

    private static let sectionPropertiesXML = "<w:sectPr><w:pgSz w:w=\"11906\" w:h=\"16838\"/><w:pgMar w:top=\"1200\" w:right=\"1200\" w:bottom=\"1200\" w:left=\"1200\"/></w:sectPr>"

    // MARK: - Static package members

    private static let contentTypesXML = """
    <?xml version="1.0" encoding="UTF-8" standalone="yes"?>
    <Types xmlns="http://schemas.openxmlformats.org/package/2006/content-types"><Default Extension="rels" ContentType="application/vnd.openxmlformats-package.relationships+xml"/><Default Extension="xml" ContentType="application/xml"/><Override PartName="/word/document.xml" ContentType="application/vnd.openxmlformats-officedocument.wordprocessingml.document.main+xml"/></Types>
    """

    private static let relsXML = """
    <?xml version="1.0" encoding="UTF-8" standalone="yes"?>
    <Relationships xmlns="http://schemas.openxmlformats.org/package/2006/relationships"><Relationship Id="rId1" Type="http://schemas.openxmlformats.org/officeDocument/2006/relationships/officeDocument" Target="word/document.xml"/></Relationships>
    """
}
