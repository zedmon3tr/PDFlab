import SwiftUI
import Translation
import _Translation_SwiftUI
import PDFLabCore

@MainActor
public final class AppleTranslationHost: ObservableObject, AppleSessionRunner, @unchecked Sendable {
    public static let shared = AppleTranslationHost()

    @Published public private(set) var pendingConfig: TranslationSession.Configuration?

    private var pendingRequest: PendingRequest?

    public init() {}

    public var view: some View {
        Mount(host: self)
    }

    nonisolated public func run(texts: [String], direction: TranslationDirection) async throws -> [String] {
        guard !texts.isEmpty else { return [] }

        return try await withCheckedThrowingContinuation { continuation in
            Task { @MainActor in
                self.enqueue(texts: texts, direction: direction, continuation: continuation)
            }
        }
    }

    private func enqueue(
        texts: [String],
        direction: TranslationDirection,
        continuation: CheckedContinuation<[String], any Error>
    ) {
        guard pendingRequest == nil else {
            continuation.resume(throwing: PDFLabError.engineUnavailable(engineID: "apple"))
            return
        }

        pendingRequest = PendingRequest(texts: texts, continuation: continuation)
        pendingConfig = TranslationSession.Configuration(
            source: AppleLocalEngine.sourceLanguage(for: direction),
            target: AppleLocalEngine.targetLanguage(for: direction)
        )
    }

    fileprivate func runPendingRequest(with session: TranslationSession) async {
        guard let request = pendingRequest else { return }

        do {
            let results = try await translate(request.texts, with: session)
            request.continuation.resume(returning: results)
        } catch {
            request.continuation.resume(throwing: mapAppleTranslationError(error))
        }

        pendingRequest = nil
        pendingConfig = nil
    }

    private func translate(_ texts: [String], with session: TranslationSession) async throws -> [String] {
        let batch = texts.enumerated().map { index, text in
            TranslationSession.Request(sourceText: text, clientIdentifier: String(index))
        }
        var results = Array<String?>(repeating: nil, count: texts.count)

        for try await response in session.translate(batch: batch) {
            guard let identifier = response.clientIdentifier,
                  let index = Int(identifier),
                  results.indices.contains(index) else {
                throw PDFLabError.engineUnavailable(engineID: "apple")
            }
            results[index] = response.targetText
        }

        return try results.map { value in
            guard let value else {
                throw PDFLabError.engineUnavailable(engineID: "apple")
            }
            return value
        }
    }

    public struct Mount: View {
        @ObservedObject private var host: AppleTranslationHost

        public init(host: AppleTranslationHost) {
            self.host = host
        }

        public var body: some View {
            Color.clear
                .frame(width: 0, height: 0)
                .translationTask(host.pendingConfig) { session in
                    await host.runPendingRequest(with: session)
                }
        }
    }

    private struct PendingRequest {
        let texts: [String]
        let continuation: CheckedContinuation<[String], any Error>
    }
}
