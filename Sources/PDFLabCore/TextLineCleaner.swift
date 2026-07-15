import Foundation

public struct TextCleanupSummary: Equatable, Sendable {
    public var repeatedEdgeLines: Int
    public var pageNumbers: Int
    public var ocrJunkLines: Int

    public init(repeatedEdgeLines: Int = 0, pageNumbers: Int = 0, ocrJunkLines: Int = 0) {
        self.repeatedEdgeLines = repeatedEdgeLines
        self.pageNumbers = pageNumbers
        self.ocrJunkLines = ocrJunkLines
    }

    public var hasFilteredLines: Bool {
        repeatedEdgeLines + pageNumbers + ocrJunkLines > 0
    }
}

public struct CleanedTextLines: Equatable, Sendable {
    public var lines: [TextLine]
    public var summary: TextCleanupSummary

    public init(lines: [TextLine], summary: TextCleanupSummary) {
        self.lines = lines
        self.summary = summary
    }
}

/// 聚段前的保守清洗。只移除能从位置与文本/置信度同时确认的非正文行。
public enum TextLineCleaner {
    public static func clean(_ lines: [TextLine]) -> CleanedTextLines {
        let pages = Dictionary(grouping: lines, by: \.pageIndex)
        let ordered = pages.keys.sorted().flatMap { OCRService.normalizeReadingOrder(pages[$0] ?? []) }
        let pageNumberIndexes = Set(ordered.indices.filter { isPageNumber(ordered[$0]) })
        let repeatedEdgeIndexes = repeatedEdgeLineIndexes(in: ordered, excluding: pageNumberIndexes)

        var summary = TextCleanupSummary()
        var retained: [TextLine] = []
        for index in ordered.indices {
            let line = ordered[index]
            if pageNumberIndexes.contains(index) {
                summary.pageNumbers += 1
            } else if repeatedEdgeIndexes.contains(index) {
                summary.repeatedEdgeLines += 1
            } else if isOCRJunk(line) {
                summary.ocrJunkLines += 1
            } else {
                retained.append(line)
            }
        }
        return CleanedTextLines(lines: retained, summary: summary)
    }

    private static func repeatedEdgeLineIndexes(in lines: [TextLine], excluding excluded: Set<Int>) -> Set<Int> {
        let candidates = lines.indices.filter { !excluded.contains($0) && edgeBucket(for: lines[$0]) != nil }
        return Set(candidates.filter { index in
            guard let edge = edgeBucket(for: lines[index]), let text = repeatedTextKey(lines[index].text) else { return false }
            let pages = candidates.compactMap { other -> Int? in
                guard edgeBucket(for: lines[other]) == edge,
                      let otherText = repeatedTextKey(lines[other].text),
                      repeatedTextIsSimilar(text, otherText) else { return nil }
                return lines[other].pageIndex
            }
            return Set(pages).count >= 3
        })
    }

    private static func edgeBucket(for line: TextLine) -> String? {
        if line.bbox.maxY >= 0.85 { return "top-\(Int((line.bbox.midY * 10).rounded()))" }
        if line.bbox.minY <= 0.15 { return "bottom-\(Int((line.bbox.midY * 10).rounded()))" }
        return nil
    }

    private static func repeatedTextKey(_ text: String) -> String? {
        let key = text.lowercased().filter { $0.isLetter || $0.isNumber }.filter { !$0.isNumber }
        return key.isEmpty ? nil : key
    }

    private static func repeatedTextIsSimilar(_ lhs: String, _ rhs: String) -> Bool {
        guard lhs.count == rhs.count else { return lhs == rhs }
        return zip(lhs, rhs).filter { $0 != $1 }.count <= 1
    }

    private static func isPageNumber(_ line: TextLine) -> Bool {
        guard edgeBucket(for: line) != nil else { return false }
        let text = line.text.trimmingCharacters(in: .whitespacesAndNewlines)
        if !text.isEmpty && text.allSatisfy(\.isNumber) { return true }
        let lower = text.lowercased()
        if lower.hasPrefix("page "), lower.dropFirst(5).trimmingCharacters(in: .whitespaces).allSatisfy(\.isNumber) { return true }
        if text.hasPrefix("第"), text.hasSuffix("页"), text.dropFirst().dropLast().trimmingCharacters(in: .whitespaces).allSatisfy(\.isNumber) { return true }
        if text.hasPrefix("-"), text.hasSuffix("-"), text.trimmingCharacters(in: CharacterSet(charactersIn: "- ")).allSatisfy(\.isNumber) { return true }
        return isValidRomanNumeral(text)
    }

    private static func isValidRomanNumeral(_ text: String) -> Bool {
        let numeral = text.uppercased()
        let values: [Character: Int] = ["I": 1, "V": 5, "X": 10, "L": 50, "C": 100, "D": 500, "M": 1_000]
        let digits = numeral.compactMap { values[$0] }
        guard !digits.isEmpty, digits.count == numeral.count else { return false }

        let value = digits.enumerated().reduce(0) { total, entry in
            let (index, digit) = entry
            return total + (index + 1 < digits.count && digit < digits[index + 1] ? -digit : digit)
        }
        return canonicalRomanNumeral(value) == numeral
    }

    private static func canonicalRomanNumeral(_ value: Int) -> String {
        var remaining = value
        let symbols: [(Int, String)] = [
            (1_000, "M"), (900, "CM"), (500, "D"), (400, "CD"),
            (100, "C"), (90, "XC"), (50, "L"), (40, "XL"),
            (10, "X"), (9, "IX"), (5, "V"), (4, "IV"), (1, "I")
        ]
        var result = ""
        for (amount, symbol) in symbols {
            while remaining >= amount {
                result += symbol
                remaining -= amount
            }
        }
        return result
    }

    private static func isOCRJunk(_ line: TextLine) -> Bool {
        guard let confidence = line.confidence, confidence < TranslationPipeline.lowConfidenceThreshold else { return false }
        let characters = line.text.filter { !$0.isWhitespace }
        guard !characters.isEmpty, characters.count <= 8 else { return false }
        let symbolCount = characters.count - characters.filter { $0.isLetter || $0.isNumber }.count
        return Double(symbolCount) / Double(characters.count) >= 0.5
    }
}
