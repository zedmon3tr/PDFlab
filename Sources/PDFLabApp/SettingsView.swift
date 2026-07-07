import SwiftUI
import PDFLabCore

/// 设置面板(`Settings` scene):外观 / 界面语言 / 翻译引擎 / 数据管理。
struct SettingsView: View {
    private enum TestState: Equatable {
        case idle
        case testing
        case success
        case failure(String)
    }

    @EnvironmentObject private var app: AppState
    @ObservedObject private var updater = UpdateController.shared

    // 秘密凭据只走 Keychain;本地 @State 仅作输入缓冲。
    @State private var llmAPIKey: String = ""

    @State private var testState: TestState = .idle
    @State private var pendingCloudEngineID: String?

    var body: some View {
        TabView(selection: $app.settingsTab) {
            generalTab
                .tabItem {
                    Label(L10n.t("settings.tab.general"), systemImage: "gearshape")
                }
                .tag("general")
            servicesTab
                .tabItem {
                    Label(L10n.t("settings.tab.services"), systemImage: "globe")
                }
                .tag("services")
            aboutTab
                .tabItem {
                    Label(L10n.t("settings.tab.about"), systemImage: "info.circle")
                }
                .tag("about")
        }
        .frame(width: 760)
        .frame(minHeight: 520)
        .onAppear(perform: loadSecrets)
        .alert(
            L10n.t("privacy.cloudNotice.title"),
            isPresented: Binding(
                get: { pendingCloudEngineID != nil },
                set: { if !$0 { pendingCloudEngineID = nil } }
            )
        ) {
            Button(L10n.t("common.confirm")) {
                if let id = pendingCloudEngineID {
                    app.cloudNoticeAcknowledged = true
                    app.engineID = id
                    testState = .idle
                }
                pendingCloudEngineID = nil
            }
            Button(L10n.t("common.cancel"), role: .cancel) {
                pendingCloudEngineID = nil
            }
        } message: {
            Text(L10n.t("privacy.cloudNotice"))
        }
    }

    // MARK: - Tab 页

    /// 设置(通用):外观 / 界面语言 / 数据管理。
    private var generalTab: some View {
        Form {
            appearanceSection
            languageSection
            dataSection
        }
        .formStyle(.grouped)
    }

