import SwiftUI
import AppKit
import PDFLabCore

/// 引擎实例缓存:同一份"构建指纹"(设置 + 凭据)下复用同一引擎实例,而不是每次
/// 重新构造——这样引擎内部的 `RateLimiter`(actor,存活跨调用)才能真正跨调用限速,
/// 而不是每次都拿到一个 `lastFire = .distantPast` 的新实例。指纹变化(引擎切换、
/// 服务 URL/model/Key 改动)才重建。用锁保护,可安全地从任意隔离域调用。
private final class EngineCache: @unchecked Sendable {
    private let lock = NSLock()
    private var fingerprint: String?
    private var engine: TranslationEngine?

    func engine(matching newFingerprint: String, build: () -> TranslationEngine) -> TranslationEngine {
        lock.lock()
        defer { lock.unlock() }
        if let engine, fingerprint == newFingerprint {
            return engine
        }
        let built = build()
        fingerprint = newFingerprint
        engine = built
        return built
    }
}

/// 全局应用状态:持久化偏好(@AppStorage)+ 引擎工厂。
/// 秘密凭据(官方服务 API Key、有道 appKey/appSecret)只存 Keychain,不进 UserDefaults。
@MainActor
final class AppState: ObservableObject {
    // Keychain 键名(service 固定为 "com.pdflab.app",见 KeychainStore)
    nonisolated static let keychainOpenAIAPIKey = "openai.apiKey"
    nonisolated static let keychainClaudeAPIKey = "claude.apiKey"
    nonisolated static let keychainLLMAPIKey = "llm.apiKey" // one-time migration source; deleted after successful copy
    nonisolated static let keychainDeepSeekAPIKey = "deepseek.apiKey"

    /// UserDefaults 键名:同时供下方 @AppStorage 声明与 `nonisolated` 的
    /// `makeEngineFromDefaults()` 重读逻辑使用,避免字符串字面量
    /// 在两处各写一份、悄悄漂移(如改了 @AppStorage 的 key 却忘了改 nonisolated 那边)。
    enum StorageKey {
        static let engineID = "engineID"
        static let llmBaseURL = "llmBaseURL"
        static let llmModel = "llmModel"
        static let openAIBaseURL = "openAIBaseURL"
        static let openAIModel = "openAIModel"
        static let claudeBaseURL = "claudeBaseURL"
        static let claudeModel = "claudeModel"
        static let deepSeekBaseURL = "deepSeekBaseURL"
        static let deepSeekModel = "deepSeekModel"
        static let legacyLLMMigrationCompletedV1 = "legacyLLMMigrationCompleted.v1" // old marker; intentionally ignored
        static let legacyLLMMigrationCompleted = "legacyLLMMigrationCompleted.v2"
    }

    /// 引擎 ID 全集(设置面板下拉顺序),由 `TranslationEngineDescriptor` 单点派生。
    nonisolated static let engineIDs = TranslationEngineDescriptor.all.map(\.id)
    /// 会把文档内容发往云端的引擎(首次选中时需要隐私确认)。
    nonisolated static let cloudEngineIDs = Set(TranslationEngineDescriptor.all.filter { $0.isCloud }.map(\.id))
    /// 非官方接口引擎(设置面板显示不稳定 badge)。
    nonisolated static let unofficialEngineIDs = Set(TranslationEngineDescriptor.all.filter { $0.isUnofficial }.map(\.id))

