import SwiftUI
import PDFLabCore

struct PreviewView: View {
    var document: ComposedDocument
    var content: OutputContent
    var lowQualityPages: [Int]
    var cleanupSummary: TextCleanupSummary

    private var rows: [PreviewRow] {
        PreviewRow.rows(from: document, content: content)
    }

    static func cleanupSummaryText(_ summary: TextCleanupSummary, format: String? = nil) -> String {
        let values = [String(summary.repeatedEdgeLines), String(summary.pageNumbers), String(summary.ocrJunkLines)]
        if let format {
            return String(format: format, arguments: values + [String(summary.tableRegions)])
        }
        if summary.tableRegions > 0, summary.removedLineCount > 0 {
            return String(format: L10n.t("translate.cleanupSummaryWithTables"), arguments: values + [String(summary.tableRegions)])
        }
        if summary.tableRegions > 0 {
            return String(format: L10n.t("translate.tableSummary"), String(summary.tableRegions))
        }
        return String(format: L10n.t("translate.cleanupSummary"), arguments: values)
    }

    var body: some View {
        VStack(spacing: 0) {
            if !lowQualityPages.isEmpty {
                lowQualityBanner
            }
            if cleanupSummary.hasFilteredLines {
                cleanupSummaryBanner
            }

            ScrollView {
                LazyVStack(alignment: .leading, spacing: 12) {
                    ForEach(Array(rows.enumerated()), id: \.offset) { _, row in
                        rowView(row)
                    }
                }
                .padding(18)
            }
        }
    }

    private var lowQualityBanner: some View {
        HStack(spacing: 8) {
            Image(systemName: "exclamationmark.triangle.fill")
            Text("\(L10n.t("translate.lowQualityPages")) \(lowQualityPages.map { String($0 + 1) }.joined(separator: ", "))")
            Spacer()
        }
        .font(.callout)
        .foregroundStyle(.orange)
        .padding(.horizontal, 14)
        .padding(.vertical, 8)
        .background(.orange.opacity(0.12))
    }

    private var cleanupSummaryBanner: some View {
        HStack(spacing: 8) {
            Image(systemName: "line.3.horizontal.decrease.circle")
            Text(Self.cleanupSummaryText(cleanupSummary))
            Spacer()
        }
        .font(.callout)
        .foregroundStyle(.secondary)
        .padding(.horizontal, 14)
        .padding(.vertical, 8)
        .background(.quaternary.opacity(0.5))
    }

    @ViewBuilder
    private func rowView(_ row: PreviewRow) -> some View {
        if let pageIndex = row.pageIndex {
            Text("\(L10n.t("translate.preview.page")) \(pageIndex + 1)")
                .font(.headline)
                .foregroundStyle(.secondary)
                .padding(.top, 8)
        } else if row.isTable {
            VStack(alignment: .leading, spacing: 8) {
                Label(L10n.t("translate.preview.table"), systemImage: "tablecells")
                    .font(.callout.weight(.semibold))
                    .foregroundStyle(.secondary)
                if content == .bilingual {
                    HStack(alignment: .top, spacing: 16) {
                        previewTableText(row.source ?? "")
                        previewTableText(row.translation ?? "")
                    }
                } else {
                    previewTableText(row.source ?? row.translation ?? "")
                }
            }
        } else if content == .bilingual {
            HStack(alignment: .top, spacing: 16) {
                previewText(row.source ?? "", kind: row.kind, foreground: .secondary)
                previewText(row.translation ?? "", kind: row.kind, foreground: .primary)
            }
        } else {
            previewText(row.source ?? row.translation ?? "", kind: row.kind, foreground: .primary)
        }
    }

    private func previewTableText(_ text: String) -> some View {
        Text(text).font(.system(.body, design: .monospaced)).textSelection(.enabled)
            .frame(maxWidth: .infinity, alignment: .leading).padding(12)
            .background(.quaternary.opacity(0.35), in: RoundedRectangle(cornerRadius: 8))
    }

    private func previewText(_ text: String, kind: ComposedTextKind, foreground: HierarchicalShapeStyle) -> some View {
        let resolvedForeground: HierarchicalShapeStyle = kind == .footnote ? .secondary : foreground
        return Text(text)
            .font(Self.font(for: kind))
            .foregroundStyle(resolvedForeground)
            .textSelection(.enabled)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(12)
            .background(.quaternary.opacity(0.35), in: RoundedRectangle(cornerRadius: 8))
    }

    static func font(for kind: ComposedTextKind) -> Font {
        switch kind {
        case .heading(let level): return level == 1 ? .title2.bold() : .title3.bold()
        case .footnote: return .footnote
        case .body, .listItem: return .body
        }
    }
}

struct PreviewRow: Equatable {
    var pageIndex: Int?
    var source: String?
    var translation: String?
    var kind: ComposedTextKind = .body
    var isTable: Bool = false

    static func rows(from document: ComposedDocument, content: OutputContent) -> [PreviewRow] {
        var rows: [PreviewRow] = []
        var pendingSource: String?
        var pageSources: [String] = []
        var pageTranslations: [String] = []

        func appendSemantic(_ block: ComposedTextBlock, source: Bool) {
            flushPageContent()
            if source {
                rows.append(PreviewRow(source: block.text, kind: block.kind))
            } else if let last = rows.indices.last,
                      rows[last].translation == nil,
                      rows[last].kind == block.kind,
                      rows[last].source != nil {
                rows[last].translation = block.text
            } else {
                rows.append(PreviewRow(translation: block.text, kind: block.kind))
            }
        }

        func appendPendingSource() {
            if let source = pendingSource {
                pageSources.append(source)
                pendingSource = nil
            }
        }

        func joined(_ parts: [String]) -> String? {
            let text = parts
                .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
                .filter { !$0.isEmpty }
                .joined(separator: "\n\n")
            return text.isEmpty ? nil : text
        }

        func flushPageContent() {
            appendPendingSource()
            guard !pageSources.isEmpty || !pageTranslations.isEmpty else { return }
            rows.append(
                PreviewRow(
                    source: joined(pageSources),
                    translation: joined(pageTranslations)
                )
            )
            pageSources.removeAll()
            pageTranslations.removeAll()
        }

        for block in document.blocks {
            switch block {
            case .pageBreak(let pageIndex):
                flushPageContent()
                rows.append(PreviewRow(pageIndex: pageIndex))
            case .sourceText(let block):
                if isSemanticCallout(block.kind) {
                    appendSemantic(block, source: true)
                    continue
                }
                if content == .bilingual {
                    if let source = pendingSource {
                        pageSources.append(source)
                    }
                    pendingSource = block.text
                } else {
                    pageSources.append(block.text)
                }
            case .translatedText(let block):
                if isSemanticCallout(block.kind) {
                    appendSemantic(block, source: false)
                    continue
                }
                if content == .bilingual {
                    appendPendingSource()
                    pageTranslations.append(block.text)
                    pendingSource = nil
                } else {
                    pageTranslations.append(block.text)
                }
            case .tableRegion(let table):
                flushPageContent()
                rows.append(PreviewRow(
                    source: table.content == .translationOnly ? nil : table.sourceRows.joined(separator: "\n"),
                    translation: table.content == .extractionOnly ? nil : table.translatedRows.joined(separator: "\n"),
                    isTable: true
                ))
            }
        }

        flushPageContent()

        return rows
    }

    private static func isSemanticCallout(_ kind: ComposedTextKind) -> Bool {
        switch kind {
        case .heading, .footnote: return true
        case .body, .listItem: return false
        }
    }
}
