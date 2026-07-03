import CoreGraphics
import Foundation

/// 一行文本及几何信息(OCR 或文本层均产出此结构;bbox 为页内归一化坐标,原点左下)。
public struct TextLine: Equatable, Sendable {
    public var text: String
    public var pageIndex: Int
    public var bbox: CGRect
    public var confidence: Double?
    public init(text: String, pageIndex: Int, bbox: CGRect, confidence: Double? = nil) {
        self.text = text
        self.pageIndex = pageIndex
        self.bbox = bbox
        self.confidence = confidence
    }
}

public enum ParagraphBuilder {
    private static let sentenceEnders: Set<Character> = ["。", ".", "!", "?", "!", "?", ";", ";", ":", ":", "」", "”", "\"", "』"]

    public static func buildParagraphs(from lines: [TextLine]) -> [SourceParagraph] {
        var result: [SourceParagraph] = []
        var current: (text: String, page: Int, confs: [Double], lastBox: CGRect)? = nil

        func flush() {
            if let c = current {
                let conf = c.confs.isEmpty ? nil : c.confs.reduce(0, +) / Double(c.confs.count)
                result.append(SourceParagraph(text: c.text, pageIndex: c.page, ocrConfidence: conf))
            }
            current = nil
        }
        for l in lines {
            guard var c = current, c.page == l.pageIndex else { flush(); current = (l.text, l.pageIndex, l.confidence.map { [$0] } ?? [], l.bbox); continue }
            let gap = c.lastBox.minY - l.bbox.maxY          // 归一化坐标,原点左下,行自上而下
            let overlaps = max(c.lastBox.minX, l.bbox.minX) < min(c.lastBox.maxX, l.bbox.maxX)  // 水平重叠(多栏不并段)
            let sameParagraph = gap <= l.bbox.height * 0.6 && overlaps  // 间距 ≤ 0.6 倍行高(即行距 ≤ 1.6 倍行高)且水平重叠
            if sameParagraph {
                c.text = join(c.text, l.text)
                if let cf = l.confidence { c.confs.append(cf) }
                c.lastBox = l.bbox
                current = c
            } else { flush(); current = (l.text, l.pageIndex, l.confidence.map { [$0] } ?? [], l.bbox) }
        }
        flush()
        return result
    }

    public static func mergeAcrossPages(_ paragraphs: [SourceParagraph]) -> [SourceParagraph] {
        var out: [SourceParagraph] = []
        for p in paragraphs {
            if var prev = out.last, prev.pageIndex < p.pageIndex,
               let lastChar = prev.text.last, !sentenceEnders.contains(lastChar),
               let firstChar = p.text.first, isContinuation(firstChar) {
                prev.text = join(prev.text, p.text)
                out[out.count - 1] = prev
            } else { out.append(p) }
        }
        return out
    }

    private static func isContinuation(_ ch: Character) -> Bool {
        ch.isLowercase || ch.unicodeScalars.first.map { (0x4E00...0x9FFF).contains($0.value) } ?? false
    }
    private static func join(_ a: String, _ b: String) -> String {
        if a.hasSuffix("-") { return String(a.dropLast()) + b }
        let aCJK = a.last.map { $0.unicodeScalars.first.map { (0x2E80...0x9FFF).contains($0.value) } ?? false } ?? false
        let bCJK = b.first.map { $0.unicodeScalars.first.map { (0x2E80...0x9FFF).contains($0.value) } ?? false } ?? false
        return (aCJK && bCJK) ? a + b : a + " " + b
    }
}
