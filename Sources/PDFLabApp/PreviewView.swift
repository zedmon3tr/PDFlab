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

    static func cleanupSummaryText(_ summary: TextCleanupSummary, format: String = L10n.t("translate.cleanupSummary")) -> String {
        String(
            format: format,
            String(summary.repeatedEdgeLines),
            String(summary.pageNumbers),
            String(summary.ocrJunkLines)
        )
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
        } else if content == .bilingual {
            HStack(alignment: .top, spacing: 16) {
                previewText(row.source ?? "", foreground: .secondary)
                previewText(row.translation ?? "", foreground: .primary)
            }
        } else {
            previewText(row.source ?? row.translation ?? "", foreground: .primary)
        }
    }

    private func previewText(_ text: String, foreground: HierarchicalShapeStyle) -> some View {
        Text(text)
            .font(.body)
            .foregroundStyle(foreground)
            .textSelection(.enabled)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(12)
            .background(.quaternary.opacity(0.35), in: RoundedRectangle(cornerRadius: 8))
    }
}

struct PreviewRow: Equatable {
    var pageIndex: Int?
    var source: String?
    var translation: String?

    static func rows(from document: ComposedDocument, content: OutputContent) -> [PreviewRow] {
        var rows: [PreviewRow] = []
        var pendingSource: String?
        var pageSources: [String] = []
        var pageTranslations: [String] = []

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
            case .sourceText(let text):
                if content == .bilingual {
                    if let source = pendingSource {
                        pageSources.append(source)
                    }
                    pendingSource = text
                } else {
                    pageSources.append(text)
                }
            case .translatedText(let text):
                if content == .bilingual {
                    appendPendingSource()
                    pageTranslations.append(text)
                    pendingSource = nil
                } else {
                    pageTranslations.append(text)
                }
            }
        }

        flushPageContent()

        return rows
    }
}
