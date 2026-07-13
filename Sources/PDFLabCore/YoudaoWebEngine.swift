import Foundation
import CryptoKit
import CommonCrypto

/// 非官方有道免 Key 网页翻译引擎(`dict.youdao.com/webtranslate`)。
///
/// 采用两步握手(镜像 Easydict `YoudaoService` 2025 实现):
///  1. **取密钥**:GET `/webtranslate/key`,`keyid=webfanyi-key-getter`,用固定
///     `defaultKey` 签名;响应是明文 JSON,含动态 `secretKey` 与 `aesKey`/`aesIv`。
///  2. **翻译**:POST `/webtranslate`,`keyid=webfanyi`,用第 1 步拿到的 `secretKey`
///     签名;响应是 URL-safe Base64 的 AES-128-CBC 密文,用第 1 步的 `aesKey`/`aesIv`
///     (各取其 MD5 的 16 字节)解密,得到 `translateResult` JSON。
///
/// 与 Google/DeepL 同属"免 Key、零配置、标注非官方"阵营:不碰 Keychain,失效时
/// 抛 `engineUnavailable` 引导切换。
///
/// ⚠️ 全部常量(`defaultKey`、AES 种子、Cookie/UA)都是逆向社区公开值,有道会不定期
/// 更新导致失效;届时需重新逆向(参考 Easydict `YoudaoService+Translate.swift`)。
public struct YoudaoWebEngine: TranslationEngine {
    // 网页接口比官方 API 更严格,单次请求上限取保守值。
    public let id = "youdao", isUnofficial = true, perRequestCharLimit = 900
    private let client: HTTPClient
    private let limiter: RateLimiter
#if DEBUG
    private let diagnostics: any TranslationDiagnosticSink
#endif
    private struct ResponseInvalid: Error {}
    private struct HTTPResult {
        let data: Data
#if DEBUG
        let requestID: UUID
        let started: Date
        let status: Int
#endif
    }

    /// 取密钥步骤的固定签名 key(逆向公开值,可能漂移)。
    static let defaultKey = "asdjnjfenknafdfsdfsd"
    /// 服务端 `aesKey`/`aesIv` 缺失时的兜底种子(实测服务端就返回这两串)。
    static let fallbackAesKeySeed = "ydsecret://query/key/B*RGygVywfNBwpmBaZg*WT7SIOUP2T0C9WHMZN39j^DAdaZhAnxvGcCY6VYFwnHl"
    static let fallbackAesIvSeed = "ydsecret://query/iv/C@lZe2YzHtZ2CYgaXKSVfsb7Y4QWHjITPPZ0nQp87fBeJ!Iv6v^6fvi2WN@bYpJ4"

    private static let keyEndpoint = "https://dict.youdao.com/webtranslate/key"
    private static let translateEndpoint = "https://dict.youdao.com/webtranslate"

    /// 握手拿到的会话密钥:`secretKey` 用于翻译请求签名,`aesKeySeed`/`aesIvSeed` 的 MD5 用于解密。
    struct SessionKey: Equatable {
        var secretKey: String
        var aesKeySeed: String
        var aesIvSeed: String
    }

#if DEBUG
    public init(client: HTTPClient = URLSession.shared, limiter: RateLimiter = RateLimiter(minInterval: 1.0),
                diagnostics: any TranslationDiagnosticSink = TranslationDiagnostics.shared) {
        self.client = client; self.limiter = limiter; self.diagnostics = diagnostics
    }
#else
    public init(client: HTTPClient = URLSession.shared, limiter: RateLimiter = RateLimiter(minInterval: 1.0)) {
        self.client = client
        self.limiter = limiter
    }
#endif

    public func translate(_ texts: [String], direction: TranslationDirection) async throws -> [String] {
#if DEBUG
        let context = TranslationDiagnosticScope.current ?? .init(runID: UUID())
        return try await TranslationDiagnosticScope.$current.withValue(context) {
            try await translateWithinContext(texts, direction: direction)
        }
#else
        return try await translateWithinContext(texts, direction: direction)
#endif
    }

