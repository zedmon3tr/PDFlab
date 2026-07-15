import Testing
import CoreGraphics
@testable import PDFLabCore

private func line(_ t: String, page: Int = 0, y: CGFloat, conf: Double? = nil) -> TextLine {
    TextLine(text: t, pageIndex: page, bbox: CGRect(x: 0.1, y: y, width: 0.8, height: 0.03), confidence: conf)
}

@Test func groupsAdjacentLinesIntoParagraph() {
    let ps = ParagraphBuilder.buildParagraphs(from: [
        line("The quick brown", y: 0.90), line("fox jumps.", y: 0.865),
        line("New paragraph here.", y: 0.70),   // 间距远大于 1.6 倍行高 → 分段
    ])
    #expect(ps.map(\.text) == ["The quick brown fox jumps.", "New paragraph here."])
}
@Test func joinsChineseWithoutSpaceAndStripsHyphen() {
    let zh = ParagraphBuilder.buildParagraphs(from: [line("这是第一", y: 0.9), line("行文字。", y: 0.865)])
    #expect(zh.first?.text == "这是第一行文字。")
    let hy = ParagraphBuilder.buildParagraphs(from: [line("hyphen-", y: 0.9), line("ated word", y: 0.865)])
    #expect(hy.first?.text == "hyphenated word")
}
@Test func mergesCrossPageAndKeepsStartPage() {
    let merged = ParagraphBuilder.mergeAcrossPages([
        SourceParagraph(text: "This sentence continues", pageIndex: 0),
        SourceParagraph(text: "on the next page.", pageIndex: 1),
        SourceParagraph(text: "完整的一段。", pageIndex: 1),
    ])
    #expect(merged.count == 2)
    #expect(merged[0].text == "This sentence continues on the next page.")
    #expect(merged[0].pageIndex == 0)
}
@Test func doesNotMergeSideBySideColumns() {
    let ps = ParagraphBuilder.buildParagraphs(from: [
        TextLine(text: "Left column line", pageIndex: 0, bbox: CGRect(x: 0.05, y: 0.90, width: 0.40, height: 0.03)),
        TextLine(text: "Right column line", pageIndex: 0, bbox: CGRect(x: 0.55, y: 0.875, width: 0.40, height: 0.03)),
    ])
    #expect(ps.count == 2)
}
@Test func listMarkersAttachToFollowingTextWithoutBecomingTranslatableText() {
    let ps = ParagraphBuilder.buildParagraphs(from: [
        TextLine(text: "1.", pageIndex: 0, bbox: CGRect(x: 0.08, y: 0.90, width: 0.03, height: 0.03)),
        TextLine(text: "Preparation", pageIndex: 0, bbox: CGRect(x: 0.14, y: 0.90, width: 0.20, height: 0.03)),
        TextLine(text: "•", pageIndex: 0, bbox: CGRect(x: 0.18, y: 0.82, width: 0.02, height: 0.03)),
        TextLine(text: "Complete Mental Model development", pageIndex: 0, bbox: CGRect(x: 0.24, y: 0.82, width: 0.50, height: 0.03)),
    ])

    #expect(ps.map(\.text) == ["Preparation", "Complete Mental Model development"])
    #expect(ps.map(\.listMarker) == ["1.", "•"])
    #expect(ps.map(\.displayText) == ["1. Preparation", "• Complete Mental Model development"])
}
@Test func joinsAcrossFullwidthPunctuationBoundary() {
    // 全角标点(如全角逗号 U+FF0C)属规范 isCJK 判定收录范围,聚段拼接与选区文本清洗(App 层
    // CJK 相邻应直接拼接,不插空格。
    #expect(ParagraphBuilder.isCJK("，"))
    let ps = ParagraphBuilder.buildParagraphs(from: [
        line("这是第一行，", y: 0.9), line("紧接着续写完。", y: 0.865),
    ])
    #expect(ps.first?.text == "这是第一行，紧接着续写完。")
}
@Test func doesNotMergeWhenSentenceEnded() {
    let merged = ParagraphBuilder.mergeAcrossPages([
        SourceParagraph(text: "Sentence done.", pageIndex: 0),
        SourceParagraph(text: "Next page para.", pageIndex: 1),
    ])
    #expect(merged.count == 2)
}

@Test func adaptiveGapThresholdSeparatesTwoStableSpacingClusters() {
    #expect(abs((ParagraphBuilder.adaptiveGapThreshold(for: [0.01, 0.011, 0.012, 0.04, 0.041, 0.042]) ?? 0) - 0.026) < 0.000_001)
    #expect(ParagraphBuilder.adaptiveGapThreshold(for: [0.01, 0.011, 0.012, 0.013, 0.014]) == nil)
    #expect(ParagraphBuilder.adaptiveGapThreshold(for: [0.010, 0.011, 0.012, 0.013, 0.014, 0.015]) == nil)
}

