import SwiftUI
import AppKit
import PDFLabCore

/// 引擎实例缓存:同一份"构建指纹"(设置 + 凭据)下复用同一引擎实例,而不是每次
/// 重新构造——这样引擎内部的 `RateLimiter`(actor,存活跨调用)才能真正跨调用限速,
/// 而不是每次都拿到一个 `lastFire = .distantPast` 的新实例。指纹变化(引擎切换、
/// LLM baseURL/model/Key 改动)才重建。用锁保护,可安全地从任意隔离域调用。
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
/// 秘密凭据(LLM API Key、有道 appKey/appSecret)只存 Keychain,不进 UserDefaults。
@MainActor
final class AppState: ObservableObject {
    // Keychain 键名(service 固定为 "com.pdflab.app",见 KeychainStore)
    nonisolated static let keychainLLMAPIKey = "llm.apiKey"

    /// UserDefaults 键名:同时供下方 @AppStorage 声明与 `nonisolated` 的
    /// `makeEngineFromDefaults()` 重读逻辑使用,避免字符串字面量
    /// 在两处各写一份、悄悄漂移(如改了 @AppStorage 的 key 却忘了改 nonisolated 那边)。
    enum StorageKey {
        static let engineID = "engineID"
        static let llmBaseURL = "llmBaseURL"
        static let llmModel = "llmModel"
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
    // 默认引擎:有道免 Key 网页接口(用户 2026-07-04 指定)。
    @AppStorage(StorageKey.engineID) var engineID: String = TranslationEngineDescriptor.defaultID {
        willSet { objectWillChange.send() }
    }
    @AppStorage(StorageKey.llmBaseURL) var llmBaseURL: String = "" {
        willSet { objectWillChange.send() }
    }
    @AppStorage(StorageKey.llmModel) var llmModel: String = "" {
        willSet { objectWillChange.send() }
    }
    /// 是否已确认过"云端翻译"隐私提示(只提示一次)。
    @AppStorage("cloudNoticeAcknowledged") var cloudNoticeAcknowledged: Bool = false {
        willSet { objectWillChange.send() }
    }

    let history = HistoryStore()

    /// 历史变更计数:清空/外部改动后自增,供主界面观察并重载缓存列表
    /// (设置面板是独立窗口,清空后主窗口不会重新触发 .onAppear)。
    @Published private(set) var historyRevision = 0

    /// 设置窗口当前 Tab("general"/"services"/"about");启动更新 alert 经它把设置定位到关于页。
    @Published var settingsTab: String = "general"

    /// 清空历史并广播变更,让任何缓存历史列表的视图刷新。
    func clearHistory() {
        history.clear()
        historyRevision += 1
    }

    /// 当前 UI 是否为中文(供视图做少量布局分支;文案取值走 L10n)。
    var uiChinese: Bool { L10n.isChinese }

    /// 按当前 engineID 构造翻译引擎。
    /// - apple 注入 `AppleTranslationHost.shared`(macOS 15 的 .translationTask 宿主);
    /// - llm 从 Keychain 取凭据,缺失时以空字符串构造(调用时由引擎报错);
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
    /// 只在"构建指纹"(设置指纹 + LLM Key,后者可能在 baseURL/model 不变时单独轮换)
    /// 与上次不同时才真正构造新引擎;否则复用 `engineCache` 里的实例——同一引擎实例
    /// 意味着同一个内部 `RateLimiter`,跨调用真正限速,而不是每次都得到一个
    /// `lastFire = .distantPast` 的新限速器。
    nonisolated static func makeEngineFromDefaults() -> TranslationEngine {
        let defaults = UserDefaults.standard
        let engineID = defaults.string(forKey: StorageKey.engineID) ?? TranslationEngineDescriptor.defaultID
        let baseURL = defaults.string(forKey: StorageKey.llmBaseURL) ?? ""
        let model = defaults.string(forKey: StorageKey.llmModel) ?? ""
        // 只有 llm 引擎的凭据存 Keychain,其余引擎零配置;Keychain 读取只在这里
        // (构建路径)发生一次。
        let apiKey = engineID == "llm" ? (KeychainStore.load(key: keychainLLMAPIKey) ?? "") : ""
        let buildFingerprint = "\(engineID)\u{0}\(baseURL)\u{0}\(model)\u{0}\(apiKey)"

        return engineCache.engine(matching: buildFingerprint) {
            switch engineID {
            case "llm":
                return OpenAICompatEngine(
                    config: LLMConfig(baseURL: baseURL, model: model),
                    apiKey: apiKey
                )
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
                return YoudaoWebEngine()
            default:
                return YoudaoWebEngine()
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