    /// 服务:翻译引擎与凭据配置。
    private var servicesTab: some View {
        HStack(spacing: 0) {
            serviceList
                .frame(width: 250)

            Divider()

            serviceDetail
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    /// 关于:App 名称、版本、一句话简介。
    private var aboutTab: some View {
        VStack(spacing: 12) {
            Image(systemName: "doc.text.magnifyingglass")
                .font(.system(size: 44, weight: .medium))
                .foregroundStyle(.tint)
            Text(L10n.t("app.name"))
                .font(.title2.weight(.semibold))
            Text("\(L10n.t("about.version")) \(PDFLabCoreInfo.version)")
                .font(.callout)
                .foregroundStyle(.secondary)
            Text(L10n.t("about.blurb"))
                .font(.callout)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .padding(.horizontal, 40)
            updateSection
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    // MARK: - 检查更新

    @ViewBuilder
    private var updateSection: some View {
        VStack(spacing: 10) {
            switch updater.phase {
            case .idle:
                checkUpdateButton
            case .checking:
                checkUpdateButton
            case .upToDate:
                checkUpdateButton
                Text(L10n.t("update.upToDate"))
                    .font(.callout)
                    .foregroundStyle(.secondary)
            case .updateAvailable(let info):
                updateAvailableView(info)
            case .downloading(let fraction):
                if let fraction {
                    ProgressView(value: fraction) { Text(L10n.t("update.downloading")) }
                        .frame(width: 260)
                } else {
                    ProgressView(L10n.t("update.downloading"))
                        .controlSize(.small)
                }
            case .downloaded:
                Text(L10n.t("update.downloaded"))
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                    .padding(.horizontal, 40)
            case .failed(let message):
                checkUpdateButton
                Text(message)
                    .font(.callout)
                    .foregroundStyle(.red)
                    .multilineTextAlignment(.center)
                    .padding(.horizontal, 40)
            }

            Toggle(L10n.t("update.autoCheck"), isOn: $updater.autoCheckUpdates)
                .toggleStyle(.checkbox)
                .font(.callout)
        }
        .padding(.top, 8)
    }

    private var checkUpdateButton: some View {
        Button {
            Task { await updater.checkManually() }
        } label: {
            if updater.phase == .checking {
                HStack(spacing: 6) {
                    ProgressView().controlSize(.small)
                    Text(L10n.t("update.checking"))
                }
            } else {
                Text(L10n.t("update.check"))
            }
        }
        .disabled(updater.phase == .checking)
    }

    private func updateAvailableView(_ info: UpdateInfo) -> some View {
        VStack(spacing: 8) {
            Text("\(L10n.t("update.available")) \(info.version)")
                .font(.callout.weight(.semibold))
            if !info.releaseNotes.isEmpty {
                ScrollView {
                    Text(info.releaseNotes)
                        .font(.callout)
                        .textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
                .frame(maxHeight: 120)
                .padding(8)
                .background(.quaternary.opacity(0.5), in: RoundedRectangle(cornerRadius: 6))
                .padding(.horizontal, 40)
            }
            HStack {
                Button(L10n.t("update.download")) { updater.download(info) }
                    .buttonStyle(.borderedProminent)
                Button(L10n.t("update.skip")) { updater.skip(info) }
            }
        }
    }

    // MARK: - 外观 / 语言

    private var appearanceSection: some View {
        Section(L10n.t("settings.appearance")) {
            Picker(L10n.t("settings.appearance"), selection: $app.appearance) {
                Text(L10n.t("settings.appearance.system")).tag("system")
                Text(L10n.t("settings.appearance.light")).tag("light")
                Text(L10n.t("settings.appearance.dark")).tag("dark")
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .onChange(of: app.appearance) { _, _ in
                app.applyAppearance()
            }
        }
    }

    private var languageSection: some View {
        Section(L10n.t("settings.language")) {
            Picker(L10n.t("settings.language"), selection: $app.uiLanguage) {
                Text(L10n.t("settings.language.system")).tag("system")
                Text(L10n.t("settings.language.zh")).tag("zh")
                Text(L10n.t("settings.language.en")).tag("en")
            }
            .pickerStyle(.segmented)
            .labelsHidden()
        }
    }

    // MARK: - 引擎

    private var serviceList: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(L10n.t("settings.service.listTitle"))
                .font(.headline)
                .padding(.top, 16)
                .padding(.horizontal, 14)

            ScrollView {
                LazyVStack(spacing: 2) {
                    ForEach(TranslationEngineDescriptor.all) { service in
                        serviceRow(service)
                    }
                }
                .padding(.horizontal, 8)
                .padding(.bottom, 12)
            }
        }
        .background(.background)
    }

    /// 引擎切换拦截:首次选中云端引擎时先弹隐私确认,确认后才真正切换。
    private var engineSelection: Binding<String> {
        Binding(
            get: { app.engineID },
            set: { newValue in
                guard newValue != app.engineID else { return }
                if AppState.cloudEngineIDs.contains(newValue), !app.cloudNoticeAcknowledged {
                    pendingCloudEngineID = newValue
                } else {
                    app.engineID = newValue
                    testState = .idle
                }
            }
        )
    }

    private func serviceRow(_ service: TranslationEngineDescriptor) -> some View {
        let isCurrent = app.engineID == service.id

        return Button {
            engineSelection.wrappedValue = service.id
        } label: {
            HStack(spacing: 10) {
                Image(systemName: service.systemImage)
                    .font(.system(size: 15, weight: .medium))
                    .foregroundStyle(isCurrent ? .white : .secondary)
                    .frame(width: 18)

                Text(L10n.t("engine.\(service.id)"))
                    .font(.callout.weight(.medium))
                    .foregroundStyle(isCurrent ? .white : .primary)
                    .lineLimit(1)

                Spacer(minLength: 8)

                if let badge = service.enabledBadge(isCurrent: isCurrent) {
                    Text(badge)
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(isCurrent ? .white : .secondary)
                        .padding(.horizontal, 7)
                        .padding(.vertical, 3)
                        .background(
                            Capsule()
                                .fill(isCurrent ? Color.white.opacity(0.18) : Color.secondary.opacity(0.12))
                        )
                }
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 7)
            .contentShape(Rectangle())
            .background(
                RoundedRectangle(cornerRadius: 6)
                    .fill(isCurrent ? Color.accentColor : Color.clear)
            )
        }
        .buttonStyle(.plain)
        .help(L10n.t("engine.\(service.id)"))
    }

    private var serviceDetail: some View {
        let service = TranslationEngineDescriptor.descriptor(for: app.engineID) ?? TranslationEngineDescriptor.all[0]

        return Group {
            switch service.configuration {
            case .none:
                serviceEmptyState(service)
            case .apiKey:
                llmServicePanel(service)
            }
        }
    }

    private func serviceEmptyState(_ service: TranslationEngineDescriptor) -> some View {
        VStack(spacing: 12) {
            Image(systemName: service.systemImage)
                .font(.system(size: 32, weight: .medium))
                .foregroundStyle(.secondary)
            Text(String(format: L10n.t("settings.service.noConfiguration"), L10n.t("engine.\(service.id)")))
                .font(.callout.weight(.semibold))
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private func llmServicePanel(_ service: TranslationEngineDescriptor) -> some View {
        VStack(alignment: .leading, spacing: 18) {
            HStack(spacing: 10) {
                Image(systemName: service.systemImage)
                    .font(.title3)
                    .foregroundStyle(.tint)
                Text(L10n.t("engine.\(service.id)"))
                    .font(.headline)
            }

            Form {
                llmFields
            }
            .formStyle(.grouped)
            .scrollDisabled(true)

            Spacer(minLength: 0)
        }
        .padding(28)
    }

    private var llmFields: some View {
        Group {
            TextField(L10n.t("settings.llm.baseURL"), text: $app.llmBaseURL, prompt: Text(verbatim: "https://api.example.com/v1"))
            TextField(L10n.t("settings.llm.model"), text: $app.llmModel)
            SecureField(L10n.t("settings.llm.apiKey"), text: $llmAPIKey)
                .onChange(of: llmAPIKey) { _, newValue in
                    persistSecret(newValue, key: AppState.keychainLLMAPIKey)
                }
            testConnectionRow {
                let engine = OpenAICompatEngine(
                    config: LLMConfig(baseURL: app.llmBaseURL, model: app.llmModel),
                    apiKey: llmAPIKey
                )
                try await engine.testConnection()
            }
        }
    }

    private func testConnectionRow(_ test: @escaping () async throws -> Void) -> some View {
        HStack {
            Button(L10n.t("settings.testConnection")) {
                testState = .testing
                Task {
                    do {
                        try await test()
                        testState = .success
                    } catch let error as PDFLabError {
                        testState = .failure(L10n.message(for: error))
                    } catch {
                        testState = .failure(error.localizedDescription)
                    }
                }
            }
            .disabled(testState == .testing)
            .buttonStyle(HoverButtonStyle())

            switch testState {
            case .idle:
                EmptyView()
            case .testing:
                ProgressView()
                    .controlSize(.small)
                Text(L10n.t("settings.testConnection.testing"))
                    .foregroundStyle(.secondary)
            case .success:
                Label(L10n.t("settings.testConnection.success"), systemImage: "checkmark.circle.fill")
                    .foregroundStyle(.green)
            case .failure(let detail):
                Label("\(L10n.t("settings.testConnection.failure")): \(detail)", systemImage: "xmark.circle.fill")
                    .foregroundStyle(.red)
                    .lineLimit(2)
            }
        }
        .font(.callout)
    }

    // MARK: - 数据管理

    private var dataSection: some View {
        Section(L10n.t("settings.data")) {
            Button(L10n.t("history.clear"), role: .destructive) {
                app.clearHistory()
            }
            .buttonStyle(HoverButtonStyle(variant: .danger))
        }
    }

    // MARK: - Keychain

    private func loadSecrets() {
        llmAPIKey = KeychainStore.load(key: AppState.keychainLLMAPIKey) ?? ""
    }

    private func persistSecret(_ value: String, key: String) {
        if value.isEmpty {
            KeychainStore.delete(key: key)
        } else {
            try? KeychainStore.save(key: key, value: value)
        }
    }
}
