import Foundation

public struct DeepSeekConfig: Codable, Equatable, Sendable {
    public static let defaultBaseURL = "https://api.deepseek.com"
    public static let models = ["deepseek-v4-flash", "deepseek-v4-pro"]
    public static let defaultModel = "deepseek-v4-flash"
    public var baseURL: String
    public var model: String
    public init(baseURL: String = defaultBaseURL, model: String = defaultModel) {
        self.baseURL = baseURL; self.model = Self.models.contains(model) ? model : Self.defaultModel
    }
}

/// DeepSeek 官方 Chat Completions 翻译引擎。
public struct DeepSeekEngine: TranslationEngine {
    public let id = "deepseek", isUnofficial = false, perRequestCharLimit = 8000
    public static let endpoint = URL(string: "\(DeepSeekConfig.defaultBaseURL)/chat/completions")!
    public static let model = DeepSeekConfig.defaultModel
    private let config: DeepSeekConfig
    private let apiKey: String
    private let client: HTTPClient
    private let limiter: RateLimiter
    private let retryPolicy: TranslationRetryPolicy
#if DEBUG
    private let diagnostics: any TranslationDiagnosticSink
#endif

#if DEBUG
    public init(config: DeepSeekConfig = DeepSeekConfig(), apiKey: String, client: HTTPClient = URLSession.shared,
                limiter: RateLimiter = RateLimiter(minInterval: 0.2),
                retryPolicy: TranslationRetryPolicy = TranslationRetryPolicy(),
                diagnostics: any TranslationDiagnosticSink = TranslationDiagnostics.shared) {
        self.config = config; self.apiKey = apiKey; self.client = client; self.limiter = limiter
        self.retryPolicy = retryPolicy; self.diagnostics = diagnostics
    }
#else
    public init(config: DeepSeekConfig = DeepSeekConfig(), apiKey: String, client: HTTPClient = URLSession.shared,
                limiter: RateLimiter = RateLimiter(minInterval: 0.2),
                retryPolicy: TranslationRetryPolicy = TranslationRetryPolicy()) {
        self.config = config; self.apiKey = apiKey; self.client = client; self.limiter = limiter
        self.retryPolicy = retryPolicy
    }
#endif

    public func translate(_ texts: [String], direction: TranslationDirection) async throws -> [String] {
        var output: [String] = []
        for text in texts { output.append(try await complete(text, direction: direction)) }
        return output
    }

    public func testConnection() async throws {
        _ = try await complete("Translate this word: test", direction: .enToZh)
    }

