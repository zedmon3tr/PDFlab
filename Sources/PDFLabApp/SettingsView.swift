import AppKit
import SwiftUI
import PDFLabCore

/// 设置面板(主窗口 sheet,固定 760×560;`Settings` 独立窗口场景已弃用,
/// 见 product-spec-changelog.md 2026-07-10):外观 / 界面语言 / 翻译引擎 / 数据管理。
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
    @State private var openAIAPIKey: String = ""
    @State private var claudeAPIKey: String = ""
    @State private var deepSeekAPIKey: String = ""
    @State private var selectedServiceID: String = TranslationEngineDescriptor.defaultID

    @State private var testState: TestState = .idle
    @State private var testEpoch = ConnectionTestEpoch()
    @State private var testTask: Task<Void, Never>?
    @State private var rollingBackOpenAISecret = false
    @State private var rollingBackClaudeSecret = false
    @State private var rollingBackDeepSeekSecret = false
    @State private var pendingCloudEngineID: String?

    /// 手动检测发现新版时弹的富更新窗口(sheet-on-sheet,挂在设置 sheet 上,
    /// 避免与设置 sheet 同层争抢;与启动弹窗共用 UpdateSheetView)。
    @State private var settingsUpdateInfo: UpdateInfo?

    var body: some View {
        VStack(spacing: 0) {
            Picker("", selection: $app.settingsTab) {
                Text(L10n.t("settings.tab.general")).tag("general")
                Text(L10n.t("settings.tab.services")).tag("services")
                Text(L10n.t("settings.tab.about")).tag("about")
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .fixedSize()
            .padding(.top, 16)
            .padding(.bottom, 12)

            Divider()

            Group {
                switch app.settingsTab {
                case "services":
                    servicesTab
                case "about":
                    aboutTab
                default:
                    generalTab
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)

            Divider()

            HStack {
                Spacer()
                // Esc 经 cancelAction 关闭 sheet;隐私 alert 弹出期间按键由 alert 接管,不冲突。
                Button(L10n.t("common.done")) {
                    app.settingsPresented = false
                }
                .keyboardShortcut(.cancelAction)
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 12)
        }
        .frame(width: 760, height: 560)
        .onAppear {
            app.normalizeEngineSelection()
            app.normalizeProviderSettings()
            selectedServiceID = app.resolvedEngineID
            loadSecrets()
        }
        .onDisappear { invalidateConnectionTest() }
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
                    invalidateConnectionTest()
                }
                pendingCloudEngineID = nil
            }
            Button(L10n.t("common.cancel"), role: .cancel) {
                pendingCloudEngineID = nil
            }
        } message: {
            Text(L10n.t("privacy.cloudNotice"))
        }
        .sheet(isPresented: settingsUpdateSheetPresented) {
            if let info = settingsUpdateInfo {
                UpdateSheetView(
                    updater: updater,
                    info: info,
                    dismiss: { settingsUpdateInfo = nil }
                )
            }
        }
    }

    private var settingsUpdateSheetPresented: Binding<Bool> {
        Binding(
            get: { settingsUpdateInfo != nil },
            set: { if !$0 { settingsUpdateInfo = nil } }
        )
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
            aboutLogo
            Text(L10n.t("app.name"))
                .font(.title2.weight(.semibold))
            Text("\(L10n.t("about.version")) \(PDFLabCoreInfo.version)")
                .font(.callout)
                .foregroundStyle(.secondary)
            Text(L10n.t("about.blurb"))
                .font(.callout)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .padding(.horizontal, 32)
            updateSection
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    @ViewBuilder
    private var aboutLogo: some View {
        let icon = NSApp.applicationIconImage
        if let icon, AboutLogoPresentation.usesApplicationIcon(icon) {
            Image(nsImage: icon)
                .resizable()
                .scaledToFit()
                .frame(width: AboutLogoPresentation.iconSide, height: AboutLogoPresentation.iconSide)
                .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
                .accessibilityHidden(true)
        } else {
            Image(systemName: AboutLogoPresentation.fallbackSystemImage)
                .font(.system(size: 44, weight: .medium))
                .foregroundStyle(.tint)
        }
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
                    .padding(.horizontal, 32)
            case .failed(let message):
                checkUpdateButton
                Text(message)
                    .font(.callout)
                    .foregroundStyle(.red)
                    .multilineTextAlignment(.center)
                    .padding(.horizontal, 32)
            }

            Toggle(L10n.t("update.autoCheck"), isOn: $updater.autoCheckUpdates)
                .toggleStyle(.checkbox)
                .font(.callout)
        }
        .padding(.top, 8)
    }

    private var checkUpdateButton: some View {
        Button {
            Task {
                await updater.checkManually()
                // 手动检测发现新版(无视 skippedVersion,现状)→ 弹同一富更新窗口。
                if case .updateAvailable(let info) = updater.phase {
                    settingsUpdateInfo = info
                }
            }
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

    /// 关于页发现新版的内联展示:精简为一行版本 + 「查看更新」,
    /// Release Notes / 下载 / 跳过统一收进富更新窗口,不做两份重复 UI。
    private func updateAvailableView(_ info: UpdateInfo) -> some View {
        VStack(spacing: 8) {
            Text("\(L10n.t("update.available")) \(info.version)")
                .font(.callout.weight(.semibold))
            Button(L10n.t("update.details")) { settingsUpdateInfo = info }
                .buttonStyle(.borderedProminent)
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
                    ForEach(TranslationEngineDescriptor.availableOnCurrentOS) { service in
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
            get: { app.resolvedEngineID },
            set: { newValue in
                guard newValue != app.resolvedEngineID else { return }
                if AppState.cloudEngineIDs.contains(newValue), !app.cloudNoticeAcknowledged {
                    pendingCloudEngineID = newValue
                } else {
                    app.engineID = newValue
                    invalidateConnectionTest()
                }
            }
        )
    }

    private func serviceRow(_ service: TranslationEngineDescriptor) -> some View {
        let isCurrent = app.resolvedEngineID == service.id
        let isSelected = selectedServiceID == service.id

        return Button {
            selectedServiceID = service.id
            invalidateConnectionTest()
        } label: {
            HStack(spacing: 10) {
                Image(systemName: service.systemImage)
                    .font(.system(size: 15, weight: .medium))
                    .foregroundStyle(isSelected ? AnyShapeStyle(Color(nsColor: .alternateSelectedControlTextColor)) : AnyShapeStyle(.secondary))
                    .frame(width: 18)

                Text(L10n.t("engine.\(service.id)"))
                    .font(.callout.weight(.medium))
                    .lineLimit(1)
                .foregroundStyle(isSelected ? AnyShapeStyle(Color(nsColor: .alternateSelectedControlTextColor)) : AnyShapeStyle(.primary))

                Spacer(minLength: 8)

                if isCurrent {
                    Image(systemName: "checkmark.circle.fill")
                        .font(.caption)
                        .accessibilityLabel(L10n.t("settings.service.enabled"))
                }

                ForEach(service.statusBadgeKeys, id: \.self) { key in
                    Text(L10n.t(key))
                        .font(.caption2.weight(.semibold))
                        .padding(.horizontal, 6)
                        .padding(.vertical, 3)
                        .foregroundStyle(isSelected ? Color(nsColor: .alternateSelectedControlTextColor) : .secondary)
                        .background(Capsule().fill(isSelected ? Color.white.opacity(0.18) : Color.secondary.opacity(0.12)))
                }
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 6)
            .contentShape(Rectangle())
            .background(
                RoundedRectangle(cornerRadius: 6)
                    .fill(isSelected ? Color(nsColor: .selectedContentBackgroundColor) : Color.clear)
            )
        }
        .buttonStyle(.plain)
        .help(serviceHelp(service))
    }

    private var serviceDetail: some View {
        let service = TranslationEngineDescriptor.availableOnCurrentOS.first { $0.id == selectedServiceID }
            ?? TranslationEngineDescriptor.descriptor(for: TranslationEngineDescriptor.defaultID)
            ?? TranslationEngineDescriptor.all[0]

        return Group {
            switch service.id {
            case "openai":
                providerServicePanel(service, baseURL: $app.openAIBaseURL, model: $app.openAIModel,
                    models: OpenAIConfig.models, apiKey: $openAIAPIKey,
                    keychainKey: AppState.keychainOpenAIAPIKey, rollback: $rollingBackOpenAISecret) {
                        try await OpenAIEngine(config: OpenAIConfig(baseURL: app.openAIBaseURL, model: app.openAIModel), apiKey: openAIAPIKey).testConnection()
                    }
            case "claude":
                providerServicePanel(service, baseURL: $app.claudeBaseURL, model: $app.claudeModel,
                    models: ClaudeConfig.models, apiKey: $claudeAPIKey,
                    keychainKey: AppState.keychainClaudeAPIKey, rollback: $rollingBackClaudeSecret) {
                        try await ClaudeEngine(config: ClaudeConfig(baseURL: app.claudeBaseURL, model: app.claudeModel), apiKey: claudeAPIKey).testConnection()
                    }
            case "deepseek":
                providerServicePanel(service, baseURL: $app.deepSeekBaseURL, model: $app.deepSeekModel,
                    models: DeepSeekConfig.models, apiKey: $deepSeekAPIKey,
                    keychainKey: AppState.keychainDeepSeekAPIKey, rollback: $rollingBackDeepSeekSecret) {
                        try await DeepSeekEngine(config: DeepSeekConfig(baseURL: app.deepSeekBaseURL, model: app.deepSeekModel), apiKey: deepSeekAPIKey).testConnection()
                    }
            default:
                serviceEmptyState(service)
            }
        }
    }

    private func serviceEmptyState(_ service: TranslationEngineDescriptor) -> some View {
        VStack(spacing: 12) {
            Image(systemName: service.systemImage)
                .font(.system(size: 30, weight: .medium))
                .foregroundStyle(.secondary)
            Text(String(format: L10n.t("settings.service.noConfiguration"), L10n.t("engine.\(service.id)")))
                .font(.callout.weight(.semibold))
                .foregroundStyle(.secondary)
            if service.isUnofficial {
                Text(L10n.t("engine.unofficialBadge"))
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }
            if let advisoryKey = service.advisoryKey {
                Text(L10n.t(advisoryKey))
                    .font(.callout)
                    .foregroundStyle(.orange)
                    .multilineTextAlignment(.center)
            }
            enableButton(service)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private func serviceHelp(_ service: TranslationEngineDescriptor) -> String {
        var parts = [L10n.t("engine.\(service.id)")]
        if service.isUnofficial { parts.append(L10n.t("engine.unofficialBadge")) }
        if let advisoryKey = service.advisoryKey { parts.append(L10n.t(advisoryKey)) }
        return parts.joined(separator: " — ")
    }

    private func providerServicePanel(_ service: TranslationEngineDescriptor, baseURL: Binding<String>,
                                      model: Binding<String>, models: [String], apiKey: Binding<String>,
                                      keychainKey: String, rollback: Binding<Bool>,
                                      test: @escaping () async throws -> Void) -> some View {
        VStack(alignment: .leading, spacing: 18) {
            HStack(spacing: 10) {
                Image(systemName: service.systemImage)
                    .font(.title3)
                    .foregroundStyle(.tint)
                Text(L10n.t("engine.\(service.id)"))
                    .font(.headline)
            }

            Form {
                TextField(L10n.t("settings.provider.baseURL"), text: baseURL,
                          prompt: Text(L10n.t("settings.provider.baseURL.placeholder")))
                    .onChange(of: baseURL.wrappedValue) { _, _ in invalidateConnectionTest() }
                    .onSubmit {
                        if let normalized = try? ProviderBaseURL.normalize(baseURL.wrappedValue) {
                            baseURL.wrappedValue = normalized
                        } else {
                            testState = .failure(L10n.t("error.providerBaseURLInvalid"))
                        }
                    }
                SecureField(L10n.t("settings.provider.apiKey"), text: apiKey,
                            prompt: Text(L10n.t("settings.provider.apiKey.placeholder")))
                    .onChange(of: apiKey.wrappedValue) { _, value in
                        if rollback.wrappedValue { rollback.wrappedValue = false; return }
                        invalidateConnectionTest()
                        if !persistSecret(value, key: keychainKey) {
                            rollback.wrappedValue = true
                            apiKey.wrappedValue = KeychainStore.load(key: keychainKey) ?? ""
                        }
                    }
                Picker(L10n.t("settings.provider.model"), selection: model) {
                    ForEach(models, id: \.self) { Text($0).tag($0) }
                }
                .onChange(of: model.wrappedValue) { _, _ in invalidateConnectionTest() }
                testConnectionRow(test)
            }
            .formStyle(.grouped)
            .scrollDisabled(true)

            Spacer(minLength: 0)
            enableButton(service)
        }
        .padding(28)
    }

    private func enableButton(_ service: TranslationEngineDescriptor) -> some View {
        Button(app.resolvedEngineID == service.id ? L10n.t("settings.service.enabled") : L10n.t("settings.service.enable")) {
            engineSelection.wrappedValue = service.id
        }
        .buttonStyle(.borderedProminent)
        .disabled(app.resolvedEngineID == service.id)
        .accessibilityHint(app.resolvedEngineID == service.id ? "" : L10n.t("settings.service.enable.hint"))
    }

    private func testConnectionRow(_ test: @escaping () async throws -> Void) -> some View {
        HStack {
            Button(L10n.t("settings.testConnection")) {
                invalidateConnectionTest()
                testState = .testing
                let generation = testEpoch.value
                testTask = Task {
                    do {
                        try await test()
                        guard !Task.isCancelled, testEpoch.accepts(generation) else { return }
                        testState = .success
                    } catch let error as PDFLabError {
                        guard !Task.isCancelled, testEpoch.accepts(generation) else { return }
                        testState = .failure(L10n.message(for: error))
                    } catch {
                        guard !Task.isCancelled, testEpoch.accepts(generation) else { return }
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
        openAIAPIKey = KeychainStore.load(key: AppState.keychainOpenAIAPIKey) ?? ""
        claudeAPIKey = KeychainStore.load(key: AppState.keychainClaudeAPIKey) ?? ""
        deepSeekAPIKey = KeychainStore.load(key: AppState.keychainDeepSeekAPIKey) ?? ""
    }

    @discardableResult
    private func persistSecret(_ value: String, key: String) -> Bool {
        let saved = SecretPersistence.persist(value,
            save: { try KeychainStore.save(key: key, value: $0) },
            delete: { try KeychainStore.delete(key: key) })
        if !saved {
            testState = .failure(L10n.t("error.keychainSaveFailed"))
        }
        return saved
    }

    private func invalidateConnectionTest() {
        testEpoch.invalidate()
        testTask?.cancel()
        testTask = nil
        testState = .idle
    }
}

enum SecretPersistence {
    static func persist(_ value: String, save: (String) throws -> Void, delete: () throws -> Void) -> Bool {
        if value.isEmpty {
            do { try delete(); return true } catch { return false }
        }
        do { try save(value); return true } catch { return false }
    }
}

struct ConnectionTestEpoch: Equatable {
    private(set) var value = 0
    mutating func invalidate() { value += 1 }
    func accepts(_ candidate: Int) -> Bool { candidate == value }
}

enum AboutLogoPresentation {
    static let fallbackSystemImage = "doc.text.magnifyingglass"
    static let iconSide: CGFloat = 72

    static func usesApplicationIcon(_ image: NSImage?) -> Bool {
        guard let image else { return false }
        return image.size.width > 0 && image.size.height > 0
    }
}
