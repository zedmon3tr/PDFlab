import Foundation
import CryptoKit

/// 有道智云官方文本翻译引擎:POST 表单到 openapi.youdao.com/api,
/// 使用用户自备的 appKey + appSecret 做 v3(SHA256)签名。
/// 与 OpenAICompatEngine 同属"用户提供凭据"模式:凭据由 UI/工厂层
/// 经 KeychainStore 存取后注入,引擎本身不碰钥匙串。
public struct YoudaoZhiyunEngine: TranslationEngine {
    public let id = "youdao", isUnofficial = false, perRequestCharLimit = 5000
    private let appKey: String
    private let appSecret: String
    private let client: HTTPClient
    private let limiter: RateLimiter

    public init(appKey: String, appSecret: String, client: HTTPClient = URLSession.shared, limiter: RateLimiter = RateLimiter(minInterval: 0.5)) {
        self.appKey = appKey
        self.appSecret = appSecret
        self.client = client
        self.limiter = limiter
    }

    public func translate(_ texts: [String], direction: TranslationDirection) async throws -> [String] {
        var results: [String] = []
        for text in texts {
            var translated = ""
            for chunk in TextChunker.split(text, limit: perRequestCharLimit) {
                await limiter.waitTurn()
                translated += try await translateChunk(chunk, direction: direction)
            }
            results.append(translated)
        }
        return results
    }

    /// 设置面板"测试连接":翻译一条 "hello",期待非空译文。
    /// 凭据错误(errorCode 108/202/401)由 translateChunk 映射为 engineInvalidKey,
    /// 欠费/超额(如 411)等其余错误映射为 engineUnavailable。
    public func testConnection() async throws {
        await limiter.waitTurn()
        let reply = try await translateChunk("hello", direction: .enToZh)
        guard !reply.isEmpty else { throw PDFLabError.engineUnavailable(engineID: id) }
    }

    /// v3 签名:SHA256(appKey + input + salt + curtime + appSecret) → 64 位小写 hex,
    /// 其中 input = q.count <= 20 ? q : 前 10 字符 + q 字符数 + 后 10 字符。
    public static func youdaoV3Sign(appKey: String, q: String, salt: String, curtime: String, appSecret: String) -> String {
        let input = q.count <= 20 ? q : String(q.prefix(10)) + String(q.count) + String(q.suffix(10))
        let digest = SHA256.hash(data: Data((appKey + input + salt + curtime + appSecret).utf8))
        return digest.map { String(format: "%02x", $0) }.joined()
    }

    private func translateChunk(_ text: String, direction: TranslationDirection) async throws -> String {
        let (from, to) = direction == .enToZh ? ("en", "zh-CHS") : ("zh-CHS", "en")
        let salt = UUID().uuidString
        let curtime = String(Int(Date().timeIntervalSince1970))
        let sign = Self.youdaoV3Sign(appKey: appKey, q: text, salt: salt, curtime: curtime, appSecret: appSecret)

        let fields: [(String, String)] = [
            ("q", text),
            ("from", from),
            ("to", to),
            ("appKey", appKey),
            ("salt", salt),
            ("sign", sign),
            ("signType", "v3"),
            ("curtime", curtime),
        ]
        let body = fields.map { "\(Self.formEncode($0.0))=\(Self.formEncode($0.1))" }.joined(separator: "&")

        var request = URLRequest(url: URL(string: "https://openapi.youdao.com/api")!)
        request.httpMethod = "POST"
        request.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
        request.httpBody = body.data(using: .utf8)

        let (data, resp): (Data, URLResponse)
        do { (data, resp) = try await client.data(for: request) }
        catch { throw PDFLabError.networkError(error.localizedDescription) }
        guard let http = resp as? HTTPURLResponse else { throw PDFLabError.engineUnavailable(engineID: id) }
        if http.statusCode == 429 { throw PDFLabError.engineRateLimited }
        guard (200..<300).contains(http.statusCode) else { throw PDFLabError.engineUnavailable(engineID: id) }

        // 有道对凭据/额度错误返回 200 + 非零 errorCode:
        // 108(appKey 无效)/202(签名错误,含 appSecret 错)/401(账户异常)→ engineInvalidKey,
        // 让设置面板"测试连接"提示"密钥无效"(与 LLM 引擎 UX 对齐);
        // 411(超额)等其余错误码 → engineUnavailable。
        guard let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw PDFLabError.engineUnavailable(engineID: id)
        }
        if let errorCode = root["errorCode"] as? String, errorCode != "0" {
            if ["108", "202", "401"].contains(errorCode) {
                throw PDFLabError.engineInvalidKey
            }
            throw PDFLabError.engineUnavailable(engineID: id)
        }
        guard let translation = root["translation"] as? [String] else {
            throw PDFLabError.engineUnavailable(engineID: id)
        }
        return translation.joined()
    }

    private static func formEncode(_ s: String) -> String {
        var allowed = CharacterSet.alphanumerics
        allowed.insert(charactersIn: "-._~")
        return s.addingPercentEncoding(withAllowedCharacters: allowed) ?? s
    }
}
