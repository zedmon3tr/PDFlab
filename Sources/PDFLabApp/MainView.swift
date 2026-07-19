import AppKit
import SwiftUI
import UniformTypeIdentifiers
import PDFLabCore

/// 主界面:查看/翻译/转换三张模块卡片 + 最近打开历史列表。
///
/// 浏览器 tab 语义:查看会话(ViewerSession)常驻,首页与查看器只是内容区切换
/// (ZStack + opacity,查看器视图不销毁,滚动/缩放状态保留);
/// 文档标签渲染收敛在这里的唯一 toolbar,首页也能点标签回查看器、点 × 关标签。
struct MainView: View {
    /// 卡片点击后待执行的模块(决定选完文件去哪个目的地)。
    private enum PendingModule {
        case viewer
        case translate
    }

    @EnvironmentObject private var app: AppState

    @StateObject private var session = ViewerSession()
    @State private var historyState = MainHistoryState()
    @State private var historyFileSizes: [String: String] = [:]
    @State private var historySizeTask: Task<Void, Never>?
    @State private var pendingModule: PendingModule?
    @State private var showFileImporter = false
    @State private var translateDialog: TranslateDialogRequest?
    @State private var missingEntry: HistoryEntry?
    @State private var launchUpdate: UpdateInfo?
    @State private var passwordInput = ""
    @State private var lossSaveInProgress = false

    var body: some View {
        content
            // 不显示默认窗口标题("PDFLabApp" 字样)。
            .navigationTitle("")
            .toolbar { toolbarContent }
            .background(MainWindowResizeControl(
                isResizeEnabled: translateDialog == nil && !app.settingsPresented && launchUpdate == nil
            ))
            .onAppear {
                reloadHistory()
                // 需求 3.1:历史只记录查看模块打开的主文件(会话只对 primary 回调)。
                session.onRecordOpen = { url in
                    app.history.record(url: url)
                    viewerDidOpen(url)
                }
            }
            .onDisappear {
                historySizeTask?.cancel()
                historySizeTask = nil
            }
            // 设置 sheet 清空历史后广播 historyRevision,主界面据此重载缓存列表。
            .onChange(of: app.historyRevision) { reloadHistory() }
            // 回到首页时刷新历史(查看会话期间可能新开过文档)。
            .onChange(of: session.isViewerVisible) {
                if !session.isViewerVisible { reloadHistory() }
            }
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
            .sheet(item: translationSheetBinding) { request in
                TranslateFlowView(
                    url: request.url,
                    openInViewer: { sourceURL, outputURL in
                        translateDialog = nil
                        // 翻译完成"立即对照查看":整体替换会话并直接进对照。
                        session.replacePair(source: sourceURL, output: outputURL)
                        if let id = app.translationResult.artifact?.id {
                            session.setTranslationArtifact(id: id, side: .secondary, isDirty: app.translationResult.artifact?.isDirty == true)
                        }
                    },
                    close: {
                        requestTranslationLoss(.closeSheet) { translateDialog = nil }
                    }
                )
                .environmentObject(app)
                .frame(width: TranslateOptionsLayout.dialogWidth, height: TranslateOptionsLayout.dialogHeight)
                .interactiveDismissDisabled(true)
            }
            // 设置面板:固定尺寸主窗口 sheet(替代已弃用的 Settings 独立窗口场景)。
            .sheet(isPresented: $app.settingsPresented) {
                SettingsView()
                    .environmentObject(app)
            }
            .alert(item: $session.alert) { item in
                Alert(
                    title: Text(item.title),
                    message: Text(item.message),
                    dismissButton: .default(Text(L10n.t("common.confirm")))
                )
            }
            .alert(
                L10n.t("viewer.password.title"),
                isPresented: passwordAlertPresented
            ) {
                SecureField(L10n.t("viewer.password.prompt"), text: $passwordInput)
                Button(L10n.t("viewer.password.open")) {
                    let password = passwordInput
                    passwordInput = ""
                    session.submitPassword(password)
                }
                Button(L10n.t("common.cancel"), role: .cancel) {
                    session.cancelPasswordRequest()
                    passwordInput = ""
                }
            } message: {
                if let failure = session.passwordFailure {
                    Text(failure)
                } else {
                    Text(session.passwordRequest?.url.lastPathComponent ?? "")
                }
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
                guard let info = await UpdateController.shared.checkAtLaunch() else { return }
                // 设置/翻译 sheet 已占用主窗口 sheet 位时静默不弹,
                // phase 已置 updateAvailable,关于页仍可见。
                guard AppState.shouldPresentUpdateSheet(
                    translateSheetActive: app.translateSheetActive,
                    settingsPresented: app.settingsPresented
                ) else { return }
                launchUpdate = info
            }
            // 更新 sheet 占位期间 ⌘,/齿轮打开设置的请求被守卫忽略(与翻译面板同范式)。
            .onChange(of: launchUpdate) { app.updateSheetActive = launchUpdate != nil }
            .sheet(isPresented: launchUpdatePresented) {
                if let info = launchUpdate {
                    UpdateSheetView(
                        updater: UpdateController.shared,
                        info: info,
                        dismiss: { launchUpdate = nil }   // 稍后提醒 = 关窗,本次会话不再弹
                    )
                }
            }
    }

