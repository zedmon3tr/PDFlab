import Testing
@testable import PDFLabCore

private func makeThreeParagraphDoc() -> ParsedDocument {
    ParsedDocument(
        paragraphs: [
            SourceParagraph(text: "p0-0", pageIndex: 0),
            SourceParagraph(text: "p0-1", pageIndex: 0),
            SourceParagraph(text: "p1-0", pageIndex: 1)
        ],
        pageCount: 2
    )
}

private func source(_ text: String, _ id: String, kind: ComposedTextKind = .body) -> ComposedBlock {
    .sourceText(.init(text: text, groupID: .init(id), kind: kind))
}

private func translation(_ text: String, _ id: String, kind: ComposedTextKind = .body) -> ComposedBlock {
    .translatedText(.init(text: text, groupID: .init(id), kind: kind))
}

@Test func bilingualPageAlignedInsertsPageBreaksOnAttributionChange() {
    let doc = makeThreeParagraphDoc()
    let translations = ["t0", "t1", "t2"]
    let options = ExportOptions(content: .bilingual, format: .pdf, pageMode: .pageAligned)

    let result = DocumentComposer.compose(doc: doc, translations: translations, options: options, direction: .enToZh)

    #expect(result.blocks == [
        .pageBreak(pageIndex: 0),
        source("p0-0", "compat-paragraph:0"),
        translation("t0", "compat-paragraph:0"),
        source("p0-1", "compat-paragraph:1"),
        translation("t1", "compat-paragraph:1"),
        .pageBreak(pageIndex: 1),
        source("p1-0", "compat-paragraph:2"),
        translation("t2", "compat-paragraph:2")
    ])
}

@Test func translatedUnitsRefillByIDInsteadOfResponseOrder() {
    let first = SourceParagraph(text: "same", pageIndex: 0, translationUnitID: .init("p:first"))
    let second = SourceParagraph(text: "same", pageIndex: 0, translationUnitID: .init("p:second"))
    let doc = ParsedDocument(paragraphs: [first, second], pageCount: 1)
    let options = ExportOptions(content: .translationOnly, format: .pdf, pageMode: .continuous)

    let result = DocumentComposer.compose(
        doc: doc,
        translatedUnits: [
            TranslatedUnit(id: .init("p:second"), text: "second translation"),
            TranslatedUnit(id: .init("p:first"), text: "first translation"),
        ],
        options: options,
        direction: .enToZh
    )

    #expect(result.blocks == [
        translation("first translation", "p:first"),
        translation("second translation", "p:second"),
    ])
}

@Test func pageAlignedEmitsBreakWithAbsolutePageIndexAcrossEmptyPages() {
    // 页 1 为空(无段落):break 直接从 0 跳到 2,导出器据此补空白页。
    let doc = ParsedDocument(
        paragraphs: [
            SourceParagraph(text: "p0-0", pageIndex: 0),
            SourceParagraph(text: "p2-0", pageIndex: 2)
        ],
        pageCount: 3
    )
    let options = ExportOptions(content: .extractionOnly, format: .pdf, pageMode: .pageAligned)

    let result = DocumentComposer.compose(doc: doc, translations: [], options: options, direction: nil)

    #expect(result.blocks == [
        .pageBreak(pageIndex: 0),
        source("p0-0", "compat-paragraph:0"),
        .pageBreak(pageIndex: 2),
        source("p2-0", "compat-paragraph:1")
    ])
}

@Test func pageAlignedAppendsTrailingBreakForTrailingEmptyPages() {
    // 末尾空白页(页 1、2 无段落):补一个指向最后一页的 break,保证输出页数 == 源页数。
    let doc = ParsedDocument(
        paragraphs: [SourceParagraph(text: "p0-0", pageIndex: 0)],
        pageCount: 3
    )
    let options = ExportOptions(content: .extractionOnly, format: .pdf, pageMode: .pageAligned)

    let result = DocumentComposer.compose(doc: doc, translations: [], options: options, direction: nil)

    #expect(result.blocks == [
        .pageBreak(pageIndex: 0),
        source("p0-0", "compat-paragraph:0"),
        .pageBreak(pageIndex: 2)
    ])
}

@Test func translationOnlyContinuousProducesNoPageBreaks() {
    let doc = makeThreeParagraphDoc()
    let translations = ["t0", "t1", "t2"]
    let options = ExportOptions(content: .translationOnly, format: .pdf, pageMode: .continuous)

    let result = DocumentComposer.compose(doc: doc, translations: translations, options: options, direction: .enToZh)

    #expect(result.blocks == [
        translation("t0", "compat-paragraph:0"),
        translation("t1", "compat-paragraph:1"),
        translation("t2", "compat-paragraph:2")
    ])
}

@Test func listMarkersAreReappliedToSourceAndTranslatedBlocks() {
    let doc = ParsedDocument(
        paragraphs: [
            SourceParagraph(text: "Preparation", pageIndex: 0, listMarker: "1."),
            SourceParagraph(text: "Complete Mental Model development", pageIndex: 0, listMarker: "•"),
        ],
        pageCount: 1
    )
    let options = ExportOptions(content: .bilingual, format: .markdown, pageMode: .continuous)

    let result = DocumentComposer.compose(doc: doc, translations: ["准备", "完成心智模型开发"], options: options, direction: .enToZh)

    #expect(result.blocks == [
        source("1. Preparation", "compat-paragraph:0", kind: .listItem(marker: "1.")),
        translation("1. 准备", "compat-paragraph:0", kind: .listItem(marker: "1.")),
        source("• Complete Mental Model development", "compat-paragraph:1", kind: .listItem(marker: "•")),
        translation("• 完成心智模型开发", "compat-paragraph:1", kind: .listItem(marker: "•")),
    ])
}

@Test func extractionOnlyProducesOnlySourceText() {
    let doc = makeThreeParagraphDoc()
    let options = ExportOptions(content: .extractionOnly, format: .pdf, pageMode: .continuous)

    let result = DocumentComposer.compose(doc: doc, translations: [], options: options, direction: nil)

    #expect(result.blocks == [
        source("p0-0", "compat-paragraph:0"),
        source("p0-1", "compat-paragraph:1"),
        source("p1-0", "compat-paragraph:2")
    ])
}

@Test func bilingualWithMismatchedTranslationsCountFallsBackToSourceOnly() {
    let doc = makeThreeParagraphDoc()
    let options = ExportOptions(content: .bilingual, format: .pdf, pageMode: .continuous)

    let result = DocumentComposer.compose(doc: doc, translations: [], options: options, direction: .enToZh)

    #expect(result.blocks == [
        source("p0-0", "compat-paragraph:0"),
        source("p0-1", "compat-paragraph:1"),
        source("p1-0", "compat-paragraph:2")
    ])
}

@Test func semanticKindsAndGroupsFlowToBilingualBlocks() {
    let paragraph = SourceParagraph(
        text: "Chapter", pageIndex: 0, kind: .heading(level: 2), translationUnitID: .init("heading")
    )
    let result = DocumentComposer.compose(
        doc: ParsedDocument(paragraphs: [paragraph], pageCount: 1),
        translations: ["章节"],
        options: .init(content: .bilingual, format: .markdown, pageMode: .continuous),
        direction: .enToZh
    )
    #expect(result.blocks == [
        .sourceText(.init(text: "Chapter", groupID: .init("heading"), kind: .heading(level: 2))),
        .translatedText(.init(text: "章节", groupID: .init("heading"), kind: .heading(level: 2))),
    ])
}
