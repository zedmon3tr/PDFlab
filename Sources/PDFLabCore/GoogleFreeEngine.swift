import Foundation

public struct GoogleFreeEngine: TranslationEngine {
    public let id = "google", isUnofficial = true, perRequestCharLimit = 5000
    private let client: HTTPClient
    private let limiter: RateLimiter
    public init(client: HTTPClient = URLSession.shared, limiter: RateLimiter = RateLimiter(minInterval: 0.5)) {
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

    private func translateChunk(_ q: String, direction: TranslationDirection) async throws -> String {
        let tl = direction == .enToZh ? "zh-CN" : "en"
        var comps = URLComponents(string: "https://translate.googleapis.com/translate_a/single")!
        comps.queryItems = [.init(name: "client", value: "gtx"), .init(name: "sl", value: "auto"),
                            .init(name: "tl", value: tl), .init(name: "dt", value: "t"), .init(name: "q", value: q)]
        let (data, resp): (Data, URLResponse)
        do { (data, resp) = try await client.data(for: URLRequest(url: comps.url!)) }
        catch { throw PDFLabError.networkError(error.localizedDescription) }
        guard let http = resp as? HTTPURLResponse else { throw PDFLabError.engineUnavailable(engineID: id) }
        if http.statusCode == 429 { throw PDFLabError.engineRateLimited }
        guard (200..<300).contains(http.statusCode) else { throw PDFLabError.engineUnavailable(engineID: id) }
        guard let root = try? JSONSerialization.jsonObject(with: data) as? [Any],
              let sentences = root.first as? [[Any]] else { throw PDFLabError.engineUnavailable(engineID: id) }
        return sentences.compactMap { $0.first as? String }.joined()
    }
}
