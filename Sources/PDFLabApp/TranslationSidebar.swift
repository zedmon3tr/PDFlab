import SwiftUI
import PDFLabCore

struct ParagraphHighlight: Equatable {
    var pageIndex: Int
    var bbox: CGRect
}

struct ParagraphClickSelection {
    var pageIndex: Int
    var paragraphIndex: Int
    var paragraph: PageParagraph
}

struct ParagraphClickConfiguration {
    var highlight: ParagraphHighlight?
    var onSelection: @MainActor (ParagraphClickSelection) -> Void
    var onMiss: @MainActor () -> Void
}

struct ParagraphTranslationEntry: Identifiable, Equatable {
    let id: UUID
    var pageIndex: Int
    var sourceText: String
    var isLowQualityOCR: Bool
    var state: ParagraphTranslationState

    init(
        id: UUID = UUID(),
        pageIndex: Int,
        sourceText: String,
        isLowQualityOCR: Bool = false,
        state: ParagraphTranslationState = .loading
    ) {
        self.id = id
        self.pageIndex = pageIndex
        self.sourceText = sourceText
        self.isLowQualityOCR = isLowQualityOCR
        self.state = state
    }
}

enum ParagraphTranslationState: Equatable {
    case loading
    case translated(String)
    case failed(message: String, suggestsEngineSwitch: Bool)
}

struct TranslationSidebar: View {
    var entries: [ParagraphTranslationEntry]
    var onClear: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 8) {
                Text(L10n.t("viewer.paragraph.sidebar.title"))
                    .font(.headline)
                Spacer()
                Button(action: onClear) {
                    Image(systemName: "trash")
                }
                .buttonStyle(HoverButtonStyle(variant: .toolbar))
                .help(L10n.t("viewer.paragraph.sidebar.clear"))
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 10)

            Divider()

            ScrollView {
                LazyVStack(alignment: .leading, spacing: 10) {
                    ForEach(entries) { entry in
                        ParagraphTranslationEntryView(entry: entry)
                    }
                }
                .padding(12)
            }
        }
        .frame(width: 320)
        .background(Color(nsColor: .windowBackgroundColor))
    }
}

private struct ParagraphTranslationEntryView: View {
    var entry: ParagraphTranslationEntry

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 6) {
                Text(String(format: L10n.t("viewer.paragraph.sidebar.page"), entry.pageIndex + 1))
                    .font(.caption)
                    .foregroundStyle(.secondary)
                if entry.isLowQualityOCR {
                    Text(L10n.t("viewer.paragraph.lowQuality"))
                        .font(.caption2.weight(.medium))
                        .foregroundStyle(.orange)
                        .padding(.horizontal, 5)
                        .padding(.vertical, 2)
                        .background(.orange.opacity(0.12), in: Capsule())
                }
            }

            Text(entry.sourceText)
                .font(.callout)
                .foregroundStyle(.secondary)
                .lineLimit(4)
                .truncationMode(.tail)

            Divider()

            switch entry.state {
            case .loading:
                HStack(spacing: 8) {
                    ProgressView()
                        .controlSize(.small)
                    Text(L10n.t("viewer.paragraph.sidebar.loading"))
                        .font(.callout)
                        .foregroundStyle(.secondary)
                }
            case .translated(let text):
                Text(text)
                    .font(.body)
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
            case .failed(let message, let suggestsEngineSwitch):
                VStack(alignment: .leading, spacing: 4) {
                    Text(message)
                        .font(.callout)
                        .foregroundStyle(.red)
                    if suggestsEngineSwitch {
                        Text(L10n.t("viewer.bubble.suggestSwitch"))
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
            }
        }
        .padding(10)
        .background(Color(nsColor: .controlBackgroundColor), in: RoundedRectangle(cornerRadius: 8))
        .overlay(
            RoundedRectangle(cornerRadius: 8)
                .strokeBorder(Color.primary.opacity(0.08), lineWidth: 1)
        )
    }
}