    private func complete(_ text: String, direction: TranslationDirection) async throws -> String {
        let endpoint = try ProviderBaseURL.endpoint(baseURL: config.baseURL, path: "/chat/completions")
        var request = URLRequest(url: endpoint)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        let target = direction == .enToZh ? "Simplified Chinese" : "English"
        let payload: [String: Any] = [
            "model": config.model,
            "stream": false,
            "thinking": ["type": "disabled"],
            "messages": [
                ["role": "system", "content": "You are a professional translator. Translate the user's text into \(target), preserving meaning, structure, terminology, and formatting. Output only the translation."],
                ["role": "user", "content": text],
            ],
        ]
        request.httpBody = try JSONSerialization.data(withJSONObject: payload)

        for attempt in 0...retryPolicy.maxRetries {
#if DEBUG
            let context = TranslationDiagnosticScope.current ?? .init(runID: UUID())
            let requestID = UUID(), started = Date()
            var receivedResponse = false
#endif
            do {
                try await limiter.waitTurn()
                let (data, response) = try await client.data(for: request)
#if DEBUG
                receivedResponse = true
#endif
                guard let http = response as? HTTPURLResponse else {
#if DEBUG
                    await record(context, requestID, started, direction, text.count, nil, attempt, "invalid-response")
#endif
                    throw PDFLabError.engineUnavailable(engineID: id)
                }
                switch http.statusCode {
                case 200..<300:
                    do {
                        let result = try Self.parseResponse(data)
#if DEBUG
                        await record(context, requestID, started, direction, text.count, http.statusCode, attempt, nil)
#endif
                        return result
                    } catch DeepSeekResponseError.insufficientSystemResource {
#if DEBUG
                        await record(context, requestID, started, direction, text.count, http.statusCode, attempt,
                                     attempt < retryPolicy.maxRetries ? "resource" : "resource-exhausted")
#endif
                        if attempt < retryPolicy.maxRetries { try await retryPolicy.wait(beforeRetry: attempt); continue }
                        throw PDFLabError.engineUnavailable(engineID: id)
                    } catch let error as PDFLabError {
#if DEBUG
                        await record(context, requestID, started, direction, text.count, http.statusCode, attempt, Self.category(error))
#endif
                        throw error
                    } catch {
#if DEBUG
                        await record(context, requestID, started, direction, text.count, http.statusCode, attempt, "parse")
#endif
                        throw PDFLabError.engineUnavailable(engineID: id)
                    }
                case 400, 422:
#if DEBUG
                    await record(context, requestID, started, direction, text.count, http.statusCode, attempt, "invalid-request")
#endif
                    throw PDFLabError.engineInvalidRequest
                case 401:
#if DEBUG
                    await record(context, requestID, started, direction, text.count, http.statusCode, attempt, "invalid-key")
#endif
                    throw PDFLabError.engineInvalidKey
                case 402:
#if DEBUG
                    await record(context, requestID, started, direction, text.count, http.statusCode, attempt, "insufficient-balance")
#endif
                    throw PDFLabError.engineInsufficientBalance
                case 429:
#if DEBUG
                    await record(context, requestID, started, direction, text.count, http.statusCode, attempt,
                                 attempt < retryPolicy.maxRetries ? "rate-limited" : "rate-limited-exhausted")
#endif
                    if attempt < retryPolicy.maxRetries { try await retryPolicy.wait(beforeRetry: attempt); continue }
                    throw PDFLabError.engineRateLimited
                case 500, 503:
#if DEBUG
                    await record(context, requestID, started, direction, text.count, http.statusCode, attempt,
                                 attempt < retryPolicy.maxRetries ? "server" : "server-exhausted")
#endif
                    if attempt < retryPolicy.maxRetries { try await retryPolicy.wait(beforeRetry: attempt); continue }
                    throw PDFLabError.engineUnavailable(engineID: id)
                default:
#if DEBUG
                    await record(context, requestID, started, direction, text.count, http.statusCode, attempt, "permanent-http")
#endif
                    throw PDFLabError.engineUnavailable(engineID: id)
                }
            } catch let error as PDFLabError { throw error }
            catch is CancellationError {
#if DEBUG
                if !receivedResponse { await record(context, requestID, started, direction, text.count, nil, attempt, "cancelled") }
#endif
                throw CancellationError()
            }
            catch let error as URLError where error.code == .cancelled {
#if DEBUG
                if !receivedResponse { await record(context, requestID, started, direction, text.count, nil, attempt, "cancelled") }
#endif
                throw CancellationError()
            }
            catch {
#if DEBUG
                await record(context, requestID, started, direction, text.count, nil, attempt,
                             attempt < retryPolicy.maxRetries ? "network" : "network-exhausted")
#endif
                if attempt < retryPolicy.maxRetries { try await retryPolicy.wait(beforeRetry: attempt); continue }
                throw PDFLabError.networkError(error.localizedDescription)
            }
        }
        throw PDFLabError.engineUnavailable(engineID: id)
    }

    static func parseResponse(_ data: Data) throws -> String {
        guard let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw PDFLabError.engineUnavailable(engineID: "deepseek")
        }
        if let error = root["error"] as? [String: Any],
           error["code"] as? String == "insufficient_system_resource" {
            throw DeepSeekResponseError.insufficientSystemResource
        }
        guard let choices = root["choices"] as? [[String: Any]], let choice = choices.first,
              let finishReason = choice["finish_reason"] as? String else {
            throw PDFLabError.engineUnavailable(engineID: "deepseek")
        }
        switch finishReason {
        case "insufficient_system_resource": throw DeepSeekResponseError.insufficientSystemResource
        case "length": throw PDFLabError.engineOutputTruncated
        case "content_filter": throw PDFLabError.engineContentFiltered
        case "stop": break
        default: throw PDFLabError.engineUnavailable(engineID: "deepseek")
        }
        guard let message = choice["message"] as? [String: Any], message["tool_calls"] == nil,
              let content = message["content"] as? String,
              !content.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw PDFLabError.engineUnavailable(engineID: "deepseek")
        }
        return content
    }

    private enum DeepSeekResponseError: Error { case insufficientSystemResource }

#if DEBUG
    private func record(_ context: TranslationDiagnosticContext, _ requestID: UUID, _ started: Date,
                        _ direction: TranslationDirection, _ count: Int, _ status: Int?, _ retry: Int,
                        _ category: String?) async {
        await diagnostics.record(.init(runID: context.runID, requestID: requestID, engine: id,
            stage: "http", direction: direction, batch: context.batch, pageStart: context.pageStart,
            pageEnd: context.pageEnd, characterCount: count,
            durationMilliseconds: Int(Date().timeIntervalSince(started) * 1000), httpStatus: status,
            retryCount: retry, errorCategory: category))
    }

    private static func category(_ error: PDFLabError) -> String {
        switch error {
        case .engineOutputTruncated: return "output-truncated"
        case .engineContentFiltered: return "content-filtered"
        default: return "parse"
        }
    }
#endif
}
