import PDFKit

public struct PageExtraction: Sendable {
    public var pageIndex: Int
    public var lines: [TextLine]
    public var isScanned: Bool

    public init(pageIndex: Int, lines: [TextLine], isScanned: Bool) {
        self.pageIndex = pageIndex
        self.lines = lines
        self.isScanned = isScanned
    }
}

public enum PDFTextExtractor {
    public static func openDocument(at url: URL, password: String?) throws -> PDFDocument {
        guard let doc = PDFDocument(url: url) else {
            throw PDFLabError.fileUnreadable
        }
        if doc.isLocked {
            guard let password, doc.unlock(withPassword: password) else {
                throw PDFLabError.encryptedPDFWrongPassword
            }
        }
        guard doc.pageCount > 0 else {
            throw PDFLabError.fileUnreadable
        }
        return doc
    }

    public static func extractPage(_ doc: PDFDocument, pageIndex: Int) -> PageExtraction {
        guard let page = doc.page(at: pageIndex),
              let content = page.string,
              content.trimmingCharacters(in: .whitespacesAndNewlines).count >= 20 else {
            return PageExtraction(pageIndex: pageIndex, lines: [], isScanned: true)
        }

        let pageBounds = page.bounds(for: .mediaBox)
        var lines: [TextLine] = []
        for raw in content.components(separatedBy: .newlines) {
            let text = raw.trimmingCharacters(in: .whitespaces)
            guard !text.isEmpty else {
                continue
            }

            let lineIndex = lines.count
            var bbox = CGRect(x: 0.1, y: 0.9 - CGFloat(lineIndex) * 0.035, width: 0.8, height: 0.03)
            if let selection = doc.findString(text, withOptions: .literal).first(where: { $0.pages.first == page }) {
                let rect = selection.bounds(for: page)
                bbox = CGRect(
                    x: rect.minX / pageBounds.width,
                    y: rect.minY / pageBounds.height,
                    width: rect.width / pageBounds.width,
                    height: rect.height / pageBounds.height
                )
            }
            lines.append(TextLine(text: text, pageIndex: pageIndex, bbox: bbox, confidence: nil))
        }

        return PageExtraction(pageIndex: pageIndex, lines: lines, isScanned: lines.isEmpty)
    }
}
