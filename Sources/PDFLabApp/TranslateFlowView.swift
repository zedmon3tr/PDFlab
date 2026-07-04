import AppKit
import SwiftUI
import UniformTypeIdentifiers
import PDFLabCore

struct TranslateFlowState: Equatable {
    enum Phase: Equatable {
        case idle
        case optionsReady
        case running
        case previewing
        case saved
    }

    var phase: Phase = .idle
    var sourceURL: URL?
    var password: String?
    var options = ExportOptions(content: .bilingual, format: .markdown, pageMode: .pageAligned)
    var forcedDirection: TranslationDirection?
    var progress: PipelineProgress?
    var composed: ComposedDocument?
    var parsed: ParsedDocument?
    var outputURL: URL?

    mutating func acceptFile(_ url: URL, password: String? = nil) {
        sourceURL = url
        self.password = password
        forcedDirection = nil
        progress = nil
        composed = nil
        parsed = nil
        outputURL = nil
        phase = .optionsReady
    }

    mutating func startRunning() {
        progress = nil
        outputURL = nil
        phase = .running
    }

    mutating func update(progress: PipelineProgress) {
        self.progress = progress
    }

    mutating func markPreview(composed: ComposedDocument, parsed: ParsedDocument) {
        self.composed = composed
        self.parsed = parsed
        phase = .previewing
    }

    mutating func markSaved(outputURL: URL) {
        self.outputURL = outputURL
        phase = .saved
    }

    mutating func reset() {
        self = TranslateFlowState()
    }

    static func fileExtension(for format: OutputFormat) -> String {
        switch format {
        case .markdown: return "md"
        case .pdf: return "pdf"
        case .docx: return "docx"
        }
    }
}

struct TranslateFlowView: View {
    let initialURL: URL?
    let openInViewer: (URL, URL) -> Void

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

    init(
        url: URL? = nil,
        openInViewer: @escaping (URL, URL) -> Void = { _, _ in }
    ) {
        initialURL = url
        self.openInViewer = openInViewer
    }