    private func translateWithinContext(_ texts: [String], direction: TranslationDirection) async throws -> [String] {
        var session = try await fetchSessionKey(direction: direction)

        var results: [String] = []
        for text in texts {
            var translated = ""
            for chunk in TextChunker.split(text, limit: perRequestCharLimit) {
                do {
                    translated += try await translateChunk(chunk, direction: direction, session: session, retry: 0)
                } catch is ResponseInvalid {
                    session = try await fetchSessionKey(direction: direction)
                    do {
                        translated += try await translateChunk(chunk, direction: direction, session: session, retry: 1)
                    } catch is ResponseInvalid {
                        throw PDFLabError.engineUnavailable(engineID: id)
                    }
                }
            }
            results.append(translated)
        }
        return results
    }

    // MARK: - 第 1 步:取会话密钥

    private func fetchSessionKey(direction: TranslationDirection) async throws -> SessionKey {
        let mysticTime = String(Int(Date().timeIntervalSince1970 * 1000))
        let sign = Self.sign(mysticTime: mysticTime, secret: Self.defaultKey)

        var comps = URLComponents(string: Self.keyEndpoint)!
        comps.queryItems = Self.generalFields(keyid: "webfanyi-key-getter", sign: sign, mysticTime: mysticTime)
            .map { URLQueryItem(name: $0.0, value: $0.1) }

        var request = URLRequest(url: comps.url!)
        request.httpMethod = "GET"
        Self.applyBrowserHeaders(&request)

        let response = try await perform(request, stage: "youdao-handshake", direction: direction, characterCount: 0, retry: 0)
        // 取密钥响应是明文 JSON:{ "code":0, "data":{ "secretKey":..,"aesKey":..,"aesIv":.. } }
        guard let root = try? JSONSerialization.jsonObject(with: response.data) as? [String: Any],
              let payload = root["data"] as? [String: Any],
              let secretKey = payload["secretKey"] as? String, !secretKey.isEmpty else {
#if DEBUG
            await record(stage: "youdao-handshake-parse", direction: direction, characterCount: 0,
                         status: response.status, retry: 0, error: "session-key-invalid",
                         requestID: response.requestID, started: response.started)
#endif
            throw PDFLabError.engineUnavailable(engineID: id)
        }
#if DEBUG
        await record(stage: "youdao-handshake", direction: direction, characterCount: 0,
                     status: response.status, retry: 0, error: nil,
                     requestID: response.requestID, started: response.started)
#endif
        return SessionKey(
            secretKey: secretKey,
            aesKeySeed: (payload["aesKey"] as? String) ?? Self.fallbackAesKeySeed,
            aesIvSeed: (payload["aesIv"] as? String) ?? Self.fallbackAesIvSeed
        )
    }

    // MARK: - 第 2 步:翻译

    private func translateChunk(_ text: String, direction: TranslationDirection, session: SessionKey, retry: Int) async throws -> String {
        let to = direction == .enToZh ? "zh-CHS" : "en"
        let mysticTime = String(Int(Date().timeIntervalSince1970 * 1000))
        let sign = Self.sign(mysticTime: mysticTime, secret: session.secretKey)

        var fields = Self.generalFields(keyid: "webfanyi", sign: sign, mysticTime: mysticTime)
        fields.append(contentsOf: [("i", text), ("from", "AUTO"), ("to", to), ("dictResult", "false")])
        let body = fields.map { "\(Self.formEncode($0.0))=\(Self.formEncode($0.1))" }.joined(separator: "&")

        var request = URLRequest(url: URL(string: Self.translateEndpoint)!)
        request.httpMethod = "POST"
        request.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
        Self.applyBrowserHeaders(&request)
        request.httpBody = body.data(using: .utf8)

        let response = try await perform(request, stage: "youdao-translate", direction: direction, characterCount: text.count, retry: retry)
        guard let base64url = String(data: response.data, encoding: .utf8),
              let plaintext = Self.decryptResponse(base64url, aesKeySeed: session.aesKeySeed, aesIvSeed: session.aesIvSeed),
              let translation = Self.parseTranslation(plaintext) else {
            #if DEBUG
            await record(stage: "youdao-parse", direction: direction, characterCount: text.count,
                         status: response.status, retry: retry, error: "decrypt-or-parse",
                         requestID: response.requestID, started: response.started)
#endif
            throw ResponseInvalid()
        }
#if DEBUG
        await record(stage: "youdao-translate", direction: direction, characterCount: text.count,
                     status: response.status, retry: retry, error: nil,
                     requestID: response.requestID, started: response.started)
#endif
        return translation
    }

