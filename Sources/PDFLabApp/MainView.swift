import AppKit
import SwiftUI
import UniformTypeIdentifiers
import PDFLabCore

/// 主界面:查看/翻译两张模块卡片 + 最近打开历史列表。
struct MainView: View {
    /// 导航目的地。翻译保存后的 viewer bridge 使用 `.viewerPair` 直接打开对照态。
    enum Destination: Hashable {
        case viewer(URL)
        case viewerPair(URL, URL)
    }

    /// 卡片点击后待执行的模块(决定选完文件去哪个目的地)。
    private enum PendingModule {
        case viewer
        case translate
    }

    @EnvironmentObject private var app: AppState
    @Environment(\.openSettings) private var openSettings

    @State private var path: [Destination] = []
    @State private var historyState = MainHistoryState()
    @State private var pendingModule: PendingModule?
    @State private var showFileImporter = false
    @State private var translateDialog: TranslateDialogRequest?
    @State private var missingEntry: HistoryEntry?
    @State private var launchUpdate: UpdateInfo?

    var body: some View {
        NavigationStack(path: $path) {
            HStack(spacing: 0) {
                historySidebar
                Divider()
                moduleArea
            }
            .navigationTitle(L10n.t("app.name"))
            .toolbar {
                ToolbarItem(placement: .navigation) {
                    Button {
                        openSettings()
                    } label: {
                        Image(systemName: "gearshape")
                    }
                    .help(L10n.t("settings.open.help"))
                }
            }
            .navigationDestination(for: Destination.self) { destination in
                switch destination {
                case .viewer(let url):
                    ViewerView(url: url) { openedURL in
                        historyState.viewerDidOpen(openedURL, history: app.history)
                    } onClose: {
                        popViewer()
                    }
                case .viewerPair(let sourceURL, let outputURL):
                    ViewerView(url: sourceURL, secondaryURL: outputURL) { openedURL in
                        historyState.viewerDidOpen(openedURL, history: app.history)
                    } onClose: {
                        popViewer()
                    }
                }
            }
        }
        .background(MainWindowResizeControl(isResizeEnabled: translateDialog == nil))
        .onAppear { reloadHistory() }
        // 设置面板(独立窗口)清空历史后广播 historyRevision,主界面据此重载缓存列表。
        .onChange(of: app.historyRevision) { reloadHistory() }
        .fileImporter(
            isPresented: $showFileImporter,
            allowedContentTypes: pendingModule == .translate ? [.pdf] : ViewerView.openableContentTypes,
            allowsMultipleSelection: false
        ) { result in
            guard case .success(let urls) = result, let url = urls.first else { return }
            open(url: url)
        }
        .sheet(item: $translateDialog) { request in
            TranslateFlowView(
                url: request.url,
                openInViewer: { sourceURL, outputURL in
                    translateDialog = nil
                    app.history.record(url: sourceURL)
                    reloadHistory()
                    path.append(.viewerPair(sourceURL, outputURL))
                },
                close: {
                    translateDialog = nil
                }
            )
            .environmentObject(app)
            .frame(width: TranslateOptionsLayout.dialogWidth, height: TranslateOptionsLayout.dialogHeight)
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
        .task {
            launchUpdate = await UpdateController.shared.checkAtLaunch()
        }
        .alert(
            L10n.t("update.alert.title"),
            isPresented: Binding(
                get: { launchUpdate != nil },
                set: { if !$0 { launchUpdate = nil } }
            )
        ) {
            Button(L10n.t("update.alert.view")) {
                app.settingsTab = "about"
                openSettings()
                launchUpdate = nil
            }
            Button(L10n.t("update.alert.close"), role: .cancel) {
                launchUpdate = nil
            }
        } message: {
            Text("\(L10n.t("update.available")) \(launchUpdate?.version ?? "")")
        }
    }

    // MARK: - 模块卡片(右侧主内容区)

    private var moduleArea: some View {
        VStack(alignment: .leading, spacing: 24) {
            moduleCards
            Spacer()
        }
        .padding(28)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }

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
            .hoverHighlight()
        }
        .buttonStyle(.plain)
    }

    // MARK: - 历史列表(左侧固定侧边栏)

    private var historySidebar: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text(L10n.t("history.title"))
                    .font(.headline)
                    .foregroundStyle(.secondary)

                Spacer()

                Button {
                    clearHistory()
                } label: {
                    Label(L10n.t("history.clear"), systemImage: "trash")
                        .labelStyle(.iconOnly)
                }
                .buttonStyle(HoverButtonStyle(variant: .danger))
                .disabled(historyState.entries.isEmpty)
                .help(L10n.t("history.clear"))
            }
            .padding(.horizontal, 16)
            .padding(.top, 16)

            if historyState.entries.isEmpty {
                Text(L10n.t("history.empty"))
                    .font(.callout)
                    .foregroundStyle(.tertiary)
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .center)
                    .padding(.horizontal, 16)
            } else {
                List(historyState.entries, id: \.path) { entry in
                    historyRow(entry)
                }
                .listStyle(.inset)
                .scrollContentBackground(.hidden)
            }
        }
        .frame(width: 260)
        .frame(maxHeight: .infinity, alignment: .topLeading)
        .background(.quaternary.opacity(0.25))
    }

    private func historyRow(_ entry: HistoryEntry) -> some View {
        HStack {
            VStack(alignment: .leading, spacing: 2) {
                Text(entry.fileName)
                    .lineLimit(2)
                    .truncationMode(.tail)
                Text(entry.path)
                    .font(.caption)
                    .foregroundStyle(.tertiary)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }
            Spacer()
        }
        .contentShape(Rectangle())
        .padding(8)
        .hoverHighlight()
        .onTapGesture { openHistoryEntry(entry) }
        .contextMenu {
            Button(L10n.t("history.remove"), role: .destructive) {
                app.history.remove(path: entry.path)
                reloadHistory()
            }
        }
    }

    // MARK: - 行为

    private func popViewer() {
        if !path.isEmpty {
            path.removeLast()
        }
    }

    private func reloadHistory() {
        historyState.reload(history: app.history)
    }

    private func clearHistory() {
        historyState.clear(history: app.history)
    }

    private func open(url: URL) {
        switch pendingModule {
        case .translate:
            // 需求 3.1:历史只记录查看模块打开的主文件,翻译模块导入不入历史。
            translateDialog = TranslateDialogRequest(url: url)
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

private struct TranslateDialogRequest: Identifiable {
    let id = UUID()
    var url: URL
}

private struct MainWindowResizeControl: NSViewRepresentable {
    var isResizeEnabled: Bool

    func makeCoordinator() -> Coordinator {
        Coordinator()
    }

    func makeNSView(context: Context) -> NSView {
        let view = NSView()
        DispatchQueue.main.async {
            context.coordinator.update(window: view.window, isResizeEnabled: isResizeEnabled)
        }
        return view
    }

    func updateNSView(_ nsView: NSView, context: Context) {
        DispatchQueue.main.async {
            context.coordinator.update(window: nsView.window, isResizeEnabled: isResizeEnabled)
        }
    }

    static func dismantleNSView(_ nsView: NSView, coordinator: Coordinator) {
        Task { @MainActor in
            coordinator.restore()
        }
    }

    final class Coordinator {
        private weak var window: NSWindow?
        private var resizeDelegate = MainWindowResizeDelegate()
        private weak var originalDelegate: NSWindowDelegate?

        @MainActor
        func update(window newWindow: NSWindow?, isResizeEnabled: Bool) {
            guard let newWindow else { return }
            AppWindowRegistry.shared.registerMainWindow(newWindow)
            if window !== newWindow {
                restore()
                window = newWindow
                originalDelegate = newWindow.delegate
                resizeDelegate.forwardDelegate = originalDelegate
                newWindow.delegate = resizeDelegate
            }

            resizeDelegate.blocksEdgeResize = !isResizeEnabled
        }

        @MainActor
        func restore() {
            if let window, window.delegate === resizeDelegate {
                window.delegate = originalDelegate
            }
            resizeDelegate.blocksEdgeResize = false
            resizeDelegate.forwardDelegate = nil
            self.window = nil
            self.originalDelegate = nil
        }
    }
}

private final class MainWindowResizeDelegate: NSObject, NSWindowDelegate {
    weak var forwardDelegate: NSWindowDelegate?
    var blocksEdgeResize = false
    private var lockedLiveResizeSize: NSSize?

    override func responds(to aSelector: Selector!) -> Bool {
        super.responds(to: aSelector) || (forwardDelegate?.responds(to: aSelector) ?? false)
    }

    override func forwardingTarget(for aSelector: Selector!) -> Any? {
        guard forwardDelegate?.responds(to: aSelector) == true else {
            return super.forwardingTarget(for: aSelector)
        }
        return forwardDelegate
    }

    func windowWillStartLiveResize(_ notification: Notification) {
        if blocksEdgeResize, let window = notification.object as? NSWindow {
            lockedLiveResizeSize = window.frame.size
        }
        forwardDelegate?.windowWillStartLiveResize?(notification)
    }

    func windowWillResize(_ sender: NSWindow, to frameSize: NSSize) -> NSSize {
        if blocksEdgeResize, sender.inLiveResize || lockedLiveResizeSize != nil {
            return lockedLiveResizeSize ?? sender.frame.size
        }
        return forwardDelegate?.windowWillResize?(sender, to: frameSize) ?? frameSize
    }

    func windowDidEndLiveResize(_ notification: Notification) {
        forwardDelegate?.windowDidEndLiveResize?(notification)
        lockedLiveResizeSize = nil
    }
}
