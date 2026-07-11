import Foundation

/// 非官方 DeepL 免 Key 引擎(DeepLX 方案):直接调用 www2.deepl.com 的 JSON-RPC
/// `LMT_handle_texts` 接口。DeepL 封控最严,故 RateLimiter 默认 2s 最小间隔。
///
/// 注意:请求体为手工拼接的 JSON 字符串,以复现 DeepLX 的两个经典技巧——
///  1. 时间戳按文本中字母 'i' 的数量对齐(iCount 算法);
///  2. `"method"` 后的冒号空格数量随请求 id 取模变化。
/// 这两点是 DeepL 校验请求"人性化"的隐藏规则,偏离会被判为机器请求。
public struct DeepLXEngine: TranslationEngine {
    public let id = "deepl", isUnofficial = true, perRequestCharLimit = 3000
    private let client: HTTPClient
    private let limiter: RateLimiter

    public init(client: HTTPClient = URLSession.shared, limiter: RateLimiter = RateLimiter(minInterval: 2.0)) {
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

    private func translateChunk(_ text: String, direction: TranslationDirection) async throws -> String {
        let targetLang = direction == .enToZh ? "ZH" : "EN"
        let body = Self.buildRequestBody(text: text, sourceLang: "auto", targetLang: targetLang)

        var request = URLRequest(url: URL(string: "https://www2.deepl.com/jsonrpc")!)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = body.data(using: .utf8)

        let (data, resp): (Data, URLResponse)
        do { (data, resp) = try await client.data(for: request) }
        catch { throw PDFLabError.networkError(error.localizedDescription) }
        guard let http = resp as? HTTPURLResponse else { throw PDFLabError.engineUnavailable(engineID: id) }
        if http.statusCode == 429 { throw PDFLabError.engineRateLimited }
        guard (200..<300).contains(http.statusCode) else { throw PDFLabError.engineUnavailable(engineID: id) }

        guard let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let result = root["result"] as? [String: Any],
              let texts = result["texts"] as? [[String: Any]],
              let first = texts.first?["text"] as? String else {
            throw PDFLabError.engineUnavailable(engineID: id)
        }
        return first
    }

    /// 手工拼接 JSON-RPC 请求体,复现 DeepLX 的 id/timestamp/method-spacing 规则。
    static func buildRequestBody(text: String, sourceLang: String, targetLang: String) -> String {
        let id = Int.random(in: 8_300_000...8_399_999) * 1000
        let timestamp = timestamp(for: text)
        let escaped = jsonEscape(text)

        var body = """
        {"jsonrpc":"2.0","method":"LMT_handle_texts","id":\(id),"params":{"splitting":"newlines","lang":{"source_lang_user_selected":"\(sourceLang)","target_lang":"\(targetLang)"},"texts":[{"text":"\(escaped)","requestAlternatives":3}],"timestamp":\(timestamp)}}
        """

        // DeepLX 经典 method-spacing 技巧:按 id 取模在冒号后加/减一个空格,
        // 令请求体字节数满足 DeepL 的隐藏校验。
        if (id + 5) % 29 == 0 || (id + 3) % 13 == 0 {
            body = body.replacingOccurrences(of: "\"method\":\"", with: "\"method\" : \"")
        } else {
            body = body.replacingOccurrences(of: "\"method\":\"", with: "\"method\": \"")
        }
        return body
    }

    /// iCount 时间戳对齐:ts 需能被 (文本中 'i' 数量 + 1) 整除。
    private static func timestamp(for text: String) -> Int {
        let iCount = text.filter { $0 == "i" }.count + 1
        let ts = Int(Date().timeIntervalSince1970 * 1000)
        return ts - (ts % iCount) + iCount
    }

    private static func jsonEscape(_ s: String) -> String {
        var out = ""
        for scalar in s.unicodeScalars {
            switch scalar {
            case "\\": out += "\\\\"
            case "\"": out += "\\\""
            case "\n": out += "\\n"
            case "\r": out += "\\r"
            case "\t": out += "\\t"
            default:
                if scalar.value < 0x20 {
                    // U+0020 以下控制字符(如 PDF 换页符 U+000C)必须 \u00XX 转义,
                    // 否则请求体不是合法 JSON。
                    out += String(format: "\\u%04x", scalar.value)
                } else {
                    out.unicodeScalars.append(scalar)
                }
            }
        }
        return out
    }
}