    // MARK: - HTTP

    private func perform(_ request: URLRequest, stage: String, direction: TranslationDirection,
                         characterCount: Int, retry: Int) async throws -> HTTPResult {
        try await limiter.waitTurn()
#if DEBUG
        let started = Date(), requestID = UUID()
#endif
        let (data, resp): (Data, URLResponse)
        do { (data, resp) = try await client.data(for: request) }
        catch is CancellationError {
#if DEBUG
            await record(stage: stage, direction: direction, characterCount: characterCount, retry: retry, error: "cancelled", requestID: requestID, started: started)
#endif
            throw CancellationError()
        }
        catch let error as URLError where error.code == .cancelled {
#if DEBUG
            await record(stage: stage, direction: direction, characterCount: characterCount, retry: retry,
                         error: "cancelled", requestID: requestID, started: started)
#endif
            throw CancellationError()
        }
        catch {
#if DEBUG
            await record(stage: stage, direction: direction, characterCount: characterCount, retry: retry, error: "network", requestID: requestID, started: started)
#endif
            throw PDFLabError.networkError(error.localizedDescription)
        }
        guard let http = resp as? HTTPURLResponse else {
#if DEBUG
            await record(stage: stage, direction: direction, characterCount: characterCount, retry: retry,
                         error: "invalid-response", requestID: requestID, started: started)
#endif
            throw PDFLabError.engineUnavailable(engineID: id)
        }
#if DEBUG
        if !(200..<300).contains(http.statusCode) {
            await record(stage: stage, direction: direction, characterCount: characterCount, status: http.statusCode,
                         retry: retry, error: http.statusCode == 429 ? "rate-limited" : "http",
                         requestID: requestID, started: started)
        }
#endif
        if http.statusCode == 429 { throw PDFLabError.engineRateLimited }
        guard (200..<300).contains(http.statusCode) else { throw PDFLabError.engineUnavailable(engineID: id) }
#if DEBUG
        return HTTPResult(data: data, requestID: requestID, started: started, status: http.statusCode)
#else
        return HTTPResult(data: data)
#endif
    }

#if DEBUG
    private func record(stage: String, direction: TranslationDirection, characterCount: Int, status: Int? = nil,
                        retry: Int, error: String?, requestID: UUID = UUID(), started: Date = Date()) async {
        let context = TranslationDiagnosticScope.current ?? .init(runID: UUID())
        await diagnostics.record(.init(runID: context.runID, requestID: requestID, engine: id, stage: stage,
            direction: direction, batch: context.batch, pageStart: context.pageStart, pageEnd: context.pageEnd,
            characterCount: characterCount, durationMilliseconds: Int(Date().timeIntervalSince(started) * 1000),
            httpStatus: status, retryCount: retry, errorCategory: error))
    }
#endif

    /// 两个端点共用的固定字段。
    static func generalFields(keyid: String, sign: String, mysticTime: String) -> [(String, String)] {
        [
            ("keyid", keyid),
            ("sign", sign),
            ("client", "fanyideskweb"),
            ("product", "webfanyi"),
            ("appVersion", "1.0.0"),
            ("vendor", "web"),
            ("pointParam", "client,mysticTime,product"),
            ("mysticTime", mysticTime),
            ("keyfrom", "fanyi.web"),
        ]
    }

    private static func applyBrowserHeaders(_ request: inout URLRequest) {
        request.setValue("https://fanyi.youdao.com/", forHTTPHeaderField: "Referer")
        request.setValue("Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/120.0.0.0 Safari/537.36", forHTTPHeaderField: "User-Agent")
        request.setValue("OUTFOX_SEARCH_USER_ID=-2022895562@1.1.1.1; OUTFOX_SEARCH_USER_ID_NCOO=123456789.98765", forHTTPHeaderField: "Cookie")
    }

