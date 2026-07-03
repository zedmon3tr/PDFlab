import Foundation
import Translation

/// macOS 15 path: the app layer owns `.translationTask` and runs the session.
public protocol AppleSessionRunner: Sendable {
    func run(texts: [String], direction: TranslationDirection) async throws -> [String]
}

public struct AppleLocalEngine: TranslationEngine {
    public let id = "apple"
    public let isUnofficial = false
    public let perRequestCharLimit = 6000

    private let legacyRunner: AppleSessionRunner?

    /// `legacyRunner` is used on macOS 15-25. macOS 26+ uses `TranslationSession`
    /// directly with installed language packs.
    public init(legacyRunner: AppleSessionRunner?) {
        self.legacyRunner = legacyRunner
    }

    public func translate(_ texts: [String], direction: TranslationDirection) async throws -> [String] {
        guard !texts.isEmpty else { return [] }

        if #available(macOS 26, *) {
            return try await translateWithInstalledSession(texts, direction: direction)
        }

        guard let legacyRunner else {
            throw PDFLabError.engineUnavailable(engineID: id)
        }

        do {
            return try await legacyRunner.run(texts: texts, direction: direction)
        } catch {
            throw mapAppleTranslationError(error)
        }
    }

    @available(macOS 26, *)
    private func translateWithInstalledSession(_ texts: [String], direction: TranslationDirection) async throws -> [String] {
        let session = TranslationSession(
            installedSource: Self.sourceLanguage(for: direction),
            target: Self.targetLanguage(for: direction)
        )
        let requests = texts.enumerated().map { index, text in
            TranslationSession.Request(sourceText: text, clientIdentifier: String(index))
        }

        var results = Array<String?>(repeating: nil, count: texts.count)
        do {
            for try await response in session.translate(batch: requests) {
                guard let identifier = response.clientIdentifier,
                      let index = Int(identifier),
                      results.indices.contains(index) else {
                    throw PDFLabError.engineUnavailable(engineID: id)
                }
                results[index] = response.targetText
            }
        } catch {
            throw mapAppleTranslationError(error)
        }

        return try results.map { value in
            guard let value else {
                throw PDFLabError.engineUnavailable(engineID: id)
            }
            return value
        }
    }

    public static func sourceLanguage(for direction: TranslationDirection) -> Locale.Language {
        switch direction {
        case .enToZh: Locale.Language(identifier: "en")
        case .zhToEn: Locale.Language(identifier: "zh-Hans")
        }
    }

    public static func targetLanguage(for direction: TranslationDirection) -> Locale.Language {
        switch direction {
        case .enToZh: Locale.Language(identifier: "zh-Hans")
        case .zhToEn: Locale.Language(identifier: "en")
        }
    }
}

public func mapAppleTranslationError(_ error: Error) -> Error {
    if let pdfLabError = error as? PDFLabError {
        return pdfLabError
    }
    if #available(macOS 26, *), TranslationError.notInstalled ~= error {
        return PDFLabError.languagePackMissing
    }
    return error
}
