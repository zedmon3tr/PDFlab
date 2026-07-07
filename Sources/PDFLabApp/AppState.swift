import SwiftUI
import AppKit
import PDFLabCore

/// 全局应用状态:持久化偏好(@AppStorage)+ 引擎工厂。
/// 秘密凭据(LLM API Key、有道 appKey/appSecret)只存 Keychain,不进 UserDefaults。
@MainActor
final class AppState: ObservableObject {
    // Keychain 键名(service 固定为 "com.pdflab.app",见 KeychainStore)
    nonisolated static let keychainLLMAPIKey = "llm.apiKey"

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
    @AppStorage("engineID") var engineID: String = TranslationEngineDescriptor.defaultID {
        willSet { objectWillChange.send() }
    }
    @AppStorage("llmBaseURL") var llmBaseURL: String = "" {
        willSet { objectWillChange.send() }
    }
    @AppStorage("llmModel") var llmModel: String = "" {
        willSet { objectWillChange.send() }
    }
    /// 是否已确认过"云端翻译"隐私提示(只提示一次)。
    @AppStorage("cloudNoticeAcknowledged") var cloudNoticeAcknowledged: Bool = false {
        willSet { objectWillChange.send() }
    }

    let history = HistoryStore()

    /// 查看器即时翻译共用服务(划选气泡等消费):LRU 缓存 + 并发合并;
    /// engineProvider 每次调用都按当前设置重建引擎(切换引擎即时生效)。
    let viewerTranslation = ViewerTranslationService(engineProvider: { AppState.makeEngineFromDefaults() })

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

    /// 与 `makeEngine()` 同逻辑的 nonisolated 工厂:直接读 UserDefaults(线程安全,
    /// 与 @AppStorage 同一存储、同一默认值),供 `ViewerTranslationService` 的
    /// @Sendable engineProvider 在任意隔离域调用。
    nonisolated static func makeEngineFromDefaults() -> TranslationEngine {
        let defaults = UserDefaults.standard
        switch defaults.string(forKey: "engineID") ?? TranslationEngineDescriptor.defaultID {
        case "llm":
            return OpenAICompatEngine(
                config: LLMConfig(
                    baseURL: defaults.string(forKey: "llmBaseURL") ?? "",
                    model: defaults.string(forKey: "llmModel") ?? ""
                ),
                apiKey: KeychainStore.load(key: keychainLLMAPIKey) ?? ""
            )
        case "google":
            return GoogleFreeEngine()
        case "deepl":
            return DeepLXEngine()
        case "youdao":
            return YoudaoWebEngine()
        default:
            return AppleLocalEngine(legacyRunner: AppleTranslationHost.shared)
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
