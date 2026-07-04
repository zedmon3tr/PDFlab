/// 将解析文档 + 译文按导出选项组装为渲染块序列(需求 3.6)。
public enum DocumentComposer {
    /// translations 与 doc.paragraphs 一一对应;extractionOnly 时 translations 传 []。
    /// 若 content 需要译文而 translations 数量与段落数不符,退化为仅输出源文,不崩溃。
    public static func compose(
        doc: ParsedDocument,
        translations: [String],
        options: ExportOptions,
        direction: TranslationDirection?
    ) -> ComposedDocument {
        let needsTranslation = options.content != .extractionOnly
        let hasValidTranslations = translations.count == doc.paragraphs.count
        let effectiveContent: OutputContent = (needsTranslation && !hasValidTranslations)
            ? .extractionOnly
            : options.content

        var blocks: [ComposedBlock] = []
        var lastPageIndex: Int?

        for (index, paragraph) in doc.paragraphs.enumerated() {
            if options.pageMode == .pageAligned, paragraph.pageIndex != lastPageIndex {
                blocks.append(.pageBreak(pageIndex: paragraph.pageIndex))
                lastPageIndex = paragraph.pageIndex
            }

            switch effectiveContent {
            case .translationOnly:
                blocks.append(.translatedText(translations[index]))
            case .bilingual:
                blocks.append(.sourceText(paragraph.text))
                blocks.append(.translatedText(translations[index]))
            case .extractionOnly:
                blocks.append(.sourceText(paragraph.text))
            }
        }

        return ComposedDocument(blocks: blocks, direction: direction)
    }
}
