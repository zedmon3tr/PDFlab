import Foundation

public struct ClaudeConfig: Codable, Equatable, Sendable {
    public static let defaultBaseURL = "https://api.anthropic.com/v1"
    public static let models = ["claude-sonnet-5", "claude-haiku-4-5", "claude-opus-4-8", "claude-fable-5"]
    public static let defaultModel = "claude-sonnet-5"
    public var baseURL: String
    public var model: String
    public init(baseURL: String = defaultBaseURL, model: String = defaultModel) {
        self.baseURL = baseURL; self.model = Self.models.contains(model) ? model : Self.defaultModel
    }
}

public struct ClaudeEngine: TranslationEngine {
    public let id = "claude", isUnofficial = false, perRequestCharLimit = 8000
    private let config: ClaudeConfig; private let apiKey: String; private let client: HTTPClient
    private let limiter: RateLimiter; private let retryPolicy: TranslationRetryPolicy
#if DEBUG
    private let diagnostics: any TranslationDiagnosticSink
    public init(config: ClaudeConfig, apiKey: String, client: HTTPClient = URLSession.shared,
                limiter: RateLimiter = RateLimiter(minInterval: 0.2), retryPolicy: TranslationRetryPolicy = TranslationRetryPolicy(),
                diagnostics: any TranslationDiagnosticSink = TranslationDiagnostics.shared) {
        self.config = config; self.apiKey = apiKey; self.client = client; self.limiter = limiter; self.retryPolicy = retryPolicy; self.diagnostics = diagnostics
    }
#else
    public init(config: ClaudeConfig, apiKey: String, client: HTTPClient = URLSession.shared,
                limiter: RateLimiter = RateLimiter(minInterval: 0.2), retryPolicy: TranslationRetryPolicy = TranslationRetryPolicy()) {
        self.config = config; self.apiKey = apiKey; self.client = client; self.limiter = limiter; self.retryPolicy = retryPolicy
    }
#endif
    public func translate(_ texts: [String], direction: TranslationDirection) async throws -> [String] {
        var output: [String] = []; for text in texts { output.append(try await complete(text, direction: direction)) }; return output
    }
    public func testConnection() async throws { _ = try await complete("test", direction: .enToZh) }
    private func complete(_ text: String, direction: TranslationDirection) async throws -> String {
        let url = try ProviderBaseURL.endpoint(baseURL: config.baseURL, path: "/messages")
        var request = URLRequest(url: url); request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue(apiKey, forHTTPHeaderField: "x-api-key")
        request.setValue("2023-06-01", forHTTPHeaderField: "anthropic-version")
        let target = direction == .enToZh ? "Simplified Chinese" : "English"
        request.httpBody = try JSONSerialization.data(withJSONObject: ["model": config.model, "max_tokens": 8192, "stream": false,
            "system": "Translate into \(target), preserving structure and terminology. Output only the translation.",
            "messages": [["role": "user", "content": text]]])
        for attempt in 0...retryPolicy.maxRetries {
#if DEBUG
            let context = TranslationDiagnosticScope.current ?? .init(runID: UUID())
            let requestID = UUID(), started = Date()
            var recorded = false
            func log(_ status: Int?, _ category: String?) async {
                guard !recorded else { return }; recorded = true
                await diagnostics.record(.init(runID: context.runID, requestID: requestID, engine: id,
                    stage: "http", direction: direction, batch: context.batch, pageStart: context.pageStart,
                    pageEnd: context.pageEnd, characterCount: text.count,
                    durationMilliseconds: Int(Date().timeIntervalSince(started) * 1000), httpStatus: status,
                    retryCount: attempt, errorCategory: category))
            }
#endif
            do {
                try await limiter.waitTurn(); let (data, response) = try await client.data(for: request)
                guard let http = response as? HTTPURLResponse else {
#if DEBUG
                    await log(nil, "invalid-response")
#endif
                    throw PDFLabError.engineUnavailable(engineID: id)
                }
                switch http.statusCode {
                case 200..<300:
                    do { let value = try Self.parseResponse(data)
#if DEBUG
                        await log(http.statusCode, nil)
#endif
                        return value
                    } catch let error as PDFLabError {
#if DEBUG
                        await log(http.statusCode, Self.category(error))
#endif
                        throw error
                    }
                case 400, 422:
#if DEBUG
                    await log(http.statusCode, "invalid-request")
#endif
                    throw PDFLabError.engineInvalidRequest
                case 401, 403:
#if DEBUG
                    await log(http.statusCode, "invalid-key")
#endif
                    throw PDFLabError.engineInvalidKey
                case 429:
#if DEBUG
                    await log(http.statusCode, attempt < retryPolicy.maxRetries ? "rate-limited" : "rate-limited-exhausted")
#endif
                    if attempt < retryPolicy.maxRetries { try await retryPolicy.wait(beforeRetry: attempt); continue }; throw PDFLabError.engineRateLimited
                case 500...599:
#if DEBUG
                    await log(http.statusCode, attempt < retryPolicy.maxRetries ? "server" : "server-exhausted")
#endif
                    if attempt < retryPolicy.maxRetries { try await retryPolicy.wait(beforeRetry: attempt); continue }; throw PDFLabError.engineUnavailable(engineID: id)
                default:
#if DEBUG
                    await log(http.statusCode, "permanent-http")
#endif
                    throw PDFLabError.engineUnavailable(engineID: id)
                }
            } catch let error as PDFLabError { throw error }
            catch is CancellationError {
#if DEBUG
                await log(nil, "cancelled")
#endif
                throw CancellationError()
            }
            catch let error as URLError where error.code == .cancelled {
#if DEBUG
                await log(nil, "cancelled")
#endif
                throw CancellationError()
            }
            catch {
#if DEBUG
                await log(nil, attempt < retryPolicy.maxRetries ? "network" : "network-exhausted")
#endif
                if attempt < retryPolicy.maxRetries { try await retryPolicy.wait(beforeRetry: attempt); continue }; throw PDFLabError.networkError(error.localizedDescription)
            }
        }
        throw PDFLabError.engineUnavailable(engineID: id)
    }
    static func parseResponse(_ data: Data) throws -> String {
        guard let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any], let stop = root["stop_reason"] as? String else { throw PDFLabError.engineUnavailable(engineID: "claude") }
        if stop == "max_tokens" { throw PDFLabError.engineOutputTruncated }
        guard stop == "end_turn" || stop == "stop_sequence", let content = root["content"] as? [[String: Any]] else { throw PDFLabError.engineUnavailable(engineID: "claude") }
        let result = content.compactMap { $0["type"] as? String == "text" ? $0["text"] as? String : nil }.joined().trimmingCharacters(in: .whitespacesAndNewlines)
        guard !result.isEmpty else { throw PDFLabError.engineUnavailable(engineID: "claude") }; return result
    }
#if DEBUG
    private static func category(_ error: PDFLabError) -> String {
        switch error { case .engineOutputTruncated: return "output-truncated"; case .engineContentFiltered: return "content-filtered"; default: return "parse" }
    }
#endif
}
