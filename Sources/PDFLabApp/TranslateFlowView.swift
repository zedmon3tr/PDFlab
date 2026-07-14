import AppKit
import PDFKit
import SwiftUI
import UniformTypeIdentifiers
import PDFLabCore

struct TranslateFlowView: View {
    let initialURL: URL?
    let openInViewer: (URL, URL) -> Void
    let close: () -> Void

    @EnvironmentObject private var app: AppState

    @State private var state = TranslateFlowState()
    @State private var didHandleInitialURL = false
    @State private var showFileImporter = false
    @State private var passwordRequest: TranslatePasswordRequest?
    @State private var passwordInput = ""
    @State private var passwordFailure: String?
    @State private var softLimitWarning: TranslateSoftLimitWarning?
    @State private var directionRequest: TranslateDirectionRequest?
    @State private var alert: TranslateAlert?
    @State private var runTask: Task<Void, Never>?
    @State private var isSaving = false

    init(
        url: URL? = nil,
        openInViewer: @escaping (URL, URL) -> Void = { _, _ in },
        close: @escaping () -> Void = {}
    ) {
        initialURL = url
        self.openInViewer = openInViewer
        self.close = close
    }

    var body: some View {
        content
            .navigationTitle(L10n.t("translate.title"))
            .onAppear(perform: handleInitialURL)
            .fileImporter(
                isPresented: $showFileImporter,
                allowedContentTypes: [.pdf],
                allowsMultipleSelection: false
            ) { result in
                switch result {
                case .success(let urls):
                    guard let url = urls.first else { return }
                    prepareFile(url, password: nil)
                case .failure(let error):
                    alert = TranslateAlert(title: L10n.t("translate.openFailed"), message: error.localizedDescription)
                }
            }
            .alert(item: $alert) { item in
                Alert(
                    title: Text(item.title),
                    message: Text(item.message),
                    dismissButton: .default(Text(L10n.t("common.confirm")))
                )
            }
            .alert(
                L10n.t("translate.password.title"),
                isPresented: Binding(
                    get: { passwordRequest != nil },
                    set: { isPresented in
                        if !isPresented {
                            passwordRequest = nil
                            passwordInput = ""
                            passwordFailure = nil
                        }
                    }
                )
            ) {
                SecureField(L10n.t("viewer.password.prompt"), text: $passwordInput)
                Button(L10n.t("viewer.password.open")) {
                    guard let request = passwordRequest else { return }
                    let password = passwordInput
                    passwordRequest = nil
                    passwordInput = ""
                    prepareFile(request.url, password: password)
                }
                Button(L10n.t("common.cancel"), role: .cancel) {
                    passwordRequest = nil
                    passwordInput = ""
                    passwordFailure = nil
                }
            } message: {
                Text(passwordFailure ?? passwordRequest?.url.lastPathComponent ?? "")
            }
            .alert(
                L10n.t("translate.softLimit.title"),
                isPresented: Binding(
                    get: { softLimitWarning != nil },
                    set: { if !$0 { softLimitWarning = nil } }
                )
            ) {
                Button(L10n.t("common.confirm")) {
                    if let warning = softLimitWarning {
                        acceptFile(warning.url, password: warning.password, pageCount: warning.check.pageCount)
                    }
                    softLimitWarning = nil
                }
                Button(L10n.t("common.cancel"), role: .cancel) {
                    softLimitWarning = nil
                }
            } message: {
                Text(softLimitWarning?.message ?? "")
            }
            .sheet(item: $directionRequest) { request in
                UnsupportedLanguageDialog(
                    request: request,
                    chooseEnglish: { retryWithForcedDirection(.enToZh) },
                    chooseChinese: { retryWithForcedDirection(.zhToEn) },
                    cancel: {
                        directionRequest = nil
                        state.phase = .optionsReady
                    }
                )
            }
    }

