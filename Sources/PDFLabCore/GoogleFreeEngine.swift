import Foundation

public struct GoogleFreeEngine: TranslationEngine {
    public let id = "google", isUnofficial = true, perRequestCharLimit = 5000
    private let client: HTTPClient
    private let limiter: RateLimiter
    private let retryPolicy: TranslationRetryPolicy
#if DEBUG
    private let diagnostics: any TranslationDiagnosticSink
#endif

#if DEBUG
    public init(client: HTTPClient = URLSession.shared,
                limiter: RateLimiter = RateLimiter(minInterval: 0.75),
                retryPolicy: TranslationRetryPolicy = TranslationRetryPolicy(),
                diagnostics: any TranslationDiagnosticSink = TranslationDiagnostics.shared) {
        self.client = client; self.limiter = limiter; self.retryPolicy = retryPolicy; self.diagnostics = diagnostics
    }
#else
    public init(client: HTTPClient = URLSession.shared,
                limiter: RateLimiter = RateLimiter(minInterval: 0.75),
                retryPolicy: TranslationRetryPolicy = TranslationRetryPolicy()) {
        self.client = client; self.limiter = limiter; self.retryPolicy = retryPolicy
    }
#endif

    public func translate(_ texts: [String], direction: TranslationDirection) async throws -> [String] {
#if DEBUG
        let context = TranslationDiagnosticScope.current ?? .init(runID: UUID())
#endif
        var results: [String] = []
        for text in texts {
            var translated = ""
            for chunk in TextChunker.split(text, limit: perRequestCharLimit) {
#if DEBUG
                translated += try await TranslationDiagnosticScope.$current.withValue(context) {
                    try await translateChunk(chunk, direction: direction)
                }
#else
                translated += try await translateChunk(chunk, direction: direction)
#endif
            }
            results.append(translated)
        }
        return results
    }

    private func translateChunk(_ q: String, direction: TranslationDirection) async throws -> String {
#if DEBUG
        let context = TranslationDiagnosticScope.current!
#endif
        let tl = direction == .enToZh ? "zh-CN" : "en"
        var comps = URLComponents(string: "https://translate.google.com/translate_a/single")!
        comps.queryItems = [.init(name: "client", value: "gtx"), .init(name: "sl", value: "auto"),
                            .init(name: "tl", value: tl), .init(name: "dt", value: "t"),
                            .init(name: "dj", value: "1"), .init(name: "ie", value: "UTF-8"),
                            .init(name: "q", value: q)]
        var request = URLRequest(url: comps.url!)
        request.setValue("Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/537.36 Chrome/124 Safari/537.36", forHTTPHeaderField: "User-Agent")

        for attempt in 0...retryPolicy.maxRetries {
#if DEBUG
            let requestID = UUID(), started = Date()
            var outcomeRecorded = false
#endif
            do {
                try await limiter.waitTurn()
                let (data, response) = try await client.data(for: request)
                guard let http = response as? HTTPURLResponse else {
#if DEBUG
                    outcomeRecorded = true
                    await record(context, requestID, direction, q.count, started, nil, attempt, "invalid-response")
#endif
                    throw PDFLabError.engineUnavailable(engineID: id)
                }
                if http.statusCode == 429 || (500...599).contains(http.statusCode) {
                    let canRetry = attempt < retryPolicy.maxRetries
#if DEBUG
                    outcomeRecorded = true
                    await record(context, requestID, direction, q.count, started, http.statusCode, attempt,
                                 canRetry ? "recoverable-http" : (http.statusCode == 429 ? "rate-limited" : "recoverable-http-exhausted"))
#endif
                    if canRetry { try await retryPolicy.wait(beforeRetry: attempt); continue }
                    throw http.statusCode == 429 ? PDFLabError.engineRateLimited : PDFLabError.engineUnavailable(engineID: id)
                }
                guard (200..<300).contains(http.statusCode) else {
#if DEBUG
                    outcomeRecorded = true
                    await record(context, requestID, direction, q.count, started, http.statusCode, attempt, "permanent-http")
#endif
                    throw PDFLabError.engineUnavailable(engineID: id)
                }
                do {
                    let translated = try Self.parseResponse(data)
#if DEBUG
                    outcomeRecorded = true
                    await record(context, requestID, direction, q.count, started, http.statusCode, attempt, nil)
#endif
                    return translated
                } catch {
#if DEBUG
                    outcomeRecorded = true
                    await record(context, requestID, direction, q.count, started, http.statusCode, attempt, "parse")
#endif
                    throw error
                }
            } catch let error as PDFLabError {
                throw error
            } catch is CancellationError {
#if DEBUG
                if !outcomeRecorded {
                    await record(context, requestID, direction, q.count, started, nil, attempt, "cancelled")
                }
#endif
                throw CancellationError()
            } catch let error as URLError where error.code == .cancelled {
#if DEBUG
                if !outcomeRecorded {
                    await record(context, requestID, direction, q.count, started, nil, attempt, "cancelled")
                }
#endif
                throw CancellationError()
            } catch {
                let canRetry = attempt < retryPolicy.maxRetries
#if DEBUG
                outcomeRecorded = true
                await record(context, requestID, direction, q.count, started, nil, attempt,
                             canRetry ? "network" : "network-exhausted")
#endif
                if canRetry { try await retryPolicy.wait(beforeRetry: attempt); continue }
                throw PDFLabError.networkError(error.localizedDescription)
            }
        }
        throw PDFLabError.engineUnavailable(engineID: id)
    }

    static func parseResponse(_ data: Data) throws -> String {
        // 畸形/非 JSON 响应(如被封禁时返回的 HTML 页面)视为永久失败,不冒充瞬时错误重试。
        guard let root = try? JSONSerialization.jsonObject(with: data) else {
            throw PDFLabError.engineUnavailable(engineID: "google")
        }
        if let dict = root as? [String: Any], let sentences = dict["sentences"] as? [[String: Any]] {
            let result = sentences.compactMap { $0["trans"] as? String }.joined()
            if !result.isEmpty { return result }
        }
        if let array = root as? [Any], let sentences = array.first as? [[Any]] {
            let result = sentences.compactMap { $0.first as? String }.joined()
            if !result.isEmpty { return result }
        }
        throw PDFLabError.engineUnavailable(engineID: "google")
    }

#if DEBUG
    private func record(_ context: TranslationDiagnosticContext, _ requestID: UUID,
                        _ direction: TranslationDirection, _ count: Int, _ started: Date,
                        _ status: Int?, _ retry: Int, _ error: String?) async {
        await diagnostics.record(.init(runID: context.runID, requestID: requestID, engine: id, stage: "http",
            direction: direction, batch: context.batch, pageStart: context.pageStart, pageEnd: context.pageEnd, characterCount: count,
            durationMilliseconds: Int(Date().timeIntervalSince(started) * 1000), httpStatus: status,
            retryCount: retry, errorCategory: error))
    }
#endif
}