    var body: some View {
        content
            .navigationTitle(L10n.t("translate.title"))
            .toolbar {
                ToolbarItemGroup {
                    Button {
                        showFileImporter = true
                    } label: {
                        Label(L10n.t("translate.chooseFile"), systemImage: "doc.badge.plus")
                    }
                    .disabled(state.phase == .running)
                    .buttonStyle(HoverButtonStyle(variant: .toolbar))
                    .help(L10n.t("translate.chooseFile"))
                }
            }
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
                        acceptFile(warning.url, password: warning.password)
                    }
                    softLimitWarning = nil
                }
                Button(L10n.t("common.cancel"), role: .cancel) {
                    softLimitWarning = nil
                }
            } message: {
                Text(softLimitWarning?.message ?? "")
            }
            .alert(
                L10n.t("translate.unsupportedLanguage.title"),
                isPresented: Binding(
                    get: { directionRequest != nil },
                    set: { if !$0 { directionRequest = nil } }
                )
            ) {
                Button(L10n.t("translate.direction.english")) {
                    retryWithForcedDirection(.enToZh)
                }
                Button(L10n.t("translate.direction.chinese")) {
                    retryWithForcedDirection(.zhToEn)
                }
                Button(L10n.t("common.cancel"), role: .cancel) {
                    directionRequest = nil
                    state.phase = .optionsReady
                }
            } message: {
                Text(directionRequest?.message ?? L10n.t("translate.unsupportedLanguage.message"))
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
                .font(.system(size: 42, weight: .regular))
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
        VStack(alignment: .leading, spacing: 18) {
            fileHeader

            Form {
                Picker(L10n.t("translate.content"), selection: $state.options.content) {
                    Text(L10n.t("translate.content.bilingual")).tag(OutputContent.bilingual)
                    Text(L10n.t("translate.content.translationOnly")).tag(OutputContent.translationOnly)
                    Text(L10n.t("translate.content.extractionOnly")).tag(OutputContent.extractionOnly)
                }
                Picker(L10n.t("translate.format"), selection: $state.options.format) {
                    Text("Markdown").tag(OutputFormat.markdown)
                    Text("PDF").tag(OutputFormat.pdf)
                    Text("DOCX").tag(OutputFormat.docx)
                }
                Picker(L10n.t("translate.pageMode"), selection: $state.options.pageMode) {
                    Text(L10n.t("translate.pageMode.pageAligned")).tag(PageMode.pageAligned)
                    Text(L10n.t("translate.pageMode.continuous")).tag(PageMode.continuous)
                }
            }
            .formStyle(.grouped)
            .frame(maxWidth: 560)

            HStack {
                Button {
                    startPipeline()
                } label: {
                    Label(L10n.t("translate.start"), systemImage: "play.fill")
                }
                .buttonStyle(HoverButtonStyle(variant: .primary))

                Button(L10n.t("common.cancel")) {
                    state.reset()
                }
                .buttonStyle(HoverButtonStyle())
            }
        }
        .padding(28)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }

    private var runningView: some View {
        VStack(spacing: 14) {
            ProgressView(value: progressValue)
                .frame(width: 360)
            Text(progressText)
                .foregroundStyle(.secondary)
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

                Button(L10n.t("translate.backToOptions")) {
                    state.phase = .optionsReady
                }
                .buttonStyle(HoverButtonStyle())
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
                    state.reset()
                }
                .buttonStyle(HoverButtonStyle())
            }
        }
        .padding(28)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }

    private var fileHeader: some View {
        HStack(spacing: 10) {
            Image(systemName: "doc.richtext")
                .foregroundStyle(.secondary)
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
    }

    private var progressValue: Double {
        guard let progress = state.progress, progress.totalPages > 0 else { return 0 }
        return min(max(Double(progress.currentPage) / Double(progress.totalPages), 0), 1)
    }

    private var progressText: String {
        guard let progress = state.progress else {
            return L10n.t("translate.running")
        }
        let stage = L10n.t("translate.stage.\(progress.stage.rawValue)")
        return "\(stage) \(L10n.t("translate.page.prefix")) \(progress.currentPage)/\(progress.totalPages)"
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
                acceptFile(url, password: password)
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

    private func acceptFile(_ url: URL, password: String?) {
        // 需求 3.1:翻译模块导入的文件不进入历史(历史只记查看模块主文件)。
        state.acceptFile(url, password: password)
    }

    private func startPipeline() {
        guard let sourceURL = state.sourceURL else { return }
        runTask?.cancel()
        state.startRunning()

        let input = PipelineInput(
            url: sourceURL,
            password: state.password,
            options: state.options,
            forcedDirection: state.forcedDirection
        )
        let pipeline = TranslationPipeline(engine: app.makeEngine())

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
        state.reset()
    }

    private func saveCurrentDocument() {
        guard let composed = state.composed,
              let sourceURL = state.sourceURL else { return }

        let panel = NSSavePanel()
        panel.allowedContentTypes = [saveContentType(for: state.options.format)]
        panel.canCreateDirectories = true
        panel.nameFieldStringValue = defaultOutputName(sourceURL: sourceURL, format: state.options.format)

        guard panel.runModal() == .OK, let outputURL = panel.url else { return }

        do {
            try export(composed, to: outputURL, format: state.options.format)
            state.markSaved(outputURL: outputURL)
        } catch let error as PDFLabError {
            alert = TranslateAlert(title: L10n.t("translate.saveFailed"), message: translateErrorMessage(error))
        } catch {
            alert = TranslateAlert(title: L10n.t("translate.saveFailed"), message: error.localizedDescription)
        }
    }

    private func export(_ document: ComposedDocument, to url: URL, format: OutputFormat) throws {
        switch format {
        case .markdown:
            try MarkdownExporter().export(document, to: url, uiLanguageChinese: L10n.isChinese)
        case .pdf:
            try PDFExporter().export(document, to: url, uiLanguageChinese: L10n.isChinese)
        case .docx:
            try DocxExporter().export(document, to: url, uiLanguageChinese: L10n.isChinese)
        }
    }

    private func defaultOutputName(sourceURL: URL, format: OutputFormat) -> String {
        let base = sourceURL.deletingPathExtension().lastPathComponent
        return "\(base)-translated.\(TranslateFlowState.fileExtension(for: format))"
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

private struct TranslateDirectionRequest {
    var detected: String

    var message: String {
        "\(L10n.t("translate.unsupportedLanguage.message")) (\(detected))"
    }
}

private struct TranslateAlert: Identifiable {
    let id = UUID()
    var title: String
    var message: String
}