    @ViewBuilder
    private var content: some View {
        switch state.phase {
        case .idle:
            idleView
        case .optionsReady:
            optionsView
        case .running:
            runningView
        case .previewing:
            previewingView
        case .saved:
            savedView
        }
    }

    private var idleView: some View {
        VStack(spacing: 16) {
            Image(systemName: "doc.text.magnifyingglass")
                .font(.system(size: 30, weight: .regular))
                .foregroundStyle(.secondary)
            Text(L10n.t("translate.idle.title"))
                .font(.title3.weight(.semibold))
            Button(L10n.t("translate.chooseFile")) {
                showFileImporter = true
            }
            .buttonStyle(HoverButtonStyle(variant: .primary))
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .onDrop(of: [UTType.fileURL.identifier], isTargeted: nil) { providers in
            guard let provider = providers.first else { return false }
            provider.loadItem(forTypeIdentifier: UTType.fileURL.identifier, options: nil) { item, _ in
                let url: URL?
                if let data = item as? Data {
                    url = URL(dataRepresentation: data, relativeTo: nil)
                } else {
                    url = item as? URL
                }
                if let url {
                    DispatchQueue.main.async {
                        prepareFile(url, password: nil)
                    }
                }
            }
            return true
        }
    }

    private var optionsView: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(alignment: .top, spacing: TranslateOptionsLayout.columnGap) {
                sourcePreviewPane

                VStack(alignment: .leading, spacing: TranslateOptionsLayout.sectionGap) {
                    fileHeader
                    settingsPane

                    Text(L10n.t("translate.pageRange.hint"))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .frame(width: TranslateOptionsLayout.settingsWidth, alignment: .leading)

                    Text(L10n.t("translate.ocrLanguage.help"))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .frame(width: TranslateOptionsLayout.settingsWidth, alignment: .leading)

                    Spacer(minLength: 0)
                    optionsActionBar
                }
                .frame(
                    width: TranslateOptionsLayout.settingsWidth,
                    height: TranslateOptionsLayout.panelHeight,
                    alignment: .topLeading
                )
            }
            .frame(
                width: TranslateOptionsLayout.panelWidth,
                height: TranslateOptionsLayout.panelHeight,
                alignment: .topLeading
            )
        }
        .padding(.horizontal, TranslateOptionsLayout.windowHorizontal)
        .padding(.top, TranslateOptionsLayout.windowTop)
        .padding(.bottom, TranslateOptionsLayout.windowBottom)
        .frame(
            width: TranslateOptionsLayout.dialogWidth,
            height: TranslateOptionsLayout.dialogHeight,
            alignment: .topLeading
        )
    }

    private var sourcePreviewPane: some View {
        VStack(spacing: 12) {
            if let sourceURL = state.sourceURL {
                PDFPagePreview(
                    url: sourceURL,
                    password: state.password,
                    pageIndex: state.previewPageIndex
                )
                .allowsHitTesting(false)
                .clipShape(RoundedRectangle(cornerRadius: 6))
                .overlay {
                    RoundedRectangle(cornerRadius: 6)
                        .stroke(.quaternary, lineWidth: 1)
                }
                .frame(
                    width: TranslateOptionsLayout.previewWidth,
                    height: TranslateOptionsLayout.previewHeight
                )
            } else {
                ContentUnavailableView {
                    Label(L10n.t("viewer.noDocument"), systemImage: "doc")
                }
                .frame(
                    width: TranslateOptionsLayout.previewWidth,
                    height: TranslateOptionsLayout.previewHeight
                )
            }

            HStack(spacing: 10) {
                Button {
                    state.movePreviewPage(by: -1)
                } label: {
                    Image(systemName: "chevron.left")
                }
                .buttonStyle(HoverButtonStyle(variant: .toolbar))
                .disabled(!state.canMoveToPreviousPreviewPage)
                .help(L10n.t("translate.preview.previousPage"))

                Text(state.previewPageDisplayText)
                    .font(.callout.monospacedDigit())
                    .foregroundStyle(.secondary)
                    .frame(minWidth: 72)

                Button {
                    state.movePreviewPage(by: 1)
                } label: {
                    Image(systemName: "chevron.right")
                }
                .buttonStyle(HoverButtonStyle(variant: .toolbar))
                .disabled(!state.canMoveToNextPreviewPage)
                .help(L10n.t("translate.preview.nextPage"))
            }
        }
        .frame(
            width: TranslateOptionsLayout.previewWidth,
            height: TranslateOptionsLayout.panelHeight,
            alignment: .top
        )
    }

    private var settingsPane: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(L10n.t("translate.settings.title"))
                .font(.headline)

            VStack(spacing: 0) {
                settingsRow(title: L10n.t("translate.content")) {
                    Picker(L10n.t("translate.content"), selection: $state.options.content) {
                        Text(L10n.t("translate.content.bilingual")).tag(OutputContent.bilingual)
                        Text(L10n.t("translate.content.translationOnly")).tag(OutputContent.translationOnly)
                        Text(L10n.t("translate.content.extractionOnly")).tag(OutputContent.extractionOnly)
                    }
                }
                settingsDivider
                settingsRow(title: L10n.t("translate.ocrLanguage")) {
                    Picker(
                        L10n.t("translate.ocrLanguage"),
                        selection: Binding(
                            get: { state.ocrLanguage },
                            set: { state.setOCRLanguage($0) }
                        )
                    ) {
                        ForEach(OCRLanguage.allCases, id: \.self) { language in
                            Text(state.ocrLanguageLabel(for: language)).tag(language)
                        }
                    }
                }
                settingsDivider
                settingsRow(title: L10n.t("translate.targetLanguage")) {
                    Picker(L10n.t("translate.targetLanguage"), selection: $state.targetLanguage) {
                        ForEach(TranslationTargetLanguage.allCases, id: \.self) { language in
                            Text(TranslateFlowState.targetLanguageName(for: language)).tag(language)
                        }
                    }
                }
                settingsDivider
                settingsRow(title: L10n.t("translate.engine")) {
                    Picker(L10n.t("translate.engine"), selection: $state.engineID) {
                        ForEach(TranslationEngineDescriptor.availableOnCurrentOS) { descriptor in
                            Text(L10n.t("engine.\(descriptor.id)")).tag(descriptor.id)
                        }
                    }
                }
                settingsDivider
                settingsRow(title: L10n.t("translate.format")) {
                    Picker(L10n.t("translate.format"), selection: $state.options.format) {
                        Text("Markdown").tag(OutputFormat.markdown)
                        Text("PDF").tag(OutputFormat.pdf)
                        Text("DOCX").tag(OutputFormat.docx)
                    }
                }
                settingsDivider
                settingsRow(title: L10n.t("translate.pageMode")) {
                    Picker(L10n.t("translate.pageMode"), selection: $state.options.pageMode) {
                        Text(L10n.t("translate.pageMode.pageAligned")).tag(PageMode.pageAligned)
                        Text(L10n.t("translate.pageMode.continuous")).tag(PageMode.continuous)
                    }
                }
                settingsDivider
                settingsRow(title: L10n.t("translate.pageRange")) {
                    TextField(
                        "",
                        text: $state.pageRangeText,
                        prompt: Text(L10n.t("translate.pageRange.placeholder"))
                    )
                    .textFieldStyle(.roundedBorder)
                    .accessibilityLabel(L10n.t("translate.pageRange"))
                    .accessibilityHint(L10n.t("translate.pageRange.hint"))
                }
            }
            .background(.quaternary.opacity(0.18), in: RoundedRectangle(cornerRadius: 6))
            .overlay {
                RoundedRectangle(cornerRadius: 6)
                    .stroke(.quaternary, lineWidth: 1)
            }
        }
        .frame(width: TranslateOptionsLayout.settingsWidth, alignment: .leading)
    }

    private var settingsDivider: some View {
        Divider()
            .padding(.leading, 12)
    }

    private func settingsRow<Control: View>(
        title: String,
        @ViewBuilder control: () -> Control
    ) -> some View {
        HStack(spacing: 12) {
            Text(title)
                .font(.callout.weight(.medium))
                .foregroundStyle(.primary)
                .frame(width: TranslateOptionsLayout.settingsLabelWidth, alignment: .leading)

            Spacer(minLength: 12)

            control()
                .labelsHidden()
                .pickerStyle(.menu)
                .frame(width: TranslateOptionsLayout.settingsControlWidth, alignment: .trailing)
        }
        .padding(.horizontal, 12)
        .frame(width: TranslateOptionsLayout.settingsWidth, height: TranslateOptionsLayout.settingsRowHeight)
    }

    private var optionsActionBar: some View {
        HStack {
            Button {
                startPipeline()
            } label: {
                Label(L10n.t("translate.start"), systemImage: "play.fill")
            }
            .buttonStyle(HoverButtonStyle(variant: .primary))

            Button(L10n.t("common.cancel")) {
                closeFlow()
            }
            .buttonStyle(HoverButtonStyle())
        }
        .frame(width: TranslateOptionsLayout.settingsWidth, alignment: .trailing)
    }

    private var runningView: some View {
        VStack(spacing: 14) {
            ProgressView(value: progressValue)
                .frame(width: 360)
                .animation(.easeInOut(duration: 0.25), value: progressValue)
            TimelineView(.periodic(from: Date(), by: 1)) { context in
                HStack(spacing: 8) {
                    ProgressView()
                        .controlSize(.small)
                        .frame(width: 16)
                    Text(progressText(now: context.date))
                        .monospacedDigit()
                        .foregroundStyle(.secondary)
                }
            }
            Button(role: .cancel) {
                cancelRunningTask()
            } label: {
                Label(L10n.t("translate.cancelRun"), systemImage: "xmark.circle")
            }
            .buttonStyle(HoverButtonStyle(variant: .danger))
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var previewingView: some View {
        VStack(spacing: 0) {
            if let composed = state.composed {
                PreviewView(
                    document: composed,
                    content: state.options.content,
                    lowQualityPages: state.parsed?.lowQualityPages ?? []
                )
            }
            Divider()
            HStack {
                Button {
                    saveCurrentDocument()
                } label: {
                    Label(L10n.t("translate.save"), systemImage: "square.and.arrow.down")
                }
                .buttonStyle(HoverButtonStyle(variant: .primary))
                .disabled(isSaving)

                Button(L10n.t("translate.backToOptions")) {
                    state.phase = .optionsReady
                }
                .buttonStyle(HoverButtonStyle())
                .disabled(isSaving)

                if isSaving {
                    ProgressView()
                        .controlSize(.small)
                }
                Spacer()
            }
            .padding(12)
        }
    }

    private var savedView: some View {
        VStack(alignment: .leading, spacing: 14) {
            Label(L10n.t("translate.saved.title"), systemImage: "checkmark.circle.fill")
                .font(.title3.weight(.semibold))
                .foregroundStyle(.green)

            if let outputURL = state.outputURL {
                Text(outputURL.path)
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .textSelection(.enabled)
            }

            HStack {
                Button {
                    if let sourceURL = state.sourceURL, let outputURL = state.outputURL {
                        app.history.record(url: sourceURL)
                        openInViewer(sourceURL, outputURL)
                    }
                } label: {
                    Label(L10n.t("translate.openInViewer"), systemImage: "rectangle.split.2x1")
                }
                .buttonStyle(HoverButtonStyle(variant: .primary))
                .disabled(state.sourceURL == nil || state.outputURL == nil)

                Button(L10n.t("translate.saveAgain")) {
                    state.phase = .previewing
                }
                .buttonStyle(HoverButtonStyle())
                Button(L10n.t("translate.newFile")) {
                    closeFlow()
                }
                .buttonStyle(HoverButtonStyle())
            }
        }
        .padding(28)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }

    private var fileHeader: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(state.sourceURL?.lastPathComponent ?? "")
                .font(.headline)
            Text(state.sourceURL?.path ?? "")
                .font(.caption)
                .foregroundStyle(.secondary)
                .lineLimit(1)
                .truncationMode(.middle)
        }
    }

    private var progressValue: Double {
        TranslateProgressFormatter.value(for: state.progress)
    }

    private func progressText(now: Date = Date()) -> String {
        TranslateProgressFormatter.text(for: state.progress, startedAt: state.runStartedAt, now: now)
    }

    private func handleInitialURL() {
        guard !didHandleInitialURL else { return }
        didHandleInitialURL = true
        if let initialURL {
            prepareFile(initialURL, password: nil)
        }
    }

    private func prepareFile(_ url: URL, password: String?) {
        guard url.pathExtension.lowercased() == "pdf" else {
            alert = TranslateAlert(title: L10n.t("translate.openFailed"), message: L10n.t("error.notAPDF"))
            return
        }

        do {
            let check = try TranslationPipeline.softLimitCheck(url: url, password: password)
            if check.exceeds {
                softLimitWarning = TranslateSoftLimitWarning(url: url, password: password, check: check)
            } else {
                acceptFile(url, password: password, pageCount: check.pageCount)
            }
        } catch PDFLabError.encryptedPDFWrongPassword {
            passwordFailure = password == nil ? nil : L10n.message(for: .encryptedPDFWrongPassword)
            passwordRequest = TranslatePasswordRequest(url: url)
        } catch let error as PDFLabError {
            alert = TranslateAlert(title: L10n.t("translate.openFailed"), message: translateErrorMessage(error))
        } catch {
            alert = TranslateAlert(title: L10n.t("translate.openFailed"), message: error.localizedDescription)
        }
    }

    private func acceptFile(_ url: URL, password: String?, pageCount: Int = 1) {
        // 需求 3.1:翻译模块导入的文件不进入历史(历史只记查看模块主文件)。
        state.acceptFile(url, password: password, pageCount: pageCount)
        state.engineID = app.resolvedEngineID
    }

    private func startPipeline() {
        guard let sourceURL = state.sourceURL else { return }
        if TranslateEnginePrecheck.hasMissingCredential(
            engineID: state.engineID,
            credential: { KeychainStore.load(key: $0) }
        ) {
            alert = TranslateAlert(
                title: L10n.t("translate.failed"),
                message: L10n.t("translate.engine.missingKey")
            )
            return
        }
        let pageRange: ClosedRange<Int>?
        do {
            pageRange = try TranslationPageRange.parse(state.pageRangeText, totalPages: state.previewPageCount)
        } catch let error as PDFLabError {
            alert = TranslateAlert(title: L10n.t("translate.failed"), message: translateErrorMessage(error))
            return
        } catch {
            alert = TranslateAlert(title: L10n.t("translate.failed"), message: error.localizedDescription)
            return
        }
        runTask?.cancel()
        state.startRunning()

        let input = PipelineInput(
            url: sourceURL,
            password: state.password,
            options: state.options,
            ocrLanguage: state.ocrLanguage,
            targetLanguage: state.targetLanguage,
            forcedDirection: state.forcedDirection,
            pageRange: pageRange
        )
        let pipeline = TranslationPipeline(engine: app.makeEngine(engineID: state.engineID))

        runTask = Task {
            do {
                let (composed, parsed) = try await pipeline.run(input) { progress in
                    Task { @MainActor in
                        state.update(progress: progress)
                    }
                }
                await MainActor.run {
                    state.markPreview(composed: composed, parsed: parsed)
                    runTask = nil
                }
            } catch PDFLabError.unsupportedLanguage(let detected) {
                await MainActor.run {
                    state.phase = .optionsReady
                    directionRequest = TranslateDirectionRequest(detected: detected)
                    runTask = nil
                }
            } catch let error as PDFLabError {
                await MainActor.run {
                    if error == .cancelled {
                        state.reset()
                    } else {
                        state.phase = .optionsReady
                        alert = TranslateAlert(title: L10n.t("translate.failed"), message: translateErrorMessage(error))
                    }
                    runTask = nil
                }
            } catch {
                await MainActor.run {
                    state.phase = .optionsReady
                    alert = TranslateAlert(title: L10n.t("translate.failed"), message: error.localizedDescription)
                    runTask = nil
                }
            }
        }
    }

    private func retryWithForcedDirection(_ direction: TranslationDirection) {
        directionRequest = nil
        state.forcedDirection = direction
        startPipeline()
    }

    private func cancelRunningTask() {
        runTask?.cancel()
        runTask = nil
        closeFlow()
    }

    private func resetFlow() {
        state.reset()
    }

    private func closeFlow() {
        runTask?.cancel()
        runTask = nil
        close()
    }

    private func saveCurrentDocument() {
        guard let composed = state.composed,
              let sourceURL = state.sourceURL,
              !isSaving else { return }

        // 保存面板必须留在主线程;真正的导出(CoreText 排版 / zip 子进程)
        // 移到主线程外执行,避免大文档导出时 UI 卡死(需求 §5 全程异步)。
        let panel = NSSavePanel()
        panel.allowedContentTypes = [saveContentType(for: state.options.format)]
        panel.canCreateDirectories = true
        let defaultOutputURL = TranslateFlowState.defaultOutputURL(sourceURL: sourceURL, format: state.options.format)
        panel.directoryURL = defaultOutputURL.deletingLastPathComponent()
        panel.nameFieldStringValue = defaultOutputURL.lastPathComponent

        guard panel.runModal() == .OK, let outputURL = panel.url else { return }

        let format = state.options.format
        let uiLanguageChinese = L10n.isChinese
        isSaving = true
        Task {
            defer { isSaving = false }
            do {
                try await Task.detached(priority: .userInitiated) {
                    try Self.performExport(
                        composed,
                        to: outputURL,
                        format: format,
                        uiLanguageChinese: uiLanguageChinese
                    )
                }.value
                state.markSaved(outputURL: outputURL)
            } catch let error as PDFLabError {
                alert = TranslateAlert(title: L10n.t("translate.saveFailed"), message: translateErrorMessage(error))
            } catch {
                alert = TranslateAlert(title: L10n.t("translate.saveFailed"), message: error.localizedDescription)
            }
        }
    }

    private nonisolated static func performExport(
        _ document: ComposedDocument,
        to url: URL,
        format: OutputFormat,
        uiLanguageChinese: Bool
    ) throws {
        switch format {
        case .markdown:
            try MarkdownExporter().export(document, to: url, uiLanguageChinese: uiLanguageChinese)
        case .pdf:
            try PDFExporter().export(document, to: url, uiLanguageChinese: uiLanguageChinese)
        case .docx:
            try DocxExporter().export(document, to: url, uiLanguageChinese: uiLanguageChinese)
        }
    }

    private func saveContentType(for format: OutputFormat) -> UTType {
        switch format {
        case .markdown:
            return UTType(filenameExtension: "md") ?? .plainText
        case .pdf:
            return .pdf
        case .docx:
            return UTType(filenameExtension: "docx") ?? .data
        }
    }

    private func translateErrorMessage(_ error: PDFLabError) -> String {
        let base = L10n.message(for: error)
        switch error {
        case .engineInvalidKey, .engineRateLimited, .engineUnavailable, .networkError:
            return "\(base)\n\(L10n.t("translate.engineSuggestion"))"
        default:
            return base
        }
    }
}

