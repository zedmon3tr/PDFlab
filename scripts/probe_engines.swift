#!/usr/bin/env swift
// Manual live-endpoint probe for the free translation engines (Task 10).
// Standalone script: mirrors the exact request SHAPE built by GoogleFreeEngine,
// DeepLXEngine and YoudaoWebEngine, then calls each real endpoint once with
// "Hello world" (EN->ZH) and prints the outcome.
//
// Run:  DEVELOPER_DIR=/Library/Developer/CommandLineTools swift scripts/probe_engines.swift
//
// DeepLX/Youdao are expected to possibly fail (blocked / signature or payload
// drift); that is acceptable per the brief — the point is to confirm the request
// shape and document real status. Only Google is required to succeed.

import Foundation
import CryptoKit
import CommonCrypto

let sem = DispatchSemaphore(value: 0)
let session = URLSession(configuration: .default)
let query = "Hello world"

func report(_ name: String, _ outcome: String) {
    print("[\(name)] \(outcome)")
}

// MARK: Google
func probeGoogle() async {
    var comps = URLComponents(string: "https://translate.googleapis.com/translate_a/single")!
    comps.queryItems = [.init(name: "client", value: "gtx"), .init(name: "sl", value: "en"),
                        .init(name: "tl", value: "zh-CN"), .init(name: "dt", value: "t"),
                        .init(name: "q", value: query)]
    do {
        let (data, resp) = try await session.data(for: URLRequest(url: comps.url!))
        let code = (resp as? HTTPURLResponse)?.statusCode ?? -1
        if let root = try? JSONSerialization.jsonObject(with: data) as? [Any],
           let sentences = root.first as? [[Any]] {
            let text = sentences.compactMap { $0.first as? String }.joined()
            report("google", "LIVE OK (\(code)) -> \"\(text)\"")
        } else {
            report("google", "HTTP \(code) but unparseable body")
        }
    } catch { report("google", "network error: \(error.localizedDescription)") }
}

// MARK: DeepLX
func probeDeepLX() async {
    let id = Int.random(in: 8_300_000...8_399_999) * 1000
    let iCount = query.filter { $0 == "i" }.count + 1
    let rawTs = Int(Date().timeIntervalSince1970 * 1000)
    let ts = rawTs - (rawTs % iCount) + iCount
    var body = """
    {"jsonrpc":"2.0","method":"LMT_handle_texts","id":\(id),"params":{"splitting":"newlines","lang":{"source_lang_user_selected":"EN","target_lang":"ZH"},"texts":[{"text":"\(query)","requestAlternatives":3}],"timestamp":\(ts)}}
    """
    if (id + 5) % 29 == 0 || (id + 3) % 13 == 0 {
        body = body.replacingOccurrences(of: "\"method\":\"", with: "\"method\" : \"")
    } else {
        body = body.replacingOccurrences(of: "\"method\":\"", with: "\"method\": \"")
    }
    var req = URLRequest(url: URL(string: "https://www2.deepl.com/jsonrpc")!)
    req.httpMethod = "POST"
    req.setValue("application/json", forHTTPHeaderField: "Content-Type")
    req.httpBody = body.data(using: .utf8)
    do {
        let (data, resp) = try await session.data(for: req)
        let code = (resp as? HTTPURLResponse)?.statusCode ?? -1
        if code == 429 { report("deepl", "rate-limited (429) -> engineRateLimited"); return }
        guard (200..<300).contains(code) else {
            report("deepl", "HTTP \(code) -> engineUnavailable (blocked, acceptable)"); return
        }
        if let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
           let result = root["result"] as? [String: Any],
           let texts = result["texts"] as? [[String: Any]],
           let text = texts.first?["text"] as? String {
            report("deepl", "LIVE OK (\(code)) -> \"\(text)\"")
        } else {
            report("deepl", "HTTP \(code) but unparseable body -> engineUnavailable")
        }
    } catch { report("deepl", "network error: \(error.localizedDescription)") }
}

// MARK: Youdao (免 Key 网页接口,镜像 YoudaoWebEngine 的两步握手)
// 第1步 GET /webtranslate/key(defaultKey 签名)拿 secretKey + aes 种子;
// 第2步 POST /webtranslate(secretKey 签名),AES-128-CBC 解密响应。
let youdaoDefaultKey = "asdjnjfenknafdfsdfsd"
let youdaoFallbackKeySeed = "ydsecret://query/key/B*RGygVywfNBwpmBaZg*WT7SIOUP2T0C9WHMZN39j^DAdaZhAnxvGcCY6VYFwnHl"
let youdaoFallbackIvSeed = "ydsecret://query/iv/C@lZe2YzHtZ2CYgaXKSVfsb7Y4QWHjITPPZ0nQp87fBeJ!Iv6v^6fvi2WN@bYpJ4"