@Test func documentSemanticBaselineClassifiesHeadingFootnoteAndListConservatively() {
    let body = (0..<8).map { index in
        TextLine(text: "Body \(index)", pageIndex: 0, bbox: CGRect(x: 0.1, y: 0.75 - CGFloat(index) * 0.04, width: 0.8, height: 0.03))
    }
    let layout = PageLayout(pageIndex: 0, regions: [
        LayoutRegion(id: "title", kind: .body, source: .heuristic, blocks: [
            LayoutBlock(id: .init("title-b"), kind: .text, lines: [
                TextLine(text: "A Short Title", pageIndex: 0, bbox: CGRect(x: 0.3, y: 0.88, width: 0.4, height: 0.045))
            ])
        ]),
        LayoutRegion(id: "body", kind: .body, source: .heuristic, blocks: [
            LayoutBlock(id: .init("body-b"), kind: .text, lines: body)
        ]),
        LayoutRegion(id: "footnote", kind: .body, source: .heuristic, blocks: [
            LayoutBlock(id: .init("footnote-b"), kind: .text, lines: [
                TextLine(text: "1 Footnote", pageIndex: 0, bbox: CGRect(x: 0.1, y: 0.03, width: 0.5, height: 0.024))
            ])
        ])
    ])

    let paragraphs = ParagraphBuilder.buildParagraphs(from: [layout])
    #expect(paragraphs.first?.kind == .heading(level: 1))
    #expect(paragraphs.last?.kind == .footnote)

    let list = ParagraphBuilder.buildParagraphs(from: [
        TextLine(text: "1. Item", pageIndex: 0, bbox: CGRect(x: 0.1, y: 0.9, width: 0.5, height: 0.03))
    ])
    #expect(list.first?.kind == .listItem(marker: "1."))
    #expect(list.first?.listMarker == "1.")
}

@Test func systemTitleAndListKindsTakePriorityOverGeometry() {
    let layout = OCRService.systemPageLayout(pageIndex: 0, blocks: [
        LayoutBlock(id: .init("title"), kind: .title, lines: [
            TextLine(text: "System title", pageIndex: 0, bbox: CGRect(x: 0.1, y: 0.9, width: 0.8, height: 0.02))
        ]),
        LayoutBlock(id: .init("list"), kind: .listItem, lines: [
            TextLine(text: "System item", pageIndex: 0, bbox: CGRect(x: 0.1, y: 0.8, width: 0.8, height: 0.06))
        ])
    ])
    let paragraphs = ParagraphBuilder.buildParagraphs(from: [layout])
    #expect(paragraphs.map(\.kind) == [.heading(level: 1), .listItem(marker: "")])
}

@Test func indentationAndShortRightEdgeForceParagraphBreaksWithinTheirRegion() {
    let lines = [
        TextLine(text: "上一段完整末行", pageIndex: 0, bbox: CGRect(x: 0.10, y: 0.90, width: 0.45, height: 0.03)),
        TextLine(text: "这是缩进新段", pageIndex: 0, bbox: CGRect(x: 0.14, y: 0.86, width: 0.76, height: 0.03)),
        TextLine(text: "缩进段续行", pageIndex: 0, bbox: CGRect(x: 0.10, y: 0.82, width: 0.80, height: 0.03)),
    ]
    let layout = PageLayout(pageIndex: 0, regions: [
        LayoutRegion(id: "column", kind: .body, source: .heuristic, blocks: [LayoutBlock(id: .init("b"), kind: .text, lines: lines)])
    ])
    let paragraphs = ParagraphBuilder.buildParagraphs(from: [layout])
    #expect(paragraphs.map(\.text) == ["上一段完整末行", "这是缩进新段缩进段续行"])
    #expect(paragraphs.first?.lastLineIsShort == true)
    #expect(paragraphs.first?.regionBodyRightEdge == 0.9)
}

@Test func adaptiveSpacingIsComputedPerColumnRegion() {
    func column(_ id: String, x: CGFloat, gaps: [CGFloat]) -> LayoutRegion {
        var y: CGFloat = 0.92
        var lines: [TextLine] = []
        for (index, gap) in gaps.enumerated() {
            lines.append(TextLine(text: "\(id)-\(index)", pageIndex: 0, bbox: CGRect(x: x, y: y, width: 0.35, height: 0.03)))
            y -= 0.03 + gap
        }
        lines.append(TextLine(text: "\(id)-last", pageIndex: 0, bbox: CGRect(x: x, y: y, width: 0.35, height: 0.03)))
        return LayoutRegion(id: id, kind: .body, source: .heuristic, blocks: [LayoutBlock(id: .init(id), kind: .text, lines: lines)])
    }
    let tightThenBreak = column("left", x: 0.05, gaps: [0.01, 0.011, 0.012, 0.04, 0.041, 0.042])
    let singlePeak = column("right", x: 0.55, gaps: [0.02, 0.021, 0.022, 0.023, 0.024, 0.025])
    let paragraphs = ParagraphBuilder.buildParagraphs(from: [PageLayout(pageIndex: 0, regions: [tightThenBreak, singlePeak])])
    #expect(paragraphs.filter { $0.sourceBlockIDs.contains(.init("left")) }.count == 4)
    #expect(paragraphs.filter { $0.sourceBlockIDs.contains(.init("right")) }.count == 7)
}

@Test func crossPageMergeRejectsSemanticKindsAndShortPreviousLine() {
    let body = SourceParagraph(
        text: "continues", pageIndex: 0, kind: .body,
        lastLineBBox: CGRect(x: 0.1, y: 0.02, width: 0.4, height: 0.03),
        regionBodyRightEdge: 0.9, lastLineIsShort: true
    )
    let next = SourceParagraph(text: "on next page", pageIndex: 1)
    #expect(ParagraphBuilder.mergeAcrossPages([body, next]).count == 2)
    #expect(ParagraphBuilder.mergeAcrossPages([
        SourceParagraph(text: "Heading", pageIndex: 0, kind: .heading(level: 1)), next
    ]).count == 2)
}

@Test func footnoteAtPreviousPageEndDoesNotBlockBodyCrossPageMerge() {
    let merged = ParagraphBuilder.mergeAcrossPages([
        SourceParagraph(text: "This continues", pageIndex: 0),
        SourceParagraph(text: "1 Note", pageIndex: 0, kind: .footnote),
        SourceParagraph(text: "on the next page.", pageIndex: 1),
    ])
    #expect(merged.map(\.text) == ["This continues on the next page.", "1 Note"])
    #expect(merged.map(\.kind) == [.body, .footnote])
}
