import Foundation

/// OpenAI 兼容 Chat Completions 接口配置(适配 DeepSeek/Kimi/通义等兼容端点)。
public struct LLMConfig: Codable, Equatable, Sendable {
    public var baseURL: String    // 如 https://api.deepseek.com/v1
    public var model: String
    public init(baseURL: String, model: String) {
        self.baseURL = baseURL
        self.model = model
    }
}

/// LLM 翻译引擎:调用任意 OpenAI 兼容的 `/chat/completions` 接口。
/// v1 不做合批,逐段落独立请求,保证输出顺序与输入一一对应。
public struct OpenAICompatEngine: TranslationEngine {
    public let id = "llm", isUnofficial = false, perRequestCharLimit = 8000
    private let config: LLMConfig
    private let apiKey: String
    private let client: HTTPClient
    private let limiter: RateLimiter

    public init(config: LLMConfig, apiKey: String, client: HTTPClient = URLSession.shared, limiter: RateLimiter = RateLimiter(minInterval: 0.2)) {
        self.config = config
        self.apiKey = apiKey
        self.client = client
        self.limiter = limiter
    }

    public func translate(_ texts: [String], direction: TranslationDirection) async throws -> [String] {
        var results: [String] = []
        for text in texts {
            await limiter.waitTurn()
            results.append(try await complete(userMessage: text, direction: direction))
        }
        return results
    }

    /// 设置面板"测试连接":发一条 "ping",期待非空回复。
    /// 失败按状态码/传输错误映射为 engineInvalidKey / networkError。
    public func testConnection() async throws {
        let reply = try await complete(userMessage: "ping", direction: .enToZh)
        guard !reply.isEmpty else { throw PDFLabError.engineInvalidKey }
    }

    private func complete(userMessage: String, direction: TranslationDirection) async throws -> String {
        let targetLanguage = direction == .enToZh ? "Chinese" : "English"
        let systemPrompt = "You are a professional translator. Translate the user's text to \(targetLanguage). Output ONLY the translation, no explanations."

        var request = URLRequest(url: URL(string: "\(config.baseURL)/chat/completions")!)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        let payload: [String: Any] = [
            "model": config.model,
            "messages": [
                ["role": "system", "content": systemPrompt],
                ["role": "user", "content": userMessage],
            ],
        ]
        request.httpBody = try? JSONSerialization.data(withJSONObject: payload)

        let (data, resp): (Data, URLResponse)
        do { (data, resp) = try await client.data(for: request) }
        catch { throw PDFLabError.networkError(error.localizedDescription) }

        guard let http = resp as? HTTPURLResponse else { throw PDFLabError.engineUnavailable(engineID: id) }
        if http.statusCode == 401 { throw PDFLabError.engineInvalidKey }
        if http.statusCode == 429 { throw PDFLabError.engineRateLimited }
        guard (200..<300).contains(http.statusCode) else { throw PDFLabError.engineUnavailable(engineID: id) }

        guard let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let choices = root["choices"] as? [[String: Any]],
              let message = choices.first?["message"] as? [String: Any],
              let content = message["content"] as? String else {
            throw PDFLabError.engineUnavailable(engineID: id)
        }
        return content
    }
}