private struct PDFPagePreview: NSViewRepresentable {
    let url: URL
    let password: String?
    let pageIndex: Int

    func makeCoordinator() -> Coordinator {
        Coordinator()
    }

    func makeNSView(context: Context) -> PDFView {
        let pdfView = NonScrollingPDFView()
        pdfView.autoScales = true
        pdfView.displayMode = .singlePage
        pdfView.displayDirection = .vertical
        pdfView.displaysPageBreaks = false
        pdfView.backgroundColor = .clear
        return pdfView
    }

    func updateNSView(_ pdfView: PDFView, context: Context) {
        if context.coordinator.loadedURL != url || context.coordinator.loadedPassword != password {
            context.coordinator.loadedURL = url
            context.coordinator.loadedPassword = password

            let document = PDFDocument(url: url)
            if document?.isLocked == true, let password {
                document?.unlock(withPassword: password)
            }
            pdfView.document = document
            pdfView.autoScales = true
        }

        guard let document = pdfView.document, document.pageCount > 0 else { return }
        let clampedIndex = min(max(pageIndex, 0), document.pageCount - 1)
        guard let page = document.page(at: clampedIndex) else { return }
        pdfView.go(to: page)
    }

    final class Coordinator {
        var loadedURL: URL?
        var loadedPassword: String?
    }
}

