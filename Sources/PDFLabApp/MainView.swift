import AppKit
import SwiftUI
import UniformTypeIdentifiers
import PDFLabCore

/// 主界面:查看/翻译/转换三张模块卡片 + 最近打开历史列表。
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

    @State private var path: [Destination] = []
    @State private var historyState = MainHistoryState()
    @State private var historyFileSizes: [String: String] = [:]
    @State private var historySizeTask: Task<Void, Never>?
    @State private var pendingModule: PendingModule?
    @State private var showFileImporter = false
    @State private var translateDialog: TranslateDialogRequest?
    @State private var missingEntry: HistoryEntry?
    @State private var launchUpdate: UpdateInfo?

    var body: some View {
        NavigationStack(path: $path) {
            moduleArea
            .navigationDestination(for: Destination.self) { destination in
                switch destination {
                case .viewer(let url):
                    ViewerView(url: url) { openedURL in
                        viewerDidOpen(openedURL)
                    } onClose: {
                        popViewer()
                    }
                case .viewerPair(let sourceURL, let outputURL):
                    ViewerView(url: sourceURL, secondaryURL: outputURL) { openedURL in
                        viewerDidOpen(openedURL)
                    } onClose: {
                        popViewer()
                    }
                }
            }
        }
        .toolbar {
            ToolbarItemGroup(placement: .navigation) {
                Button {
                    if HomeToolbarPolicy.logoAction(hasNavigationPath: !path.isEmpty) == .returnHome {
                        path.removeAll()
                    }
                } label: {
                    Image(nsImage: NSApp.applicationIconImage)
                        .resizable()
                        .scaledToFit()
                        .frame(width: 20, height: 20)
                }
                .buttonStyle(.plain)
                .accessibilityLabel(L10n.t("app.name"))
                .help(L10n.t("app.name"))

                if HomeToolbarPolicy.showsAddDocument(hasNavigationPath: !path.isEmpty) {
                    Button {
                        pendingModule = .viewer
                        showFileImporter = true
                    } label: {
                        Image(systemName: "plus")
                    }
                    .accessibilityLabel(L10n.t("viewer.addTab"))
                    .help(L10n.t("viewer.addTab"))
                }
            }
        }
        .background(MainWindowResizeControl(isResizeEnabled: translateDialog == nil && !app.settingsPresented))
        .onAppear { reloadHistory() }
        .onDisappear {
            historySizeTask?.cancel()
            historySizeTask = nil
        }
        // 设置 sheet 清空历史后广播 historyRevision,主界面据此重载缓存列表。
        .onChange(of: app.historyRevision) { reloadHistory() }
        // 翻译面板占用主窗口 sheet 位时,⌘, 打开设置的请求被 AppState 守卫忽略,
        // 避免同层两个 sheet 争抢(settingsPresented 卡 true 后齿轮失效)。
        .onChange(of: translateDialog?.id) { app.translateSheetActive = translateDialog != nil }
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
        // 设置面板:固定尺寸主窗口 sheet(替代已弃用的 Settings 独立窗口场景)。
        .sheet(isPresented: $app.settingsPresented) {
            SettingsView()
                .environmentObject(app)
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
                app.presentSettingsIfIdle()
                launchUpdate = nil
            }
            Button(L10n.t("update.alert.close"), role: .cancel) {
                launchUpdate = nil
            }
        } message: {
            Text("\(L10n.t("update.available")) \(launchUpdate?.version ?? "")")
        }
    }

    // MARK: - 模块与最近打开

    private var moduleArea: some View {
        VStack(alignment: .leading, spacing: 28) {
            moduleCards
            historySection
        }
        .padding(.horizontal, HomeLayout.horizontalInset)
        .padding(.top, HomeLayout.topInset)
        .padding(.bottom, 28)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }

    private var moduleCards: some View {
        HStack(spacing: HomeLayout.moduleCardSpacing) {
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
            moduleCard(
                title: L10n.t("main.convert"),
                subtitle: L10n.t("main.convert.subtitle"),
                systemImage: "arrow.triangle.2.circlepath.doc.on.clipboard",
                isEnabled: false
            ) {}
        }
    }

    private func moduleCard(
        title: String,
        subtitle: String,
        systemImage: String,
        isEnabled: Bool = true,
        action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            HStack(spacing: 8) {
                Image(systemName: systemImage)
                    .font(.system(size: 22, weight: .medium))
                    .foregroundStyle(.tint)
                    .frame(width: HomeLayout.moduleIconSize, height: HomeLayout.moduleIconSize)

                VStack(alignment: .leading, spacing: 4) {
                    HStack(spacing: 6) {
                        Text(title)
                            .font(.callout.weight(.semibold))
                        if !isEnabled {
                            Text(L10n.t("main.convert.disabled"))
                                .font(.caption2.weight(.medium))
                                .foregroundStyle(.secondary)
                                .lineLimit(1)
                        }
                    }
                    Text(subtitle)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .padding(.horizontal, 16)
            .frame(maxWidth: .infinity, minHeight: HomeLayout.moduleCardHeight, maxHeight: HomeLayout.moduleCardHeight, alignment: .leading)
            .background(.quaternary.opacity(0.5), in: RoundedRectangle(cornerRadius: 8))
            .modifier(ModuleCardInteraction(isEnabled: isEnabled))
        }
        .buttonStyle(.plain)
        .disabled(!isEnabled)
        .help(isEnabled ? title : L10n.t("main.convert.disabled"))
    }

    private var historySection: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text(L10n.t("history.title"))
                    .font(.callout)

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

            if historyState.entries.isEmpty {
                Text(L10n.t("history.empty"))
                    .font(.callout)
                    .foregroundStyle(.tertiary)
                    .frame(maxWidth: .infinity, minHeight: 120, alignment: .center)
            } else {
                ScrollView {
                    LazyVStack(spacing: 0) {
                        ForEach(historyState.entries, id: \.path) { entry in
                            historyRow(entry)
                        }
                    }
                }
                .frame(minHeight: 180)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }

    private func historyRow(_ entry: HistoryEntry) -> some View {
        HStack(spacing: 16) {
            Text(entry.fileName)
                .lineLimit(1)
                .truncationMode(.tail)
                .frame(maxWidth: .infinity, alignment: .leading)
            Text(HomeHistoryPresentation.formatOpenedAt(entry.openedAt))
                .foregroundStyle(.secondary)
                .lineLimit(1)
                .frame(width: HomeLayout.historyOpenedColumnWidth, alignment: .leading)
            Text(historyFileSizes[entry.path] ?? L10n.t("history.sizeUnknown"))
                .foregroundStyle(.secondary)
                .lineLimit(1)
                .frame(width: HomeLayout.historySizeColumnWidth, alignment: .leading)
        }
        .font(.callout)
        .frame(height: HomeLayout.historyRowHeight)
        .contentShape(Rectangle())
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
        reloadHistoryFileSizes()
    }

    private func viewerDidOpen(_ url: URL) {
        historyState.viewerDidOpen(url, history: app.history)
        reloadHistoryFileSizes()
    }

    private func clearHistory() {
        historyState.clear(history: app.history)
        historySizeTask?.cancel()
        historySizeTask = nil
        historyFileSizes = [:]
    }

    private func reloadHistoryFileSizes() {
        historySizeTask?.cancel()
        let paths = historyState.entries.map(\.path)
        let retained = historyFileSizes.filter { paths.contains($0.key) }
        historyFileSizes = retained

        historySizeTask = Task {
            let worker = Task.detached(priority: .utility) {
                var result: [String: String] = [:]
                for path in paths {
                    guard !Task.isCancelled else { return result }
                    let url = URL(fileURLWithPath: path)
                    if let byteCount = try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize {
                        result[path] = ByteCountFormatter.string(
                            fromByteCount: Int64(byteCount),
                            countStyle: .file
                        )
                    }
                }
                return result
            }
            let sizes = await withTaskCancellationHandler {
                await worker.value
            } onCancel: {
                worker.cancel()
            }
            guard !Task.isCancelled,
                  historyState.entries.map(\.path) == paths else { return }
            historyFileSizes = sizes
        }
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

private struct ModuleCardInteraction: ViewModifier {
    var isEnabled: Bool

    @ViewBuilder
    func body(content: Content) -> some View {
        if isEnabled {
            content.hoverHighlight()
        } else {
            content.opacity(0.55)
        }
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