    // @AppStorage 在 ObservableObject 内不会自动触发刷新,willSet 手动补发。
    @AppStorage("appearance") var appearance: String = "system" {
        willSet { objectWillChange.send() }
    }
    @AppStorage("uiLanguage") var uiLanguage: String = "system" {
        willSet { objectWillChange.send() }
    }
    // 默认引擎:Google 免 Key网页接口。有道仅保留为用户显式选择的实验性短文本选项。
    @AppStorage(StorageKey.engineID) var engineID: String = TranslationEngineDescriptor.defaultID {
        willSet { objectWillChange.send() }
    }
    @AppStorage(StorageKey.openAIBaseURL) var openAIBaseURL: String = OpenAIConfig.defaultBaseURL {
        willSet { objectWillChange.send() }
    }
    @AppStorage(StorageKey.openAIModel) var openAIModel: String = OpenAIConfig.defaultModel {
        willSet { objectWillChange.send() }
    }
    @AppStorage(StorageKey.claudeBaseURL) var claudeBaseURL: String = ClaudeConfig.defaultBaseURL {
        willSet { objectWillChange.send() }
    }
    @AppStorage(StorageKey.claudeModel) var claudeModel: String = ClaudeConfig.defaultModel {
        willSet { objectWillChange.send() }
    }
    @AppStorage(StorageKey.deepSeekBaseURL) var deepSeekBaseURL: String = DeepSeekConfig.defaultBaseURL {
        willSet { objectWillChange.send() }
    }
    @AppStorage(StorageKey.deepSeekModel) var deepSeekModel: String = DeepSeekConfig.defaultModel {
        willSet { objectWillChange.send() }
    }
    // 旧测试/迁移代码的兼容入口；新界面与工厂不再使用旧通用设置。
    var llmBaseURL: String { get { openAIBaseURL } set { openAIBaseURL = newValue } }
    var llmModel: String { get { openAIModel } set { openAIModel = newValue } }
    /// 是否已确认过"云端翻译"隐私提示(只提示一次)。
    @AppStorage("cloudNoticeAcknowledged") var cloudNoticeAcknowledged: Bool = false {
        willSet { objectWillChange.send() }
    }

    let history = HistoryStore()

    /// 历史变更计数:清空/外部改动后自增,供主界面观察并重载缓存列表
    /// (设置面板是独立窗口,清空后主窗口不会重新触发 .onAppear)。
    @Published private(set) var historyRevision = 0

    /// 设置面板当前 Tab("general"/"services"/"about");启动更新 alert 经它把设置定位到关于页。
    @Published var settingsTab: String = "general"

    /// 设置 sheet 呈现状态(挂在主窗口,替代已弃用的 `Settings` 独立窗口场景):
    /// 齿轮按钮与 ⌘, 菜单命令共用。
    @Published var settingsPresented = false

    /// 翻译任务面板是否正占用主窗口 sheet 位(由 MainView 同步)。
    /// 占用期间忽略打开设置的请求,避免同层两个 sheet 争抢导致
    /// `settingsPresented` 卡在 true(之后齿轮按钮点了没反应)。
    @Published var translateSheetActive = false

    init() {
        migrateLegacyLLM()
        normalizeProviderSettings()
        normalizeEngineSelection()
    }

    private func migrateLegacyLLM() {
        let defaults = UserDefaults.standard
        guard !defaults.bool(forKey: StorageKey.legacyLLMMigrationCompleted) else { return }
        if defaults.string(forKey: StorageKey.engineID) == "llm" { engineID = "openai" }
        if defaults.object(forKey: StorageKey.openAIBaseURL) == nil,
           let old = defaults.string(forKey: StorageKey.llmBaseURL),
           let normalized = try? ProviderBaseURL.normalize(old) { openAIBaseURL = normalized }
        if defaults.object(forKey: StorageKey.openAIModel) == nil,
           let old = defaults.string(forKey: StorageKey.llmModel), OpenAIConfig.models.contains(old) { openAIModel = old }
        let completed = LegacyOpenAIKeyMigration.run(
            copyIfMissing: !defaults.bool(forKey: StorageKey.legacyLLMMigrationCompletedV1),
            newValue: { try KeychainStore.lookup(key: Self.keychainOpenAIAPIKey).value },
            legacyValue: { try KeychainStore.lookup(key: Self.keychainLLMAPIKey).value },
            saveNew: { try KeychainStore.save(key: Self.keychainOpenAIAPIKey, value: $0) },
            deleteLegacy: { try KeychainStore.delete(key: Self.keychainLLMAPIKey) }
        )
        if completed { defaults.set(true, forKey: StorageKey.legacyLLMMigrationCompleted) }
    }

