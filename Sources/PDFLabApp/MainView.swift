import SwiftUI
import UniformTypeIdentifiers
import PDFLabCore

/// 主界面:查看/翻译两张模块卡片 + 最近打开历史列表。
/// 导航目的地为占位视图,Task 20(ViewerView)/ Task 21(TranslateFlowView)替换。
struct MainView: View {
    /// 导航目的地。Task 20/21 的视图接入点:
    /// `.viewer(url)` → ViewerView(url:),`.translate(url)` → TranslateFlowView(url:)。
    enum Destination: Hashable {
        case viewer(URL)
        case translate(URL)
    }

    /// 卡片点击后待执行的模块(决定选完文件去哪个目的地)。
    private enum PendingModule {
        case viewer
        case translate
    }

    @EnvironmentObject private var app: AppState

    @State private var path: [Destination] = []
    @State private var entries: [HistoryEntry] = []
    @State private var pendingModule: PendingModule?
    @State private var showFileImporter = false
    @State private var missingEntry: HistoryEntry?

    var body: some View {
        NavigationStack(path: $path) {
            VStack(alignment: .leading, spacing: 24) {
                moduleCards
                historySection
            }
            .padding(28)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            .navigationTitle(L10n.t("app.name"))
            .navigationDestination(for: Destination.self) { destination in
                switch destination {
                case .viewer(let url):
                    ViewerView(url: url)
                case .translate:
                    // Task 21:替换为 TranslateFlowView(url:)
                    Text("Translate")
                }
            }
        }
        .onAppear { reloadHistory() }
        .fileImporter(
            isPresented: $showFileImporter,
            allowedContentTypes: pendingModule == .translate ? [.pdf] : ViewerView.openableContentTypes,
            allowsMultipleSelection: false
        ) { result in
            guard case .success(let urls) = result, let url = urls.first else { return }
            open(url: url)
        }
        .alert(
            L10n.t("history.missing"),
            isPresented: Binding(
                get: { missingEntry != nil },
                set: { if !$0 { missingEntry = nil } }
            )
        ) {
            Button(L10n.t("history.missing.remove"), role: .destructive) {
                if let entry = missingEntry {
                    app.history.remove(path: entry.path)
                    reloadHistory()
                }
                missingEntry = nil
            }
            Button(L10n.t("common.cancel"), role: .cancel) {
                missingEntry = nil
            }
        } message: {
            Text(missingEntry?.fileName ?? "")
        }
    }

    // MARK: - 模块卡片

    private var moduleCards: some View {
        HStack(spacing: 20) {
            moduleCard(
                title: L10n.t("main.view"),
                subtitle: L10n.t("main.view.subtitle"),
                systemImage: "doc.text.magnifyingglass"
            ) {
                pendingModule = .viewer
                showFileImporter = true
            }
            moduleCard(
                title: L10n.t("main.translate"),
                subtitle: L10n.t("main.translate.subtitle"),
                systemImage: "character.book.closed"
            ) {
                pendingModule = .translate
                showFileImporter = true
            }
        }
    }

    private func moduleCard(
        title: String,
        subtitle: String,
        systemImage: String,
        action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            VStack(alignment: .leading, spacing: 10) {
                Image(systemName: systemImage)
                    .font(.system(size: 30, weight: .medium))
                    .foregroundStyle(.tint)
                Text(title)
                    .font(.title2.weight(.semibold))
                Text(subtitle)
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(20)
            .background(.quaternary.opacity(0.5), in: RoundedRectangle(cornerRadius: 12))
        }
        .buttonStyle(.plain)
    }

    // MARK: - 历史列表

    private var historySection: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(L10n.t("history.title"))
                .font(.headline)
                .foregroundStyle(.secondary)

            if entries.isEmpty {
                Text(L10n.t("history.empty"))
                    .font(.callout)
                    .foregroundStyle(.tertiary)
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .center)
            } else {
                List(entries, id: \.path) { entry in
                    historyRow(entry)
                }
                .listStyle(.inset)
                .scrollContentBackground(.hidden)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }

    private func historyRow(_ entry: HistoryEntry) -> some View {
        HStack {
            Image(systemName: "doc.richtext")
                .foregroundStyle(.secondary)
            VStack(alignment: .leading, spacing: 2) {
                Text(entry.fileName)
                Text(entry.path)
                    .font(.caption)
                    .foregroundStyle(.tertiary)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }
            Spacer()
            Text(entry.openedAt, style: .date)
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .contentShape(Rectangle())
        .onTapGesture { openHistoryEntry(entry) }
        .contextMenu {
            Button(L10n.t("history.remove"), role: .destructive) {
                app.history.remove(path: entry.path)
                reloadHistory()
            }
        }
    }

    // MARK: - 行为

    private func reloadHistory() {
        entries = app.history.entries()
    }

    private func open(url: URL) {
        switch pendingModule {
        case .translate:
            app.history.record(url: url)
            reloadHistory()
            path.append(.translate(url))
        default:
            path.append(.viewer(url))
        }
        pendingModule = nil
    }

    private func openHistoryEntry(_ entry: HistoryEntry) {
        let url = URL(fileURLWithPath: entry.path)
        guard FileManager.default.fileExists(atPath: entry.path) else {
            missingEntry = entry
            return
        }
        path.append(.viewer(url))
    }
}
