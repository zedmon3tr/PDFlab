import SwiftUI
import AppKit
import PDFLabCore

/// 全局应用状态:持久化偏好(@AppStorage)+ 引擎工厂。
/// 秘密凭据(LLM API Key、有道 appKey/appSecret)只存 Keychain,不进 UserDefaults。
@MainActor
final class AppState: ObservableObject {
    // Keychain 键名(service 固定为 "com.pdflab.app",见 KeychainStore)
    static let keychainLLMAPIKey = "llm.apiKey"

    /// 引擎 ID 全集(设置面板下拉顺序)。
    nonisolated static let engineIDs = ["apple", "llm", "google", "deepl", "youdao"]
    /// 会把文档内容发往云端的引擎(首次选中时需要隐私确认)。
    nonisolated static let cloudEngineIDs: Set<String> = ["llm", "google", "deepl", "youdao"]
    /// 非官方接口引擎(设置面板显示不稳定 badge)。
    nonisolated static let unofficialEngineIDs: Set<String> = ["google", "deepl", "youdao"]

    // @AppStorage 在 ObservableObject 内不会自动触发刷新,willSet 手动补发。
    @AppStorage("appearance") var appearance: String = "system" {
        willSet { objectWillChange.send() }
    }
    @AppStorage("uiLanguage") var uiLanguage: String = "system" {
        willSet { objectWillChange.send() }
    }
    // 默认引擎:有道免 Key 网页接口(用户 2026-07-04 指定)。
    @AppStorage("engineID") var engineID: String = "youdao" {
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

    /// 当前 UI 是否为中文(供视图做少量布局分支;文案取值走 L10n)。
    var uiChinese: Bool { L10n.isChinese }

    /// 按当前 engineID 构造翻译引擎。
    /// - apple 注入 `AppleTranslationHost.shared`(macOS 15 的 .translationTask 宿主);
    /// - llm 从 Keychain 取凭据,缺失时以空字符串构造(调用时由引擎报错);
    /// - google/deepl/youdao 为免 Key 非官方引擎,零配置。
    func makeEngine() -> TranslationEngine {
        switch engineID {
        case "llm":
            return OpenAICompatEngine(
                config: LLMConfig(baseURL: llmBaseURL, model: llmModel),
                apiKey: KeychainStore.load(key: Self.keychainLLMAPIKey) ?? ""
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