    /// 内容区:首页 / 查看器二选一。查看器只要有文档就保持挂载(仅隐藏),
    /// PDFView 等 NSView 不销毁,滚动位置与缩放跨切换保留。
    private var content: some View {
        ZStack {
            if session.hasDocuments {
                ViewerView(session: session)
                    .opacity(session.isViewerVisible ? 1 : 0)
                    .allowsHitTesting(session.isViewerVisible)
                    .accessibilityHidden(!session.isViewerVisible)
            }
            if !session.isViewerVisible {
                moduleArea
            }
        }
    }

    // MARK: - 唯一 toolbar(logo + 文档标签 + "+" + 查看器工具项)

    @ToolbarContentBuilder
    private var toolbarContent: some ToolbarContent {
        ToolbarItemGroup(placement: .navigation) {
            logoButton
            if let primary = session.primary {
                DocumentTabView(
                    title: primary.title,
                    isActive: session.isTabActive(.primary),
                    isUnsaved: session.isTabUnsaved(.primary),
                    onFocus: { session.focusTab(.primary) },
                    onCloseTab: { requestTabClose(.primary) }
                )
            }
            if let secondary = session.secondary {
                DocumentTabView(
                    title: secondary.title,
                    isActive: session.isTabActive(.secondary),
                    isUnsaved: session.isTabUnsaved(.secondary),
                    onFocus: { session.focusTab(.secondary) },
                    onCloseTab: { requestTabClose(.secondary) }
                )
            }
            // 已开满 2 个文档时隐藏 "+"。
            if HomeToolbarPolicy.showsAddDocument(isSessionFull: session.isFull) {
                if session.hasDocuments {
                    // 参考图:标签区与 "+" 之间的细竖分隔线。
                    Rectangle()
                        .fill(Color(nsColor: .separatorColor))
                        .frame(
                            width: ViewerTabMetrics.separatorWidth,
                            height: ViewerTabMetrics.separatorHeight
                        )
                }
                Button {
                    addDocument()
                } label: {
                    Image(systemName: "plus")
                        .font(.callout.weight(.medium))
                }
                .buttonStyle(HoverButtonStyle(variant: .toolbar))
                .accessibilityLabel(L10n.t("viewer.addTab"))
                .help(L10n.t("viewer.addTab"))
            }
        }
        ToolbarItemGroup {
            // 滚动比例只在滚动对照有意义;逐页对照(readingLayout == .paged)由锚点偏移联动,隐藏比例项。
            if session.isViewerVisible, session.secondary != nil,
               session.effectiveLayout == .sideBySide,
               ViewerToolbarPolicy.showsRatioControls(isSideBySide: true, readingLayout: session.readingLayout) {
                ratioControl(L10n.t("viewer.leftRatio"), value: $session.ratioA)
                ratioControl(L10n.t("viewer.rightRatio"), value: $session.ratioB)
                resetRatioButton
            }
        }
        // “对照浏览”开关已移入查看器控制条(ViewerView.comparisonToggleControl),
        // 标题栏不再放该按钮。
    }

    private var logoButton: some View {
        Button {
            if HomeToolbarPolicy.logoAction(isViewerVisible: session.isViewerVisible) == .returnHome {
                session.returnHome()
            }
        } label: {
            Image(nsImage: NSApp.applicationIconImage)
                .resizable()
                .scaledToFit()
                .frame(width: 20, height: 20)
        }
        // 复用与 "+" 等工具栏按钮相同的 HoverButtonStyle,
        // 保证 hover/press/focus/disabled/Reduce Motion/增强对比度表现一致。
        .buttonStyle(HoverButtonStyle(variant: .toolbar))
        .accessibilityLabel(L10n.t("app.name"))
        .help(L10n.t("app.name"))
    }

