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
        buildParagraphs(from: lines, sourceBlockID: nil)
    }

    public static func buildParagraphs(from blocks: [LayoutBlock]) -> [SourceParagraph] {
        blocks.flatMap { buildParagraphs(from: $0.lines, sourceBlockID: $0.id) }
    }

    public static func buildParagraphs(from layouts: [PageLayout]) -> [SourceParagraph] {
        buildParagraphs(from: layouts.flatMap(\.blocks))
    }

    private static func buildParagraphs(from lines: [TextLine], sourceBlockID: LayoutBlockID?) -> [SourceParagraph] {
        var result: [SourceParagraph] = []
        var current: (text: String, page: Int, confs: [Double], firstBox: CGRect, lastBox: CGRect, listMarker: String?)? = nil

        func flush() {
            if let c = current {
                let conf = c.confs.isEmpty ? nil : c.confs.reduce(0, +) / Double(c.confs.count)
                let sourceIDs = sourceBlockID.map { [$0] } ?? []
                let unitID = sourceBlockID.map { TranslationUnitID("paragraph:\($0.rawValue):\(result.count)") }
                result.append(SourceParagraph(
                    text: c.text,
                    pageIndex: c.page,
                    ocrConfidence: conf,
                    listMarker: c.listMarker,
                    translationUnitID: unitID,
                    sourceBlockIDs: sourceIDs,
                    firstLineBBox: c.firstBox,
                    lastLineBBox: c.lastBox
                ))
            }
            current = nil
        }
        var index = 0
        while index < lines.count {
            let l = lines[index]
            if let marker = ParagraphListMarkerParser.standaloneMarker(in: l.text) {
                if index + 1 < lines.count {
                    var next = lines[index + 1]
                    if next.pageIndex == l.pageIndex,
                       isSameVisualLineContinuation(previous: l.bbox, next: next.bbox) {
                        flush()
                        let split = ParagraphListMarkerParser.splitLeadingMarker(in: next.text)
                        next.text = split?.body ?? next.text
                        current = (next.text, next.pageIndex, next.confidence.map { [$0] } ?? [], next.bbox, next.bbox, split?.marker ?? marker)
                        index += 2
                        continue
                    }
                }
                flush()
                index += 1
                continue
            }
            if let split = ParagraphListMarkerParser.splitLeadingMarker(in: l.text) {
                flush()
                current = (split.body, l.pageIndex, l.confidence.map { [$0] } ?? [], l.bbox, l.bbox, split.marker)
                index += 1
                continue
            }

            guard var c = current, c.page == l.pageIndex else { flush(); current = (l.text, l.pageIndex, l.confidence.map { [$0] } ?? [], l.bbox, l.bbox, nil); index += 1; continue }
            let sameVisualLine = isSameVisualLineContinuation(previous: c.lastBox, next: l.bbox)
            let sameParagraph = sameVisualLine || isNextLineContinuation(previous: c.lastBox, next: l.bbox)
            if sameParagraph {
                c.text = join(c.text, l.text)
                if let cf = l.confidence { c.confs.append(cf) }
                c.lastBox = sameVisualLine ? c.lastBox.union(l.bbox) : l.bbox
                current = c
            } else { flush(); current = (l.text, l.pageIndex, l.confidence.map { [$0] } ?? [], l.bbox, l.bbox, nil) }
            index += 1
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
                prev.sourceBlockIDs.append(contentsOf: p.sourceBlockIDs.filter { !prev.sourceBlockIDs.contains($0) })
                prev.lastLineBBox = p.lastLineBBox
                out[out.count - 1] = prev
            } else { out.append(p) }
        }
        return out
    }

    private static func isContinuation(_ ch: Character) -> Bool {
        ch.isLowercase || ch.unicodeScalars.first.map { (0x4E00...0x9FFF).contains($0.value) } ?? false
    }
    /// 判断 next 是否为 previous 的下一自然行(段内换行)。
    /// 直接复用同一套聚段判定,避免两处独立维护阈值而逐渐分叉。
    static func isNextLineContinuation(previous: CGRect, next: CGRect) -> Bool {
        let gap = previous.minY - next.maxY          // 归一化坐标,原点左下,行自上而下
        let overlaps = max(previous.minX, next.minX) < min(previous.maxX, next.maxX)  // 水平重叠(多栏不并段)
        return gap <= next.height * 0.6 && overlaps  // 间距 ≤ 0.6 倍行高(即行距 ≤ 1.6 倍行高)且水平重叠
    }
    /// 判断 next 是否与 previous 同属一条视觉行(如行内被拆成多个文本片段)。
    static func isSameVisualLineContinuation(previous: CGRect, next: CGRect) -> Bool {
        let verticalOverlap = min(previous.maxY, next.maxY) - max(previous.minY, next.minY)
        let requiredOverlap = min(previous.height, next.height) * 0.5
        let horizontalGap = next.minX - previous.maxX
        return verticalOverlap >= requiredOverlap && horizontalGap >= 0 && horizontalGap <= next.height * 2
    }
    /// 拼接两行文本:行尾连字符去掉并无缝连接;CJK 相邻直接连接,否则以单空格连接。
    /// 同模块直接调用,保证聚段文本口径一致。
    static func join(_ a: String, _ b: String) -> String {
        if a.hasSuffix("-") { return String(a.dropLast()) + b }
        let aCJK = a.last.map(isCJK) ?? false
        let bCJK = b.first.map(isCJK) ?? false
        return (aCJK && bCJK) ? a + b : a + " " + b
    }
    /// CJK 字符判定(统一表意文字/部首区 + 全角标点区)。`public`:供 App target 的
    public static func isCJK(_ character: Character) -> Bool {
        guard let scalar = character.unicodeScalars.first else { return false }
        return (0x2E80...0x9FFF).contains(scalar.value) || (0xFF00...0xFFEF).contains(scalar.value)
    }
}
