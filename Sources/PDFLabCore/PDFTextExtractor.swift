import PDFKit

public struct PageExtraction: Sendable {
    public var pageIndex: Int
    public var layout: PageLayout
    public var lines: [TextLine] { layout.flattenedLines }
    public var isScanned: Bool

    public init(pageIndex: Int, lines: [TextLine], isScanned: Bool) {
        self.pageIndex = pageIndex
        self.layout = PageReadingOrder.layout(lines, pageIndex: pageIndex, orderedLines: lines)
        self.isScanned = isScanned
    }

    public init(layout: PageLayout, isScanned: Bool) {
        self.pageIndex = layout.pageIndex
        self.layout = layout
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
        if let visualLines = visualTextLines(on: page, content: content, pageBounds: pageBounds, pageIndex: pageIndex) {
            let orderedLines = PageReadingOrder.order(visualLines)
            return PageExtraction(
                pageIndex: pageIndex,
                lines: orderedLines,
                isScanned: visualLines.isEmpty
            )
        }

        // Some malformed PDFs expose text without usable character geometry. Keep
        // the old selection-based path as an all-or-nothing fallback so text is not
        // silently dropped when visual reconstruction cannot prove full coverage.
        return legacyExtraction(page, in: doc, content: content, pageBounds: pageBounds, pageIndex: pageIndex)
    }

    private static func visualTextLines(
        on page: PDFPage,
        content: String,
        pageBounds: CGRect,
        pageIndex: Int
    ) -> [TextLine]? {
        guard pageBounds.width > 0, pageBounds.height > 0, page.numberOfCharacters > 0,
              let wholePage = page.selection(for: NSRange(location: 0, length: page.numberOfCharacters)) else { return nil }
        let lines = wholePage.selectionsByLine().flatMap { selection in
            splitVisualLine(selection, on: page, pageBounds: pageBounds, pageIndex: pageIndex)
        }
        guard sameNonWhitespaceCharacters(content, lines.map(\.text).joined()) else { return nil }
        return normalizeCoincidentMultilineGeometry(lines)
    }

    private struct VisualCharacter {
        var localRange: NSRange
        var bounds: CGRect
    }

