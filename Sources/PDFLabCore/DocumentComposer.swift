/// 将解析文档 + 译文按导出选项组装为渲染块序列(需求 3.6)。
public enum DocumentComposer {
    /// 兼容数组 API；顺序为 ParsedDocument.blocks 中的段落、表格行翻译单元顺序。
    public static func compose(
        doc: ParsedDocument,
        translations: [String],
        options: ExportOptions,
        direction: TranslationDirection?
    ) -> ComposedDocument {
        let units = zip(translationUnitIDs(in: doc), translations).map { TranslatedUnit(id: $0.0, text: $0.1) }
        return compose(doc: doc, translatedUnits: units, options: options, direction: direction)
    }

    public static func compose(
        doc: ParsedDocument,
        translatedUnits: [TranslatedUnit],
        options: ExportOptions,
        direction: TranslationDirection?
    ) -> ComposedDocument {
        let expectedIDs = translationUnitIDs(in: doc)
        var translationsByID: [TranslationUnitID: String] = [:]
        for unit in translatedUnits { translationsByID[unit.id] = unit.text }
        let needsTranslation = options.content != .extractionOnly
        let valid = translationsByID.count == translatedUnits.count &&
            translatedUnits.count == expectedIDs.count && expectedIDs.allSatisfy { translationsByID[$0] != nil }
        let effectiveContent: OutputContent = needsTranslation && !valid ? .extractionOnly : options.content

        var blocks: [ComposedBlock] = []
        var lastPageIndex: Int?
        var paragraphIndex = 0
        for parsedBlock in doc.blocks {
            let pageIndex: Int
            switch parsedBlock {
            case .paragraph(let paragraph): pageIndex = paragraph.pageIndex
            case .table(let table): pageIndex = table.pageIndex
            }
            if options.pageMode == .pageAligned, pageIndex != lastPageIndex {
                blocks.append(.pageBreak(pageIndex: pageIndex))
                lastPageIndex = pageIndex
            }

            switch parsedBlock {
            case .paragraph(let paragraph):
                let unitID = resolvedID(for: paragraph, index: paragraphIndex)
                paragraphIndex += 1
                appendParagraph(
                    paragraph, unitID: unitID, translation: translationsByID[unitID],
                    content: effectiveContent, to: &blocks
                )
            case .table(let table):
                blocks.append(.tableRegion(.init(
                    groupID: table.translationUnitID,
                    pageIndex: table.pageIndex,
                    sourceRows: table.rows.map(\.text),
                    translatedRows: effectiveContent == .extractionOnly ? [] : table.rows.map { translationsByID[$0.translationUnitID] ?? "" },
                    content: effectiveContent
                )))
            }
        }

        if options.pageMode == .pageAligned,
           doc.pageCount > 0,
           (lastPageIndex ?? -1) < doc.pageCount - 1 {
            blocks.append(.pageBreak(pageIndex: doc.pageCount - 1))
        }
        return ComposedDocument(blocks: blocks, direction: direction)
    }

    private static func appendParagraph(
        _ paragraph: SourceParagraph,
        unitID: TranslationUnitID,
        translation: String?,
        content: OutputContent,
        to blocks: inout [ComposedBlock]
    ) {
        switch content {
        case .translationOnly:
            blocks.append(.translatedText(.init(
                text: paragraph.textWithListMarker(translation ?? ""), groupID: unitID, kind: composedKind(paragraph.kind)
            )))
        case .bilingual:
            blocks.append(.sourceText(.init(
                text: paragraph.displayText, groupID: unitID, kind: composedKind(paragraph.kind)
            )))
            blocks.append(.translatedText(.init(
                text: paragraph.textWithListMarker(translation ?? ""), groupID: unitID, kind: composedKind(paragraph.kind)
            )))
        case .extractionOnly:
            blocks.append(.sourceText(.init(
                text: paragraph.displayText, groupID: unitID, kind: composedKind(paragraph.kind)
            )))
        }
    }

    private static func translationUnitIDs(in doc: ParsedDocument) -> [TranslationUnitID] {
        var paragraphIndex = 0
        return doc.blocks.flatMap { block -> [TranslationUnitID] in
            switch block {
            case .paragraph(let paragraph):
                defer { paragraphIndex += 1 }
                return [resolvedID(for: paragraph, index: paragraphIndex)]
            case .table(let table): return table.rows.map(\.translationUnitID)
            }
        }
    }

    private static func resolvedID(for paragraph: SourceParagraph, index: Int) -> TranslationUnitID {
        paragraph.translationUnitID ?? TranslationUnitID("compat-paragraph:\(index)")
    }

    private static func composedKind(_ kind: SourceParagraphKind) -> ComposedTextKind {
        switch kind {
        case .body: return .body
        case .heading(let level): return .heading(level: level)
        case .listItem(let marker): return .listItem(marker: marker)
        case .footnote: return .footnote
        }
    }
}
