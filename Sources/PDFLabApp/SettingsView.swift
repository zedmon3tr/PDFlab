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

    // 秘密凭据只走 Keychain;本地 @State 仅作输入缓冲。
    @State private var llmAPIKey: String = ""

    @State private var testState: TestState = .idle
    @State private var pendingCloudEngineID: String?

    var body: some View {
        TabView {
            generalTab
                .tabItem {
                    Label(L10n.t("settings.tab.general"), systemImage: "gearshape")
                }
            servicesTab
                .tabItem {
                    Label(L10n.t("settings.tab.services"), systemImage: "globe")
                }
            aboutTab
                .tabItem {
                    Label(L10n.t("settings.tab.about"), systemImage: "info.circle")
                }
        }
        .frame(width: 520)
        .frame(minHeight: 420)
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
        Form {
            engineSection
        }
        .formStyle(.grouped)
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
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
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

    private var engineSection: some View {
        Section(L10n.t("settings.engine")) {
            Picker(L10n.t("settings.engine"), selection: engineSelection) {
                ForEach(AppState.engineIDs, id: \.self) { id in
                    engineRowLabel(id).tag(id)
                }
            }

            if AppState.unofficialEngineIDs.contains(app.engineID) {
                Label(L10n.t("engine.unofficialBadge"), systemImage: "exclamationmark.triangle")
                    .font(.callout)
                    .foregroundStyle(.orange)
            }

            if app.engineID == "llm" {
                llmFields
            }
        }
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

    private func engineRowLabel(_ id: String) -> Text {
        let name = Text(L10n.t("engine.\(id)"))
        guard AppState.unofficialEngineIDs.contains(id) else { return name }
        return name + Text("  \(L10n.t("engine.unofficialBadge"))")
            .font(.caption)
            .foregroundColor(.secondary)
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
                app.history.clear()
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
