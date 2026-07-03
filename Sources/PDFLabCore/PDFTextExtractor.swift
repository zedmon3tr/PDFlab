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
        let textLines = content.components(separatedBy: .newlines)
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
        var lines: [TextLine] = []
        var consumedOccurrences: [String: Int] = [:]
        for (lineIndex, text) in textLines.enumerated() {
            let occurrence = consumedOccurrences[text, default: 0]
            consumedOccurrences[text] = occurrence + 1

            var bbox = fallbackBBox(lineIndex: lineIndex, lineCount: textLines.count)
            if let selection = selection(for: text, on: page, in: doc, occurrence: occurrence) {
                let rect = selection.bounds(for: page)
                bbox = normalizedBBox(from: rect, pageBounds: pageBounds, fallback: bbox)
            }
            lines.append(TextLine(text: text, pageIndex: pageIndex, bbox: bbox, confidence: nil))
        }

        return PageExtraction(pageIndex: pageIndex, lines: lines, isScanned: lines.isEmpty)
    }

    static func fallbackBBox(lineIndex: Int, lineCount: Int) -> CGRect {
        let safeCount = max(lineCount, 1)
        let height = min(0.03, 0.8 / CGFloat(safeCount))
        let available = max(0, 1 - height)
        let y: CGFloat
        if safeCount == 1 {
            y = 0.5
        } else {
            y = available * (1 - CGFloat(lineIndex) / CGFloat(safeCount - 1))
        }
        return CGRect(x: 0.1, y: clamp(y, min: 0, max: 1 - height), width: 0.8, height: height)
    }

    private static func selection(for text: String, on page: PDFPage, in doc: PDFDocument, occurrence: Int) -> PDFSelection? {
        doc.findString(text, withOptions: .literal)
            .filter { $0.pages.first == page }
            .dropFirst(occurrence)
            .first
    }

    private static func normalizedBBox(from rect: CGRect, pageBounds: CGRect, fallback: CGRect) -> CGRect {
        guard pageBounds.width > 0, pageBounds.height > 0 else {
            return fallback
        }
        let minX = clamp(rect.minX / pageBounds.width, min: 0, max: 1)
        let minY = clamp(rect.minY / pageBounds.height, min: 0, max: 1)
        let maxX = clamp(rect.maxX / pageBounds.width, min: minX, max: 1)
        let maxY = clamp(rect.maxY / pageBounds.height, min: minY, max: 1)
        return CGRect(x: minX, y: minY, width: maxX - minX, height: maxY - minY)
    }

    private static func clamp<T: Comparable>(_ value: T, min minValue: T, max maxValue: T) -> T {
        min(max(value, minValue), maxValue)
    }
}