func youdaoSign(mysticTime: String, secret: String) -> String {
    let raw = "client=fanyideskweb&mysticTime=\(mysticTime)&product=webfanyi&key=\(secret)"
    return Insecure.MD5.hash(data: Data(raw.utf8)).map { String(format: "%02x", $0) }.joined()
}
func md5Bytes(_ s: String) -> [UInt8] { Array(Insecure.MD5.hash(data: Data(s.utf8))) }
func youdaoGeneralItems(keyid: String, sign: String, mysticTime: String) -> [(String, String)] {
    [("keyid", keyid), ("sign", sign), ("client", "fanyideskweb"), ("product", "webfanyi"),
     ("appVersion", "1.0.0"), ("vendor", "web"), ("pointParam", "client,mysticTime,product"),
     ("mysticTime", mysticTime), ("keyfrom", "fanyi.web")]
}
func youdaoHeaders(_ req: inout URLRequest) {
    req.setValue("https://fanyi.youdao.com/", forHTTPHeaderField: "Referer")
    req.setValue("Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/120.0.0.0 Safari/537.36", forHTTPHeaderField: "User-Agent")
    req.setValue("OUTFOX_SEARCH_USER_ID=-2022895562@1.1.1.1; OUTFOX_SEARCH_USER_ID_NCOO=123456789.98765", forHTTPHeaderField: "Cookie")
}
func base64urlDecode(_ s: String) -> [UInt8]? {
    var str = s.trimmingCharacters(in: .whitespacesAndNewlines)
        .replacingOccurrences(of: "-", with: "+").replacingOccurrences(of: "_", with: "/")
    let rem = str.count % 4
    if rem > 0 { str += String(repeating: "=", count: 4 - rem) }
    guard let d = Data(base64Encoded: str) else { return nil }
    return [UInt8](d)
}
func aesCBCDecrypt(_ data: [UInt8], key: [UInt8], iv: [UInt8]) -> [UInt8]? {
    guard key.count == 16, iv.count == 16, !data.isEmpty else { return nil }
    var outLength = 0
    var out = [UInt8](repeating: 0, count: data.count + kCCBlockSizeAES128)
    let status = CCCrypt(CCOperation(kCCDecrypt), CCAlgorithm(kCCAlgorithmAES), CCOptions(kCCOptionPKCS7Padding),
                         key, key.count, iv, data, data.count, &out, out.count, &outLength)
    guard status == kCCSuccess else { return nil }
    return Array(out.prefix(outLength))
}
func enc(_ s: String) -> String {
    var a = CharacterSet.alphanumerics; a.insert(charactersIn: "-._~")
    return s.addingPercentEncoding(withAllowedCharacters: a) ?? s
}
func probeYoudao() async {
    // 第 1 步:握手取 secretKey / aes 种子。
    let t1 = String(Int(Date().timeIntervalSince1970 * 1000))
    let keySign = youdaoSign(mysticTime: t1, secret: youdaoDefaultKey)
    var keyComps = URLComponents(string: "https://dict.youdao.com/webtranslate/key")!
    keyComps.queryItems = youdaoGeneralItems(keyid: "webfanyi-key-getter", sign: keySign, mysticTime: t1)
        .map { URLQueryItem(name: $0.0, value: $0.1) }
    var keyReq = URLRequest(url: keyComps.url!); youdaoHeaders(&keyReq)
    var secretKey = "", aesKeySeed = youdaoFallbackKeySeed, aesIvSeed = youdaoFallbackIvSeed
    do {
        let (data, resp) = try await session.data(for: keyReq)
        let code = (resp as? HTTPURLResponse)?.statusCode ?? -1
        guard (200..<300).contains(code),
              let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let d = root["data"] as? [String: Any], let sk = d["secretKey"] as? String, !sk.isEmpty else {
            report("youdao", "key handshake failed (HTTP \(code)) -> engineUnavailable (acceptable)"); return
        }
        secretKey = sk
        aesKeySeed = (d["aesKey"] as? String) ?? aesKeySeed
        aesIvSeed = (d["aesIv"] as? String) ?? aesIvSeed
    } catch { report("youdao", "key network error: \(error.localizedDescription)"); return }

    // 第 2 步:用 secretKey 签名翻译。
    let mysticTime = String(Int(Date().timeIntervalSince1970 * 1000))
    let sign = youdaoSign(mysticTime: mysticTime, secret: secretKey)
    var fields = youdaoGeneralItems(keyid: "webfanyi", sign: sign, mysticTime: mysticTime)
    fields.append(contentsOf: [("i", query), ("from", "en"), ("to", "zh-CHS"), ("dictResult", "false")])
    let body = fields.map { "\(enc($0.0))=\(enc($0.1))" }.joined(separator: "&")
    var req = URLRequest(url: URL(string: "https://dict.youdao.com/webtranslate")!)
    req.httpMethod = "POST"
    req.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
    youdaoHeaders(&req)
    req.httpBody = body.data(using: .utf8)
    do {
        let (data, resp) = try await session.data(for: req)
        let code = (resp as? HTTPURLResponse)?.statusCode ?? -1
        guard (200..<300).contains(code) else {
            report("youdao", "HTTP \(code) -> engineUnavailable (blocked, acceptable)"); return
        }
        let key = md5Bytes(aesKeySeed), iv = md5Bytes(aesIvSeed)
        if let b64 = String(data: data, encoding: .utf8),
           let cipher = base64urlDecode(b64),
           let plain = aesCBCDecrypt(cipher, key: key, iv: iv),
           let json = String(bytes: plain, encoding: .utf8),
           let root = try? JSONSerialization.jsonObject(with: Data(json.utf8)) as? [String: Any],
           let result = root["translateResult"] as? [Any] {
            // translateResult 可能是双层 [[{tgt}]] 或单层 [{tgt}],都要拍平。
            var text = ""
            for el in result {
                if let group = el as? [[String: Any]] {
                    text += group.compactMap { $0["tgt"] as? String }.joined()
                } else if let item = el as? [String: Any], let tgt = item["tgt"] as? String {
                    text += tgt
                }
            }
            report("youdao", "LIVE OK (\(code)) -> \"\(text)\"")
        } else {
            let preview = String(data: data.prefix(120), encoding: .utf8) ?? "<binary>"
            report("youdao", "HTTP \(code) but decrypt/parse failed -> engineUnavailable; body: \(preview)")
        }
    } catch { report("youdao", "network error: \(error.localizedDescription)") }
}

Task {
    await probeGoogle()
    await probeDeepLX()
    await probeYoudao()
    sem.signal()
}
sem.wait()
