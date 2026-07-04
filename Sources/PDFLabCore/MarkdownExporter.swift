/// 导出器协议:将组装后的文档写入磁盘。任务15(PDF)、16(DOCX)遵循此协议。
public protocol Exporter {
    /// 写文件;磁盘/权限失败抛 exportWriteFailed(原因)。
    func export(_ doc: ComposedDocument, to url: URL, uiLanguageChinese: Bool) throws
}

/// 将 ComposedDocument 渲染为 Markdown 纯文本并写入 UTF-8 文件。
public struct MarkdownExporter: Exporter {
    public init() {}

    public func export(_ doc: ComposedDocument, to url: URL, uiLanguageChinese: Bool) throws {
        var output = ""
        for block in doc.blocks {
            switch block {
            case .pageBreak(let pageIndex):
                let heading = uiLanguageChinese
                    ? "## 第 \(pageIndex + 1) 页"
                    : "## Page \(pageIndex + 1)"
                output += heading + "\n\n"
            case .sourceText(let text):
                output += text + "\n\n"
            case .translatedText(let text):
                output += text + "\n\n"
            }
        }
        if output.hasSuffix("\n\n") {
            output.removeLast()
        }

        do {
            try output.write(to: url, atomically: true, encoding: .utf8)
        } catch {
            throw PDFLabError.exportWriteFailed(error.localizedDescription)
        }
    }
}