    // macOS 工具栏常不渲染 Stepper 的 label,数值必须用独立 Text 显式呈现。
    private func ratioControl(_ title: String, value: Binding<Double>) -> some View {
        HStack(spacing: 4) {
            Text("\(title) \(Int((value.wrappedValue * 100).rounded()))%")
                .monospacedDigit()
                .frame(minWidth: 72, alignment: .trailing)
            Stepper(title, value: value, in: 0.5...2.0, step: 0.1)
                .labelsHidden()
                .help(L10n.t("viewer.ratio.help"))
        }
    }

    private var resetRatioButton: some View {
        Button {
            session.resetRatios()
        } label: {
            Label(L10n.t("viewer.resetRatio"), systemImage: "arrow.counterclockwise")
        }
        .buttonStyle(HoverButtonStyle(variant: .toolbar))
        .disabled(session.isDefaultRatio)
        .help(L10n.t("viewer.resetRatio"))
    }

    private var launchUpdatePresented: Binding<Bool> {
        Binding(
            get: { launchUpdate != nil },
            set: { if !$0 { launchUpdate = nil } }
        )
    }

    private var passwordAlertPresented: Binding<Bool> {
        Binding(
            get: { session.passwordRequest != nil },
            set: { isPresented in
                if !isPresented {
                    session.cancelPasswordRequest()
                    passwordInput = ""
                }
            }
        )
    }

    /// A titlebar close is a replacement of the sheet binding too. Route it through
    /// the same loss policy as the in-sheet close action instead of silently nil-ing it.
    private var translationSheetBinding: Binding<TranslateDialogRequest?> {
        Binding(
            get: { translateDialog },
            set: { request in
                guard request == nil, translateDialog != nil else {
                    translateDialog = request
                    return
                }
                requestTranslationLoss(.closeSheet) { translateDialog = nil }
            }
        )
    }

    private func requestTranslationLoss(_ action: TranslationLossAction, then continuation: @escaping () -> Void) {
        guard !lossSaveInProgress else {
            NSSound.beep()
            return
        }
        guard UnsavedTranslationPolicy.requiresConfirmation(
            isDirty: app.translationResult.hasUnsavedArtifact, action: action
        ) else {
            continuation()
            return
        }
        guard let artifact = app.translationResult.artifact else { return }
        let alert = NSAlert()
        alert.messageText = L10n.t("translation.unsaved.title")
        alert.informativeText = L10n.t("translation.unsaved.message")
        alert.addButton(withTitle: L10n.t("translation.saveAs"))
        alert.addButton(withTitle: L10n.t("translation.discard"))
        if alert.runModal() == .alertSecondButtonReturn {
            if action == .startTranslation { removeTranslationTab(artifact.id) }
            app.translationResult.discard()
            continuation()
            return
        }
        saveTranslationLossArtifact(artifact, then: continuation)
    }

    private func requestTabClose(_ side: ViewerSide) {
        guard session.isTabUnsaved(side) else { closeTabAndCleanTemporary(side); return }
        requestTranslationLoss(.closeTab) { closeTabAndCleanTemporary(side) }
    }

    private func discardActiveTranslationResult() {
        if let id = app.translationResult.artifact?.id {
            if session.translationID(for: .secondary) == id { session.closeTab(.secondary) }
            else if session.translationID(for: .primary) == id { session.closeTab(.primary) }
        }
        app.translationResult.discard()
    }

    private func beginNewTranslation() {
        discardActiveTranslationResult()
        pendingModule = .translate
        showFileImporter = true
    }

    private func removeTranslationTab(_ id: UUID) {
        if session.translationID(for: .secondary) == id { session.closeTab(.secondary) }
        else if session.translationID(for: .primary) == id { session.closeTab(.primary) }
    }

    private func closeTabAndCleanTemporary(_ side: ViewerSide) {
        let id = session.translationID(for: side)
        let saved = id == app.translationResult.artifact?.id && !app.translationResult.hasUnsavedArtifact
        session.closeTab(side)
        if saved { app.translationResult.discard() }
    }

