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
    @State private var youdaoAppKey: String = ""
    @State private var youdaoAppSecret: String = ""

    @State private var testState: TestState = .idle
    @State private var pendingCloudEngineID: String?

    var body: some View {
        Form {
            appearanceSection
            languageSection
            engineSection
            dataSection
        }
        .formStyle(.grouped)
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
            } else if app.engineID == "youdao" {
                youdaoFields
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

    private var youdaoFields: some View {
        Group {
            TextField(L10n.t("settings.youdao.appKey"), text: $youdaoAppKey)
                .onChange(of: youdaoAppKey) { _, newValue in
                    persistSecret(newValue, key: AppState.keychainYoudaoAppKey)
                }
            SecureField(L10n.t("settings.youdao.appSecret"), text: $youdaoAppSecret)
                .onChange(of: youdaoAppSecret) { _, newValue in
                    persistSecret(newValue, key: AppState.keychainYoudaoAppSecret)
                }
            testConnectionRow {
                let engine = YoudaoZhiyunEngine(appKey: youdaoAppKey, appSecret: youdaoAppSecret)
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
        }
    }

    // MARK: - Keychain

    private func loadSecrets() {
        llmAPIKey = KeychainStore.load(key: AppState.keychainLLMAPIKey) ?? ""
        youdaoAppKey = KeychainStore.load(key: AppState.keychainYoudaoAppKey) ?? ""
        youdaoAppSecret = KeychainStore.load(key: AppState.keychainYoudaoAppSecret) ?? ""
    }

    private func persistSecret(_ value: String, key: String) {
        if value.isEmpty {
            KeychainStore.delete(key: key)
        } else {
            try? KeychainStore.save(key: key, value: value)
        }
    }
}
