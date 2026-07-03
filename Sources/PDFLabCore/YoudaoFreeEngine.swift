import Foundation
import CryptoKit

/// 非官方有道免 Key 引擎:调用 dict.youdao.com/webtranslate,签名走经典
/// `fanyideskweb` MD5 链路。响应解析为 `translateResult` JSON 结构。
///
/// 说明:有道近年将 webtranslate 响应改为 AES 加密 base64,且签名 key 会随
/// 前端版本漂移。本实现固定为公开已知的 fanyideskweb 方案,便于确定性测试;
/// 线上若因签名/加密变动被拒,会抛 `engineUnavailable`,由 UI 提示切换引擎。
public struct YoudaoFreeEngine: TranslationEngine {
    public let id = "youdao", isUnofficial = true, perRequestCharLimit = 4000
    private let client: HTTPClient
    private let limiter: RateLimiter

    // fanyideskweb 方案的公开常量。
    private static let signClient = "fanyideskweb"
    private static let signKey = "Ygy_4c=r#e#4EX^NUGUc5"

    public init(client: HTTPClient = URLSession.shared, limiter: RateLimiter = RateLimiter(minInterval: 1.0)) {
        self.client = client; self.limiter = limiter
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

    /// MD5(client + query + salt + time + key) → 32 位小写 hex。
    public static func youdaoSign(query: String, salt: String, time: String) -> String {
        let raw = signClient + query + salt + time + signKey
        let digest = Insecure.MD5.hash(data: Data(raw.utf8))
        return digest.map { String(format: "%02x", $0) }.joined()
    }

    private func translateChunk(_ text: String, direction: TranslationDirection) async throws -> String {
        let (from, to) = direction == .enToZh ? ("en", "zh-CHS") : ("zh-CHS", "en")
        let time = String(Int(Date().timeIntervalSince1970 * 1000))
        let salt = time + String(Int.random(in: 0...9))
        let sign = Self.youdaoSign(query: text, salt: salt, time: time)

        let fields: [(String, String)] = [
            ("i", text),
            ("from", from),
            ("to", to),
            ("dictResult", "true"),
            ("keyid", "webfanyi"),
            ("client", "fanyideskweb"),
            ("product", "webfanyi"),
            ("appVersion", "1.0.0"),
            ("vendor", "web"),
            ("pointParam", "client,mysticTime,product"),
            ("mysticTime", time),
            ("keyfrom", "fanyi.web"),
            ("salt", salt),
            ("sign", sign),
        ]
        let body = fields.map { "\(Self.formEncode($0.0))=\(Self.formEncode($0.1))" }.joined(separator: "&")

        var request = URLRequest(url: URL(string: "https://dict.youdao.com/webtranslate")!)
        request.httpMethod = "POST"
        request.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
        request.httpBody = body.data(using: .utf8)

        let (data, resp): (Data, URLResponse)
        do { (data, resp) = try await client.data(for: request) }
        catch { throw PDFLabError.networkError(error.localizedDescription) }
        guard let http = resp as? HTTPURLResponse else { throw PDFLabError.engineUnavailable(engineID: id) }
        if http.statusCode == 429 { throw PDFLabError.engineRateLimited }
        guard (200..<300).contains(http.statusCode) else { throw PDFLabError.engineUnavailable(engineID: id) }

        guard let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let groups = root["translateResult"] as? [[[String: Any]]] else {
            throw PDFLabError.engineUnavailable(engineID: id)
        }
        // translateResult: [[{tgt,src}, ...], ...] —— 逐句拼接 tgt。
        let joined = groups.flatMap { $0 }.compactMap { $0["tgt"] as? String }.joined()
        return joined
    }

    private static func formEncode(_ s: String) -> String {
        var allowed = CharacterSet.alphanumerics
        allowed.insert(charactersIn: "-._~")
        return s.addingPercentEncoding(withAllowedCharacters: allowed) ?? s
    }
}