    private func saveTranslationLossArtifact(_ artifact: TranslationArtifact, then continuation: @escaping () -> Void) {
        guard !lossSaveInProgress else { return }
        let artifactID = artifact.id
        lossSaveInProgress = true
        let panel = NSSavePanel()
        panel.allowedContentTypes = [saveContentType(for: artifact.options.format)]
        panel.canCreateDirectories = true
        let defaultURL = TranslateFlowState.defaultOutputURL(sourceURL: artifact.sourceURL, format: artifact.options.format)
        panel.directoryURL = defaultURL.deletingLastPathComponent()
        panel.nameFieldStringValue = defaultURL.lastPathComponent
        guard panel.runModal() == .OK, let outputURL = panel.url else {
            lossSaveInProgress = false
            return
        }
        Task {
            defer { lossSaveInProgress = false }
            do {
                try await Task.detached(priority: .userInitiated) {
                    try TranslateFlowView.performExport(
                        artifact.composed, to: outputURL, sourceURL: artifact.sourceURL,
                        format: artifact.options.format, uiLanguageChinese: L10n.isChinese
                    )
                }.value
                guard app.translationResult.artifact?.id == artifactID else {
                    let mismatch = NSError(
                        domain: "PDFLab.Translation",
                        code: 1,
                        userInfo: [
                            NSLocalizedDescriptionKey: L10n.t("translate.saveFailed")
                        ]
                    )
                    NSAlert(error: mismatch).runModal()
                    return
                }
                app.translationResult.markSaved(to: outputURL)
                session.markTranslationSaved(id: artifactID)
                continuation()
            } catch {
                NSAlert(error: error).runModal()
            }
        }
    }

