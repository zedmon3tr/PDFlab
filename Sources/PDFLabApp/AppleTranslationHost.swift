import Foundation
import SwiftUI
import Translation
import PDFLabCore

/// macOS 15 的 Apple 本地翻译宿主:`.translationTask` 只能由 SwiftUI 视图承载,
/// 故用一个常驻的 0×0 隐藏视图挂载,`AppleLocalEngine` 的 legacyRunner 委托到这里。
///
/// ⚠️ 关键约束(踩过的坑):`.translationTask(config)` 只在 **config 值变化** 时重跑。
/// 若每个翻译批次都新建一个"源/目标语言相同"的 Configuration,第二个 config 与第一个
/// 相等(中间的 nil 会被 SwiftUI 渲染合并掉),`.translationTask` 不会再触发 →
/// 第 2 批起永久挂起(表现为"进度条卡在翻译阶段")。
/// 因此这里对同一翻译方向 **只建一次 session**:首批设定 config 拿到 session 后,
/// 后续同方向批次全部经 `AsyncStream` 喂给这个常驻 session,不再改动 config;
/// 仅当翻译方向切换(语言对不同 → config 必然不相等)时才重建 session。
@MainActor
public final class AppleTranslationHost: ObservableObject, AppleSessionRunner, @unchecked Sendable {
    public static let shared = AppleTranslationHost()

    @Published public private(set) var pendingConfig: TranslationSession.Configuration?

    /// 流中传递的轻量请求(仅 id + 文本);continuation 存 `continuations` 字典,
    /// 以便取消时按 id 精确兑现且保证只兑现一次。
    private struct QueuedRequest {
        let id: UUID
        let texts: [String]
    }

    private var continuations: [UUID: CheckedContinuation<[String], any Error>] = [:]
    private var streamContinuation: AsyncStream<QueuedRequest>.Continuation?
    private var stream: AsyncStream<QueuedRequest>?
    private var currentDirection: TranslationDirection?

    private init() {}

    public var view: some View {
        Mount(host: self)
    }

    nonisolated public func run(texts: [String], direction: TranslationDirection) async throws -> [String] {
        guard !texts.isEmpty else { return [] }
        let id = UUID()

        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                Task { @MainActor in
                    self.enqueue(id: id, texts: texts, direction: direction, continuation: continuation)
                }
            }
        } onCancel: {
            Task { @MainActor in
                self.resolve(id: id, throwing: PDFLabError.cancelled)
            }
        }
    }

    private func enqueue(
        id: UUID,
        texts: [String],
        direction: TranslationDirection,
        continuation: CheckedContinuation<[String], any Error>
    ) {
        continuations[id] = continuation
        let request = QueuedRequest(id: id, texts: texts)

        if pendingConfig == nil || currentDirection != direction {
            // 新方向(或首次):重建 stream 并触发 `.translationTask` 建立新 session。
            streamContinuation?.finish()
            currentDirection = direction
            let newStream = AsyncStream<QueuedRequest> { continuation in
                self.streamContinuation = continuation
            }
            stream = newStream
            streamContinuation?.yield(request)
            pendingConfig = TranslationSession.Configuration(
                source: AppleLocalEngine.sourceLanguage(for: direction),
                target: AppleLocalEngine.targetLanguage(for: direction)
            )
        } else {
            // 同方向:复用常驻 session,直接喂流(不动 config,避免 `.translationTask` 不重跑的坑)。
            streamContinuation?.yield(request)
        }
    }

    /// 兑现某个请求的 continuation(成功);字典中已无该 id 说明已被取消/兑现,忽略。
    private func resolve(id: UUID, returning results: [String]) {
        guard let continuation = continuations.removeValue(forKey: id) else { return }
        continuation.resume(returning: results)
    }

    /// 兑现某个请求的 continuation(失败/取消);幂等,保证只 resume 一次。
    private func resolve(id: UUID, throwing error: Error) {
        guard let continuation = continuations.removeValue(forKey: id) else { return }
        continuation.resume(throwing: error)
    }

    /// `.translationTask` 拿到 session 后进入此循环,持续消费同方向的批次直到流结束
    /// (方向切换时 `enqueue` 会 finish 旧流,循环自然退出)。
    fileprivate func serve(with session: TranslationSession) async {
        guard let stream else { return }
        for await request in stream {
            // 已被取消的请求 continuation 已移除,跳过。
            guard continuations[request.id] != nil else { continue }
            do {
                let results = try await translate(request.texts, with: session)
                resolve(id: request.id, returning: results)
            } catch {
                resolve(id: request.id, throwing: mapAppleTranslationError(error))
            }
        }
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
                    await host.serve(with: session)
                }
        }
    }
}