    func normalizeProviderSettings() {
        openAIBaseURL = (try? ProviderBaseURL.normalize(openAIBaseURL)) ?? OpenAIConfig.defaultBaseURL
        claudeBaseURL = (try? ProviderBaseURL.normalize(claudeBaseURL)) ?? ClaudeConfig.defaultBaseURL
        deepSeekBaseURL = (try? ProviderBaseURL.normalize(deepSeekBaseURL)) ?? DeepSeekConfig.defaultBaseURL
        if !OpenAIConfig.models.contains(openAIModel) { openAIModel = OpenAIConfig.defaultModel }
        if !ClaudeConfig.models.contains(claudeModel) { claudeModel = ClaudeConfig.defaultModel }
        if !DeepSeekConfig.models.contains(deepSeekModel) { deepSeekModel = DeepSeekConfig.defaultModel }
    }

    /// 打开设置 sheet 的守卫判定(纯函数,便于测试):
    /// 只有主窗口没有其他 sheet 且设置未打开时才呈现。
    nonisolated static func shouldPresentSettings(translateSheetActive: Bool, settingsPresented: Bool) -> Bool {
        !translateSheetActive && !settingsPresented
    }

    /// 齿轮按钮 / ⌘, 命令的统一入口:守卫通过才置 `settingsPresented`。
    func presentSettingsIfIdle() {
        guard Self.shouldPresentSettings(
            translateSheetActive: translateSheetActive,
            settingsPresented: settingsPresented
        ) else { return }
        settingsPresented = true
    }

    /// 清空历史并广播变更,让任何缓存历史列表的视图刷新。
    func clearHistory() {
        history.clear()
        historyRevision += 1
    }

    /// 当前 UI 是否为中文(供视图做少量布局分支;文案取值走 L10n)。
    var uiChinese: Bool { L10n.isChinese }

    /// UI 与工厂共享同一套“当前系统可用”解析规则。
    var resolvedEngineID: String {
        TranslationEngineDescriptor.resolvedEngineID(
            engineID,
            availableIDs: TranslationEngineDescriptor.currentAvailableIDs
        )
    }

    /// 设置界面出现时修正遗留的未知值或当前系统不可用值，避免列表、详情与工厂分裂。
    func normalizeEngineSelection() {
        // 只修正未知值；合法但当前系统不可用的选择只在运行时回退，保留偏好供系统升级后恢复。
        if TranslationEngineDescriptor.descriptor(for: engineID) == nil {
            engineID = TranslationEngineDescriptor.defaultID
        }
    }

    /// 按当前 engineID 构造翻译引擎。
    /// - apple 注入 `AppleTranslationHost.shared`(macOS 15 的 .translationTask 宿主);
    /// - OpenAI/Claude/DeepSeek 从各自 Keychain 键取凭据,缺失时由引擎明确报错;
    /// - google/deepl/youdao 为免 Key 非官方引擎,零配置。
    func makeEngine() -> TranslationEngine {
        Self.makeEngineFromDefaults()
    }

    /// 引擎实例缓存,见 `EngineCache`:跨调用复用,使内部 `RateLimiter` 真正生效。
    /// `EngineCache` 自带锁、标记 `@unchecked Sendable`,可从任意隔离域访问。
    private nonisolated static let engineCache = EngineCache()

