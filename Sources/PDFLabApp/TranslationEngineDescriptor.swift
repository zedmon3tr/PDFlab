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

    static let defaultID = "youdao"

    static let all: [TranslationEngineDescriptor] = [
        .init(
            id: "apple",
            systemImage: "apple.logo",
            configuration: .none,
            isCloud: false,
            isUnofficial: false
        ),
        .init(
            id: "llm",
            systemImage: "sparkles",
            configuration: .apiKey,
            isCloud: true,
            isUnofficial: false
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
            isUnofficial: true
        ),
    ]

    static func descriptor(for id: String) -> TranslationEngineDescriptor? {
        all.first { $0.id == id }
    }

    func enabledBadge(isCurrent: Bool) -> String? {
        isCurrent ? L10n.t("settings.service.enabled") : nil
    }
}
