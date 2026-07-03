#!/usr/bin/env swift
// Manual live-endpoint probe for the free translation engines (Task 10).
// Standalone script: mirrors the exact request SHAPE built by GoogleFreeEngine,
// DeepLXEngine and YoudaoFreeEngine, then calls each real endpoint once with
// "Hello world" (EN->ZH) and prints the outcome.
//
// Run:  DEVELOPER_DIR=/Library/Developer/CommandLineTools swift scripts/probe_engines.swift
//
// DeepLX/Youdao are expected to possibly fail (blocked / signature or payload
// drift); that is acceptable per the brief — the point is to confirm the request
// shape and document real status. Only Google is required to succeed.

import Foundation
import CryptoKit

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

// MARK: Youdao
func youdaoSign(query: String, salt: String, time: String) -> String {
    let raw = "fanyideskweb" + query + salt + time + "Ygy_4c=r#e#4EX^NUGUc5"
    return Insecure.MD5.hash(data: Data(raw.utf8)).map { String(format: "%02x", $0) }.joined()
}
func probeYoudao() async {
    let time = String(Int(Date().timeIntervalSince1970 * 1000))
    let salt = time + String(Int.random(in: 0...9))
    let sign = youdaoSign(query: query, salt: salt, time: time)
    func enc(_ s: String) -> String {
        var a = CharacterSet.alphanumerics; a.insert(charactersIn: "-._~")
        return s.addingPercentEncoding(withAllowedCharacters: a) ?? s
    }
    let fields: [(String, String)] = [
        ("i", query), ("from", "en"), ("to", "zh-CHS"), ("dictResult", "true"),
        ("keyid", "webfanyi"), ("client", "fanyideskweb"), ("product", "webfanyi"),
        ("appVersion", "1.0.0"), ("vendor", "web"), ("pointParam", "client,mysticTime,product"),
        ("mysticTime", time), ("keyfrom", "fanyi.web"), ("salt", salt), ("sign", sign),
    ]
    let body = fields.map { "\(enc($0.0))=\(enc($0.1))" }.joined(separator: "&")
    var req = URLRequest(url: URL(string: "https://dict.youdao.com/webtranslate")!)
    req.httpMethod = "POST"
    req.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
    req.httpBody = body.data(using: .utf8)
    do {
        let (data, resp) = try await session.data(for: req)
        let code = (resp as? HTTPURLResponse)?.statusCode ?? -1
        guard (200..<300).contains(code) else {
            report("youdao", "HTTP \(code) -> engineUnavailable (blocked, acceptable)"); return
        }
        if let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
           let groups = root["translateResult"] as? [[[String: Any]]] {
            let text = groups.flatMap { $0 }.compactMap { $0["tgt"] as? String }.joined()
            report("youdao", "LIVE OK (\(code)) -> \"\(text)\"")
        } else {
            let preview = String(data: data.prefix(80), encoding: .utf8) ?? "<binary>"
            report("youdao", "HTTP \(code) but unparseable (likely encrypted) -> engineUnavailable; body: \(preview)")
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