    /// 与 `makeEngine()` 同逻辑的 nonisolated 工厂:直接读 UserDefaults(线程安全,
    /// 与 @AppStorage 同一存储、同一默认值),可从任意隔离域调用。
    ///
    /// 只在"构建指纹"(当前服务设置 + 对应 Key,后者可能在 URL/model 不变时单独轮换)
    /// 与上次不同时才真正构造新引擎;否则复用 `engineCache` 里的实例——同一引擎实例
    /// 意味着同一个内部 `RateLimiter`,跨调用真正限速,而不是每次都得到一个
    /// `lastFire = .distantPast` 的新限速器。
    nonisolated static func makeEngineFromDefaults() -> TranslationEngine {
        let defaults = UserDefaults.standard
        let engineID = TranslationEngineDescriptor.resolvedEngineID(
            defaults.string(forKey: StorageKey.engineID),
            availableIDs: TranslationEngineDescriptor.currentAvailableIDs
        )
        let openAIBaseURL = defaults.string(forKey: StorageKey.openAIBaseURL) ?? OpenAIConfig.defaultBaseURL
        let openAIModel = defaults.string(forKey: StorageKey.openAIModel) ?? OpenAIConfig.defaultModel
        let claudeBaseURL = defaults.string(forKey: StorageKey.claudeBaseURL) ?? ClaudeConfig.defaultBaseURL
        let claudeModel = defaults.string(forKey: StorageKey.claudeModel) ?? ClaudeConfig.defaultModel
        let deepSeekBaseURL = defaults.string(forKey: StorageKey.deepSeekBaseURL) ?? DeepSeekConfig.defaultBaseURL
        let deepSeekModel = defaults.string(forKey: StorageKey.deepSeekModel) ?? DeepSeekConfig.defaultModel
        // 仅需凭据的官方引擎读取各自 Keychain 键；免 Key 引擎不访问 Keychain。
        let apiKey: String
        switch engineID {
        case "openai": apiKey = KeychainStore.load(key: keychainOpenAIAPIKey) ?? ""
        case "claude": apiKey = KeychainStore.load(key: keychainClaudeAPIKey) ?? ""
        case "deepseek": apiKey = KeychainStore.load(key: keychainDeepSeekAPIKey) ?? ""
        default: apiKey = ""
        }
        let providerConfiguration: String
        switch engineID {
        case "openai": providerConfiguration = "\(openAIBaseURL)\u{0}\(openAIModel)"
        case "claude": providerConfiguration = "\(claudeBaseURL)\u{0}\(claudeModel)"
        case "deepseek": providerConfiguration = "\(deepSeekBaseURL)\u{0}\(deepSeekModel)"
        default: providerConfiguration = ""
        }
        let buildFingerprint = "\(engineID)\u{0}\(providerConfiguration)\u{0}\(apiKey)"

        return engineCache.engine(matching: buildFingerprint) {
            switch engineID {
            case "openai":
                return OpenAIEngine(
                    config: OpenAIConfig(baseURL: openAIBaseURL, model: openAIModel),
                    apiKey: apiKey
                )
            case "claude":
                return ClaudeEngine(config: ClaudeConfig(baseURL: claudeBaseURL, model: claudeModel), apiKey: apiKey)
            case "deepseek":
                return DeepSeekEngine(config: DeepSeekConfig(baseURL: deepSeekBaseURL, model: deepSeekModel), apiKey: apiKey)
            case "google":
                return GoogleFreeEngine()
            case "deepl":
                return DeepLXEngine()
            case "youdao":
                return YoudaoWebEngine()
            case "apple":
                if #available(macOS 15.0, *) {
                    return AppleLocalEngine(legacyRunner: AppleTranslationHost.shared)
                }
                return GoogleFreeEngine()
            default:
                return GoogleFreeEngine()
            }
        }
    }

    /// 应用外观设置到 NSApp(即时生效)。
    func applyAppearance() {
        switch appearance {
        case "light": NSApp.appearance = NSAppearance(named: .aqua)
        case "dark": NSApp.appearance = NSAppearance(named: .darkAqua)
        default: NSApp.appearance = nil
        }
    }
}

enum LegacyOpenAIKeyMigration {
    /// Copy-before-delete migration. A failed save or legacy deletion leaves the marker incomplete,
    /// so the next launch retries safely. Existing new credentials are never overwritten.
    static func run(copyIfMissing: Bool = true,
                    newValue: () throws -> String?, legacyValue: () throws -> String?,
                    saveNew: (String) throws -> Void, deleteLegacy: () throws -> Void) -> Bool {
        let legacy: String?
        do { legacy = try legacyValue() } catch { return false }
        guard let legacy, !legacy.isEmpty else { return true }
        if copyIfMissing {
            let current: String?
            do { current = try newValue() } catch { return false }
            if current?.isEmpty != false {
                do { try saveNew(legacy) } catch { return false }
            }
        }
        do { try deleteLegacy() } catch { return false }
        return true
    }
}

private extension KeychainStore.LookupResult {
    var value: String? {
        switch self { case .found(let value): return value; case .missing: return nil }
    }
}
