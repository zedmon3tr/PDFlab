import Foundation

struct TranslationEngineDescriptor: Identifiable, Equatable {
    enum Configuration: Equatable {
        case none
        case apiKey
    }

    var id: String
    var systemImage: String
    var configuration: Configuration
    var isCloud: Bool
    var isUnofficial: Bool
    var isExperimental: Bool = false
    var advisoryKey: String? = nil
    var minimumMacOSMajor: Int = 14

    static let defaultID = "google"

    static let all: [TranslationEngineDescriptor] = [
        .init(
            id: "apple",
            systemImage: "apple.logo",
            configuration: .none,
            isCloud: false,
            isUnofficial: false,
            minimumMacOSMajor: 15
        ),
        .init(
            id: "openai",
            systemImage: "sparkles",
            configuration: .apiKey,
            isCloud: true,
            isUnofficial: false
        ),
        .init(
            id: "claude",
            systemImage: "c.circle",
            configuration: .apiKey,
            isCloud: true,
            isUnofficial: false
        ),
        .init(
            id: "deepseek",
            systemImage: "brain.head.profile",
            configuration: .apiKey,
            isCloud: true,
            isUnofficial: false,
            advisoryKey: "engine.deepseek.billing"
        ),
        .init(
            id: "google",
            systemImage: "g.circle",
            configuration: .none,
            isCloud: true,
            isUnofficial: true
        ),
        .init(
            id: "deepl",
            systemImage: "d.circle",
            configuration: .none,
            isCloud: true,
            isUnofficial: true
        ),
        .init(
            id: "youdao",
            systemImage: "character.book.closed",
            configuration: .none,
            isCloud: true,
            isUnofficial: true,
            isExperimental: true,
            advisoryKey: "engine.youdao.experimental"
        ),
    ]

    static func descriptor(for id: String) -> TranslationEngineDescriptor? {
        all.first { $0.id == id }
    }

    static func available(macOSMajorVersion: Int) -> [TranslationEngineDescriptor] {
        all.filter { macOSMajorVersion >= $0.minimumMacOSMajor }
    }

    static var availableOnCurrentOS: [TranslationEngineDescriptor] {
        available(macOSMajorVersion: ProcessInfo.processInfo.operatingSystemVersion.majorVersion)
    }

    static var currentAvailableIDs: Set<String> { Set(availableOnCurrentOS.map(\.id)) }

    /// 将持久设置解析为当前系统真正可用的引擎。缺失、未知或当前 OS 不支持时
    /// 统一回到 Google；合法且可用的显式选择保持原样。
    static func resolvedEngineID(_ storedID: String?, availableIDs: Set<String>) -> String {
        guard let storedID, availableIDs.contains(storedID), descriptor(for: storedID) != nil else {
            return defaultID
        }
        return storedID
    }

    var statusBadgeKeys: [String] {
        var keys: [String] = []
        if isUnofficial { keys.append("engine.unofficialCompactBadge") }
        if isExperimental { keys.append("engine.experimentalBadge") }
        return keys
    }

}