    // MARK: - 签名

    /// `sign = MD5("client=fanyideskweb&mysticTime={ts}&product=webfanyi&key={secret}")`,32 位小写 hex。
    static func sign(mysticTime: String, secret: String) -> String {
        let raw = "client=fanyideskweb&mysticTime=\(mysticTime)&product=webfanyi&key=\(secret)"
        return Insecure.MD5.hash(data: Data(raw.utf8)).map { String(format: "%02x", $0) }.joined()
    }

    // MARK: - AES 解密

    /// 由种子串的 MD5(16 字节)得到 AES-128 的 key/iv 字节。
    static func md5Bytes(_ s: String) -> [UInt8] {
        Array(Insecure.MD5.hash(data: Data(s.utf8)))
    }

    /// URL-safe Base64 解码 → AES-128-CBC(PKCS7)解密 → UTF-8 明文。任一步失败返回 nil。
    static func decryptResponse(_ base64url: String, aesKeySeed: String, aesIvSeed: String) -> String? {
        guard let cipher = base64urlDecode(base64url),
              let plain = aesCBCDecrypt(cipher, key: md5Bytes(aesKeySeed), iv: md5Bytes(aesIvSeed)) else { return nil }
        return String(bytes: plain, encoding: .utf8)
    }

    /// URL-safe Base64(`-`→`+`,`_`→`/`)解码,自动补齐 `=` padding。
    static func base64urlDecode(_ s: String) -> [UInt8]? {
        var str = s.trimmingCharacters(in: .whitespacesAndNewlines)
            .replacingOccurrences(of: "-", with: "+")
            .replacingOccurrences(of: "_", with: "/")
        let remainder = str.count % 4
        if remainder > 0 { str += String(repeating: "=", count: 4 - remainder) }
        guard let d = Data(base64Encoded: str) else { return nil }
        return [UInt8](d)
    }

    /// AES-128-CBC + PKCS7 解密(CommonCrypto,零第三方依赖)。
    static func aesCBCDecrypt(_ data: [UInt8], key: [UInt8], iv: [UInt8]) -> [UInt8]? {
        guard key.count == kCCKeySizeAES128, iv.count == kCCBlockSizeAES128, !data.isEmpty else { return nil }
        var outLength = 0
        var out = [UInt8](repeating: 0, count: data.count + kCCBlockSizeAES128)
        let status = CCCrypt(
            CCOperation(kCCDecrypt),
            CCAlgorithm(kCCAlgorithmAES),
            CCOptions(kCCOptionPKCS7Padding),
            key, key.count,
            iv,
            data, data.count,
            &out, out.count,
            &outLength
        )
        guard status == kCCSuccess else { return nil }
        return Array(out.prefix(outLength))
    }

    // MARK: - 响应解析

    /// 明文 JSON 的 `translateResult` 有两种形态:
    ///  - 双层 `[[{"tgt":..}]]`(正常译文,外层按段、内层按句);
    ///  - 单层 `[{"tgt":..}]`(签名失效时服务端返回的诱饵)。
    /// 两种都拍平拼接 `tgt`,便于健壮解析。
    static func parseTranslation(_ plaintext: String) -> String? {
        guard let data = plaintext.data(using: .utf8),
              let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let result = root["translateResult"] as? [Any] else { return nil }
        var out = ""
        for element in result {
            if let group = element as? [[String: Any]] {            // 双层:一段含多句
                out += group.compactMap { $0["tgt"] as? String }.joined()
            } else if let item = element as? [String: Any],         // 单层:直接是句对象
                      let tgt = item["tgt"] as? String {
                out += tgt
            }
        }
        return out.isEmpty ? nil : out
    }

    private static func formEncode(_ s: String) -> String {
        var allowed = CharacterSet.alphanumerics
        allowed.insert(charactersIn: "-._~")
        return s.addingPercentEncoding(withAllowedCharacters: allowed) ?? s
    }
}