enum TranslateOptionsLayout {
    static let dialogWidth: CGFloat = 900
    static let dialogHeight: CGFloat = 620
    static let windowHorizontal: CGFloat = 28
    static let windowTop: CGFloat = 28
    static let windowBottom: CGFloat = 24
    static let panelWidth: CGFloat = dialogWidth - windowHorizontal * 2
    static let panelHeight: CGFloat = dialogHeight - windowTop - windowBottom
    static let columnGap: CGFloat = 32
    static let sectionGap: CGFloat = 16
    static let previewWidth: CGFloat = 360
    static let previewHeight: CGFloat = 520
    static let settingsWidth: CGFloat = panelWidth - previewWidth - columnGap
    static let settingsLabelWidth: CGFloat = 112
    static let settingsControlWidth: CGFloat = 165
    static let settingsRowHeight: CGFloat = 40
}

private final class NonScrollingPDFView: PDFView {
    override func scrollWheel(with event: NSEvent) {}
}

private struct TranslatePasswordRequest {
    var url: URL
}

private struct TranslateSoftLimitWarning {
    var url: URL
    var password: String?
    var check: SoftLimitCheck

    var message: String {
        "\(L10n.t("translate.softLimit.message")) \(L10n.t("translate.pages")) \(check.pageCount), \(L10n.t("translate.size")) \(check.fileSizeMB)MB"
    }
}

private struct TranslateDirectionRequest: Identifiable {
    let id = UUID()
    var detected: String

    var message: String {
        "\(L10n.t("translate.unsupportedLanguage.message")) (\(detected))"
    }
}

private struct UnsupportedLanguageDialog: View {
    var request: TranslateDirectionRequest
    var chooseEnglish: () -> Void
    var chooseChinese: () -> Void
    var cancel: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            VStack(alignment: .leading, spacing: 8) {
                Text(L10n.t("translate.unsupportedLanguage.title"))
                    .font(.title3.weight(.semibold))
                Text(request.message)
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }

            HStack(spacing: 10) {
                Button(L10n.t("translate.direction.english")) {
                    chooseEnglish()
                }
                .buttonStyle(HoverButtonStyle(variant: .primary))

                Button(L10n.t("translate.direction.chinese")) {
                    chooseChinese()
                }
                .buttonStyle(HoverButtonStyle())

                Spacer()

                Button(L10n.t("common.cancel"), role: .cancel) {
                    cancel()
                }
                .buttonStyle(HoverButtonStyle())
            }
        }
        .padding(20)
        .frame(width: 420)
    }
}

private struct TranslateAlert: Identifiable {
    let id = UUID()
    var title: String
    var message: String
}
