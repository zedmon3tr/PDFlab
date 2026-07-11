import Foundation

enum ParagraphListMarkerParser {
    private static let bulletMarkers: Set<String> = ["•", "●", "○", "◦", "▪", "▫", "-", "–", "—", "*"]

    static func standaloneMarker(in text: String) -> String? {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        if bulletMarkers.contains(trimmed) { return trimmed }
        return isOrderedMarker(trimmed) ? trimmed : nil
    }

    static func splitLeadingMarker(in text: String) -> (marker: String, body: String)? {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let spaceIndex = trimmed.firstIndex(where: { $0.isWhitespace }) else { return nil }
        let marker = String(trimmed[..<spaceIndex])
        let body = String(trimmed[spaceIndex...]).trimmingCharacters(in: .whitespacesAndNewlines)
        guard !body.isEmpty else { return nil }
        if bulletMarkers.contains(marker) || isOrderedMarker(marker) {
            return (marker, body)
        }
        return nil
    }

    private static func isOrderedMarker(_ text: String) -> Bool {
        guard text.count >= 2, let last = text.last, last == "." || last == ")" else { return false }
        let prefix = text.dropLast()
        guard !prefix.isEmpty else { return false }
        return prefix.allSatisfy(\.isNumber) || (prefix.count == 1 && prefix.allSatisfy(\.isLetter))
    }
}
