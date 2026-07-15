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
            case .sourceText(let block):
                output += Self.markdownText(block) + "\n\n"
            case .translatedText(let block):
                output += Self.markdownText(block) + "\n\n"
            case .tableRegion(let table):
                let label = uiLanguageChinese ? "[表格]" : "[Table]"
                let content = table.displayedRows.joined(separator: "\n")
                let fence = String(repeating: "`", count: max(3, Self.longestBacktickRun(in: content) + 1))
                output += label + "\n\n\(fence)\n" + content + "\n\(fence)\n\n"
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

    private static func markdownText(_ block: ComposedTextBlock) -> String {
        guard case let .heading(level) = block.kind else { return block.text }
        return String(repeating: "#", count: min(max(level, 1), 3)) + " " + block.text
    }

    private static func longestBacktickRun(in text: String) -> Int {
        var longest = 0
        var current = 0
        for character in text {
            if character == "`" {
                current += 1
                longest = max(longest, current)
            } else {
                current = 0
            }
        }
        return longest
    }
}
