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
        for block in doc.blocks {
            switch block {
            case .pageBreak(let pageIndex):
                // 按 pageIndex 差值补分页符:空白源页保留为空白输出页,
                // 且 break(0) 不再在文档开头多插一页(内容本就从第 1 页开始)。
                let breaks = max(pageIndex - lastBreakIndex, 0)
                lastBreakIndex = max(pageIndex, lastBreakIndex)
                for _ in 0..<breaks {
                    body += "<w:p><w:r><w:br w:type=\"page\"/></w:r></w:p>"
                }
            case .sourceText(let text):
                body += paragraphXML(for: text)
            case .translatedText(let text):
                body += paragraphXML(for: text)
            }
        }

        return """
        <?xml version="1.0" encoding="UTF-8" standalone="yes"?>
        <w:document xmlns:w="http://schemas.openxmlformats.org/wordprocessingml/2006/main"><w:body>\(body)</w:body></w:document>
        """
    }

    private static func paragraphXML(for text: String) -> String {
        "<w:p><w:r><w:t>\(xmlEscape(text))</w:t></w:r></w:p>"
    }

    private static func xmlEscape(_ text: String) -> String {
        var escaped = text
        escaped = escaped.replacingOccurrences(of: "&", with: "&amp;")
        escaped = escaped.replacingOccurrences(of: "<", with: "&lt;")
        escaped = escaped.replacingOccurrences(of: ">", with: "&gt;")
        escaped = escaped.replacingOccurrences(of: "\"", with: "&quot;")
        escaped = escaped.replacingOccurrences(of: "'", with: "&apos;")
        return escaped
    }

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