    static func splitVisualLine(
        _ selection: PDFSelection,
        on page: PDFPage,
        pageBounds: CGRect,
        pageIndex: Int
    ) -> [TextLine] {
        guard let rawText = selection.string,
              !rawText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return [] }
        let wholeBounds = selection.bounds(for: page)
        guard usable(wholeBounds) else { return [] }
        let fallback = TextLine(
            text: rawText.trimmingCharacters(in: .whitespacesAndNewlines),
            pageIndex: pageIndex,
            bbox: normalizedBBox(from: wholeBounds, pageBounds: pageBounds, fallback: .zero),
            confidence: nil
        )
        let rangeCount = selection.numberOfTextRanges(on: page)
        guard rangeCount > 0 else { return [fallback] }
        var fragments: [TextLine] = []
        for index in 0..<rangeCount {
            let pageRange = selection.range(at: index, on: page)
            guard pageRange.location != NSNotFound,
                  pageRange.length > 0,
                  let rangeSelection = page.selection(for: pageRange),
                  let rangeText = rangeSelection.string,
                  let rangeFragments = visualFragments(
                    text: rangeText,
                    pageRange: pageRange,
                    on: page,
                    pageBounds: pageBounds,
                    pageIndex: pageIndex
                  ) else { return [fallback] }
            fragments.append(contentsOf: rangeFragments)
        }
        return fragments.isEmpty ? [fallback] : fragments
    }

    private static func visualFragments(
        text rawText: String,
        pageRange: NSRange,
        on page: PDFPage,
        pageBounds: CGRect,
        pageIndex: Int
    ) -> [TextLine]? {
        let text = rawText as NSString
        var characters: [VisualCharacter] = []
        var location = 0
        while location < text.length {
            let localRange = text.rangeOfComposedCharacterSequence(at: location)
            location = NSMaxRange(localRange)
            let character = text.substring(with: localRange)
            guard !character.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { continue }
            let globalRange = NSRange(location: pageRange.location + localRange.location, length: localRange.length)
            guard NSMaxRange(globalRange) <= NSMaxRange(pageRange),
                  let characterSelection = page.selection(for: globalRange) else { return nil }
            let bounds = characterSelection.bounds(for: page)
            guard usable(bounds) else { return nil }
            characters.append(VisualCharacter(localRange: localRange, bounds: bounds))
        }
        guard !characters.isEmpty else { return [] }

        let medianCharacterWidth = median(characters.map { max($0.bounds.width, 1) })
        let medianCharacterHeight = median(characters.map { max($0.bounds.height, 1) })
        let splitGap = max(pageBounds.width * 0.012, medianCharacterHeight * 1.25, medianCharacterWidth * 2)
        var groups: [[VisualCharacter]] = []
        for character in characters {
            if let previous = groups.last?.last,
               character.bounds.minX - previous.bounds.maxX > splitGap {
                groups.append([character])
            } else if groups.isEmpty {
                groups.append([character])
            } else {
                groups[groups.count - 1].append(character)
            }
        }

        return groups.compactMap { group in
            guard let first = group.first, let last = group.last else { return nil }
            let fragmentRange = NSRange(
                location: first.localRange.location,
                length: NSMaxRange(last.localRange) - first.localRange.location
            )
            let fragmentText = text.substring(with: fragmentRange)
                .trimmingCharacters(in: .whitespacesAndNewlines)
            guard !fragmentText.isEmpty else { return nil }
            let bounds = group.reduce(CGRect.null) { $0.union($1.bounds) }
            return TextLine(
                text: fragmentText,
                pageIndex: pageIndex,
                bbox: normalizedBBox(from: bounds, pageBounds: pageBounds, fallback: .zero),
                confidence: nil
            )
        }
    }

    private static func usable(_ rect: CGRect) -> Bool {
        !rect.isNull && !rect.isEmpty && rect.minX.isFinite && rect.minY.isFinite &&
            rect.maxX.isFinite && rect.maxY.isFinite && rect.width > 0 && rect.height > 0
    }

    /// PDFKit occasionally returns the same union rect for two adjacent text
    /// ranges on separate visual rows. Recover the rows only when the shared
    /// rect is a clear multiple of the page's ordinary line height.
    static func normalizeCoincidentMultilineGeometry(_ lines: [TextLine]) -> [TextLine] {
        guard lines.count >= 3 else { return lines }
        let heights = lines.map { max($0.bbox.height, 0.001) }
        let middle = median(heights)
        let baseline = median(heights.filter { $0 <= middle })
        let tolerance = baseline * 0.1
        var normalized = lines
        var consumed: Set<Int> = []
        for index in lines.indices where !consumed.contains(index) {
            let box = lines[index].bbox
            let matches = lines.indices.filter { candidate in
                guard !consumed.contains(candidate) else { return false }
                let other = lines[candidate].bbox
                let horizontalOverlap = min(box.maxX, other.maxX) - max(box.minX, other.minX)
                return abs(box.minY - other.minY) <= tolerance &&
                    abs(box.maxY - other.maxY) <= tolerance &&
                    horizontalOverlap >= min(box.width, other.width) * 0.8
            }
            guard matches.count >= 2, box.height >= baseline * CGFloat(matches.count) * 0.8 else { continue }
            let rowHeight = box.height / CGFloat(matches.count)
            for (position, match) in matches.enumerated() {
                normalized[match].bbox.origin.y = box.minY + CGFloat(matches.count - position - 1) * rowHeight
                normalized[match].bbox.size.height = rowHeight
                consumed.insert(match)
            }
        }
        return normalized
    }

    private static func sameNonWhitespaceCharacters(_ source: String, _ rebuilt: String) -> Bool {
        source.filter { !$0.isWhitespace }.sorted() == rebuilt.filter { !$0.isWhitespace }.sorted()
    }

    private static func median(_ values: [CGFloat]) -> CGFloat {
        let sorted = values.sorted()
        guard !sorted.isEmpty else { return 0 }
        let middle = sorted.count / 2
        if sorted.count.isMultiple(of: 2) {
            return (sorted[middle - 1] + sorted[middle]) / 2
        }
        return sorted[middle]
    }

    private static func legacyExtraction(
        _ page: PDFPage,
        in doc: PDFDocument,
        content: String,
        pageBounds: CGRect,
        pageIndex: Int
    ) -> PageExtraction {
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

        let normalized = normalizeCoincidentMultilineGeometry(lines)
        return PageExtraction(pageIndex: pageIndex, lines: normalized, isScanned: normalized.isEmpty)
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

    static func normalizedBBox(from rect: CGRect, pageBounds: CGRect, fallback: CGRect) -> CGRect {
        guard pageBounds.width > 0, pageBounds.height > 0 else {
            return fallback
        }
        let minX = clamp((rect.minX - pageBounds.minX) / pageBounds.width, min: 0, max: 1)
        let minY = clamp((rect.minY - pageBounds.minY) / pageBounds.height, min: 0, max: 1)
        let maxX = clamp((rect.maxX - pageBounds.minX) / pageBounds.width, min: minX, max: 1)
        let maxY = clamp((rect.maxY - pageBounds.minY) / pageBounds.height, min: minY, max: 1)
        return CGRect(x: minX, y: minY, width: maxX - minX, height: maxY - minY)
    }

    private static func clamp<T: Comparable>(_ value: T, min minValue: T, max maxValue: T) -> T {
        min(max(value, minValue), maxValue)
    }
}
