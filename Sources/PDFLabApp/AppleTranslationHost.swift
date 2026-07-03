import Foundation
import SwiftUI
import Translation
import PDFLabCore

@MainActor
public final class AppleTranslationHost: ObservableObject, AppleSessionRunner, @unchecked Sendable {
    public static let shared = AppleTranslationHost()

    @Published public private(set) var pendingConfig: TranslationSession.Configuration?

    private var pendingRequest: PendingRequest?

    private init() {}

    public var view: some View {
        Mount(host: self)
    }

    nonisolated public func run(texts: [String], direction: TranslationDirection) async throws -> [String] {
        guard !texts.isEmpty else { return [] }
        let id = UUID()
        let cancellation = CancellationFlag()

        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                Task { @MainActor in
                    self.enqueue(
                        id: id,
                        texts: texts,
                        direction: direction,
                        continuation: continuation,
                        cancellation: cancellation
                    )
                }
            }
        } onCancel: {
            cancellation.cancel()
            Task { @MainActor in
                self.cancelRequest(id: id)
            }
        }
    }

    private func enqueue(
        id: UUID,
        texts: [String],
        direction: TranslationDirection,
        continuation: CheckedContinuation<[String], any Error>,
        cancellation: CancellationFlag
    ) {
        guard !cancellation.isCancelled else {
            continuation.resume(throwing: PDFLabError.cancelled)
            return
        }
        guard pendingRequest == nil else {
            continuation.resume(throwing: PDFLabError.engineUnavailable(engineID: "apple"))
            return
        }

        pendingRequest = PendingRequest(id: id, state: .pending, texts: texts, continuation: continuation)
        pendingConfig = TranslationSession.Configuration(
            source: AppleLocalEngine.sourceLanguage(for: direction),
            target: AppleLocalEngine.targetLanguage(for: direction)
        )
    }

    fileprivate func runPendingRequest(with session: TranslationSession) async {
        guard let request = pendingRequest, request.state == .pending else { return }

        pendingRequest?.state = .inFlight
        let id = request.id
        let texts = request.texts

        do {
            let results = try await translate(texts, with: session)
            finishRequest(id: id, returning: results)
        } catch {
            finishRequest(id: id, throwing: mapAppleTranslationError(error))
        }
    }

    private func cancelRequest(id: UUID) {
        finishRequest(id: id, throwing: PDFLabError.cancelled)
    }

    private func finishRequest(id: UUID, returning results: [String]) {
        guard let request = pendingRequest, request.id == id else { return }
        pendingRequest = nil
        pendingConfig = nil
        request.continuation.resume(returning: results)
    }

    private func finishRequest(id: UUID, throwing error: Error) {
        guard let request = pendingRequest, request.id == id else { return }
        pendingRequest = nil
        pendingConfig = nil
        request.continuation.resume(throwing: error)
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
        let id: UUID
        var state: RequestState
        let texts: [String]
        let continuation: CheckedContinuation<[String], any Error>
    }

    private enum RequestState {
        case pending
        case inFlight
    }
}

private final class CancellationFlag: @unchecked Sendable {
    private let lock = NSLock()
    private var cancelled = false

    var isCancelled: Bool {
        lock.lock()
        defer { lock.unlock() }
        return cancelled
    }

    func cancel() {
        lock.lock()
        cancelled = true
        lock.unlock()
    }
}