    private func saveContentType(for format: OutputFormat) -> UTType {
        switch format {
        case .markdown: return UTType(filenameExtension: "md") ?? .plainText
        case .pdf: return .pdf
        case .docx: return UTType(filenameExtension: "docx") ?? .data
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
                requestTranslationLoss(.startTranslation) { beginNewTranslation() }
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
                    // 原型三张卡片同构(icon + 标题 + 副文案),禁用态不加可见角标,
                    // 仅靠 disabled + .help 提示"功能规划中"。
                    Text(title)
                        .font(.title3.weight(.semibold))
                    Text(subtitle)
                        .font(.callout)
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
        // 行内容与 hover 高亮框之间留出内边距,不顶到边缘。
        .padding(.horizontal, HomeLayout.historyRowHorizontalPadding)
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

    /// "+":无文档时走文件选择器开主文档;已有主文档时按对照流程选 PDF 加副文档。
    private func addDocument() {
        if session.hasDocuments {
            guard let picked = ViewerSecondaryDocumentPicker.pick() else { return }
            session.open(url: picked)
        } else {
            pendingModule = .viewer
            showFileImporter = true
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
            // 会话有空位则作为新标签加进会话并聚焦;开满 2 个由会话弹提示。
            session.open(url: url)
        }
        pendingModule = nil
    }

    private func openHistoryEntry(_ entry: HistoryEntry) {
        let url = URL(fileURLWithPath: entry.path)
        guard FileManager.default.fileExists(atPath: entry.path) else {
            missingEntry = entry
            return
        }
        session.open(url: url)
    }
}

/// 标题栏文档标签 hover 数值:非激活标签 hover 从无底色到轻 tonal 底;
/// 激活标签保留原有底色,hover 只轻微加深已有描边(幅度克制,不抢激活态本身的视觉权重)。
/// internal(非 private):供 ViewerInteractionTests 经 @testable import 覆盖设计范围断言。
enum DocumentTabHoverMetrics {
    static let inactiveHoverFillOpacity: Double = 0.07
    static let activeStrokeOpacity: Double = 0.12
    static let activeHoverStrokeOpacity: Double = 0.20
    static let animationBaseDuration: Double = 0.14
}

/// 文档标签(Chrome/PDF Expert 式):标题按钮 + 独立 × 关闭按钮。
/// hover 反馈覆盖整个标签矩形、不改变尺寸(只变 fill/描边);
/// × 自身的 hover 反馈由 TabCloseButtonStyle 独立负责,两者可同时可见(参考 Chrome 行为)。
private struct DocumentTabView: View {
    let title: String
    let isActive: Bool
    let isUnsaved: Bool
    let onFocus: () -> Void
    let onCloseTab: () -> Void

    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.colorSchemeContrast) private var colorSchemeContrast
    @State private var isHovering = false

    var body: some View {
        HStack(spacing: 8) {
            // 标签主体可点 → 聚焦该侧(首页点击 = 回查看器)。
            Button(action: onFocus) {
                HStack(spacing: 4) {
                    Text(title)
                        .font(.callout)
                        .foregroundStyle(isActive ? AnyShapeStyle(.primary) : AnyShapeStyle(.secondary))
                        .lineLimit(1)
                        .truncationMode(.middle)
                        .frame(maxWidth: ViewerTabMetrics.maxTitleWidth, alignment: .leading)
                    if isUnsaved {
                        Text(L10n.t("translation.unsaved.marker"))
                            .font(.caption2.weight(.medium))
                            .foregroundStyle(.orange)
                    }
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .help(title)
            .clickableHoverCursor()
            // × 关闭按钮独立,点击不穿透到聚焦;首页也可关。
            Button(action: onCloseTab) {
                Image(systemName: "xmark")
                    .font(.system(size: 9, weight: .bold))
            }
            .buttonStyle(TabCloseButtonStyle())
            .help(L10n.t("viewer.closeTab"))
        }
        .padding(.horizontal, ViewerTabMetrics.horizontalPadding)
        // 参考图(Chrome/PDF Expert 式):标签占满标题栏可用高度,仅激活标签有底色。
        .frame(height: ViewerTabMetrics.height)
        .background(fill, in: RoundedRectangle(cornerRadius: 6))
        .overlay(
            RoundedRectangle(cornerRadius: 6)
                .strokeBorder(stroke, lineWidth: 1)
        )
        .animation(
            .easeOut(duration: HoverMotion.animationDuration(base: DocumentTabHoverMetrics.animationBaseDuration, reduceMotion: reduceMotion)),
            value: isHovering
        )
        .onHover { hovering in
            isHovering = hovering
        }
        .onDisappear { isHovering = false }
    }

    /// 激活标签底色:亮色模式用内容底(textBackgroundColor,浅于标题栏),
    /// 暗色模式 textBackgroundColor 近黑、反而更暗,改用系统 quaternary fill 亮一档;
    /// 非激活标签无底色,hover 时给轻 tonal fill 提示可点。全部走系统语义色,不写死色值。
    private var fill: AnyShapeStyle {
        guard isActive else {
            return AnyShapeStyle(Color.primary.opacity(isHovering ? DocumentTabHoverMetrics.inactiveHoverFillOpacity : 0))
        }
        return colorScheme == .dark
            ? AnyShapeStyle(.quaternary)
            : AnyShapeStyle(Color(nsColor: .textBackgroundColor))
    }

    /// 非激活标签不加描边(只用 fill 表达 hover);激活标签描边 hover 时轻微加深。
    private var stroke: Color {
        let base = isActive
            ? (isHovering ? DocumentTabHoverMetrics.activeHoverStrokeOpacity : DocumentTabHoverMetrics.activeStrokeOpacity)
            : 0
        return Color.primary.opacity(HoverContrast.strokeOpacity(base: base, increasedContrast: colorSchemeContrast == .increased))
    }
}

/// 标签页 × 关闭按钮:小圆形命中区,hover 显示浅底 + pointingHand。
///
/// hover 视觉**即时呈现、不做渐变动画**(与 Safari/Chrome 原生标签 × 一致):
/// 曾两次尝试用 `.animation(value: isHovering)` 做 120ms 渐入,首次 hover 都会
/// 肉眼可见地闪一下(疑与首次 hover 时 tracking/手势初始化引发的状态抖动被动画
/// 放大有关,拆分动画作用域也没根治);即时切换下任何单帧抖动都不可感知。
/// 按下反馈保留独立动画作用域。
private struct TabCloseButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        TabCloseButtonBody(configuration: configuration)
    }

    private struct TabCloseButtonBody: View {
        let configuration: ButtonStyle.Configuration
        @Environment(\.accessibilityReduceMotion) private var reduceMotion
        @State private var isHovering = false

        var body: some View {
            configuration.label
                .foregroundStyle(isHovering ? AnyShapeStyle(.primary) : AnyShapeStyle(.secondary))
                .frame(width: 16, height: 16)
                .background(
                    Circle().fill(Color.primary.opacity(isHovering ? 0.12 : 0.0))
                )
                .opacity(configuration.isPressed ? 0.7 : 1)
                .animation(.easeOut(duration: HoverMotion.animationDuration(base: 0.08, reduceMotion: reduceMotion)), value: configuration.isPressed)
                .onHover { hovering in
                    var transaction = Transaction()
                    transaction.disablesAnimations = true
                    withTransaction(transaction) {
                        isHovering = hovering
                    }
                }
                .onDisappear { isHovering = false }
                .clickableHoverCursor()
        }
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
