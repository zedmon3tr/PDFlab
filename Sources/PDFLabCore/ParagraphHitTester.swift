import CoreGraphics

/// 页内段落(带聚合 bbox,归一化坐标,原点左下)。
public struct PageParagraph: Equatable, Sendable {
    public var text: String
    public var bbox: CGRect
    public var ocrConfidence: Double?

    public init(text: String, bbox: CGRect, ocrConfidence: Double? = nil) {
        self.text = text
        self.bbox = bbox
        self.ocrConfidence = ocrConfidence
    }
}

public enum ParagraphHitTester {
    private static let tolerance: CGFloat = 0.005

    /// 由 TextLine 列表聚段并生成段落级 union bbox。
    public static func paragraphs(from lines: [TextLine]) -> [PageParagraph] {
        var result: [PageParagraph] = []
        var current: (text: String, page: Int, confs: [Double], lastBox: CGRect, unionBox: CGRect)?

        func flush() {
            guard let c = current else { return }
            let conf = c.confs.isEmpty ? nil : c.confs.reduce(0, +) / Double(c.confs.count)
            result.append(PageParagraph(text: c.text, bbox: c.unionBox, ocrConfidence: conf))
            current = nil
        }

        for line in lines {
            guard var c = current, c.page == line.pageIndex else {
                flush()
                current = (
                    text: line.text,
                    page: line.pageIndex,
                    confs: line.confidence.map { [$0] } ?? [],
                    lastBox: line.bbox,
                    unionBox: line.bbox
                )
                continue
            }

            let gap = c.lastBox.minY - line.bbox.maxY
            let overlaps = max(c.lastBox.minX, line.bbox.minX) < min(c.lastBox.maxX, line.bbox.maxX)
            let sameParagraph = gap <= line.bbox.height * 0.6 && overlaps
            if sameParagraph {
                c.text = join(c.text, line.text)
                if let confidence = line.confidence {
                    c.confs.append(confidence)
                }
                c.lastBox = line.bbox
                c.unionBox = c.unionBox.union(line.bbox)
                current = c
            } else {
                flush()
                current = (
                    text: line.text,
                    page: line.pageIndex,
                    confs: line.confidence.map { [$0] } ?? [],
                    lastBox: line.bbox,
                    unionBox: line.bbox
                )
            }
        }
        flush()
        return result
    }

    /// 命中:点击点(归一化,原点左下)落入某段 bbox 则命中;多段重叠取 bbox 面积最小者。
    public static func hitTest(point: CGPoint, in paragraphs: [PageParagraph]) -> Int? {
        paragraphs.enumerated()
            .filter { _, paragraph in paragraph.bbox.insetBy(dx: -tolerance, dy: -tolerance).contains(point) }
            .min { lhs, rhs in area(lhs.element.bbox) < area(rhs.element.bbox) }?
            .offset
    }

    private static func area(_ rect: CGRect) -> CGFloat {
        max(0, rect.width) * max(0, rect.height)
    }

    private static func join(_ a: String, _ b: String) -> String {
        if a.hasSuffix("-") { return String(a.dropLast()) + b }
        let aCJK = a.last.map { isCJK($0) } ?? false
        let bCJK = b.first.map { isCJK($0) } ?? false
        return (aCJK && bCJK) ? a + b : a + " " + b
    }

    private static func isCJK(_ character: Character) -> Bool {
        character.unicodeScalars.first.map { (0x2E80...0x9FFF).contains($0.value) } ?? false
    }
}
