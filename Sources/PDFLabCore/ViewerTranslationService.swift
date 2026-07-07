/// 查看器即时翻译共用服务:引擎跟随全局设置 + LRU 缓存 + 方向检测。
///
/// 后续任务(划选气泡翻译、点选段译、整页翻译)都通过本服务调用翻译引擎,
/// 不直接持有/调用 `TranslationEngine`,以获得统一的缓存与并发合并语义。
public actor ViewerTranslationService {
    /// 缓存 key:文本 + 翻译方向 + 引擎 id。三者缺一都可能导致跨方向/跨引擎误命中。
    private struct CacheKey: Hashable {
        let text: String
        let direction: TranslationDirection
        let engineID: String
    }

    private let engineProvider: @Sendable () -> TranslationEngine
    private let cacheLimit: Int

    /// LRU 存储。`recencyOrder` 从最久未用到最近使用排列,命中/写入都会把 key 移到末尾。
    private var cache: [CacheKey: String] = [:]
    private var recencyOrder: [CacheKey] = []

    /// 同一 key 正在进行中的引擎调用;用于合并并发/连续重复请求。
    private var inFlight: [CacheKey: Task<String, Error>] = [:]

    /// - Parameters:
    ///   - engineProvider: 每次调用取当前引擎(跟随设置切换,不缓存实例)。
    ///   - cacheLimit: LRU 上限,默认 500。
    public init(engineProvider: @escaping @Sendable () -> TranslationEngine, cacheLimit: Int = 500) {
        self.engineProvider = engineProvider
        self.cacheLimit = cacheLimit
    }

    /// 翻译一段文本:用 `LanguageDetector` 判定方向(zh→en / en→zh)。
    /// 非中英文档(检测不出方向)抛 `PDFLabError.unsupportedLanguage`。
    public func translate(_ text: String) async throws -> (text: String, direction: TranslationDirection) {
        guard let direction = LanguageDetector.detectDirection(sample: text) else {
            throw PDFLabError.unsupportedLanguage(detected: LanguageDetector.detectedLanguageName(sample: text))
        }
        let translated = try await translate(text, direction: direction)
        return (translated, direction)
    }

    /// 批量翻译(整页翻译用):逐段复用同一缓存与 in-flight 合并逻辑;顺序与输入一致。
    /// 每段开始前检查取消:用户取消整页翻译后,不再对剩余段发出新的引擎请求。
    public func translateBatch(_ texts: [String], direction: TranslationDirection) async throws -> [String] {
        var results: [String] = []
        results.reserveCapacity(texts.count)
        for text in texts {
            try Task.checkCancellation()
            results.append(try await translate(text, direction: direction))
        }
        return results
    }

    /// 显式指定方向的单段翻译(扫描页等已知方向场景)。
    /// 命中缓存直接返回;未命中时合并同 key 的并发/连续请求为一次引擎调用。
    /// 引擎抛出的错误原样透传,失败的请求不会残留在缓存或 in-flight 表里(可重试)。
    public func translate(_ text: String, direction: TranslationDirection) async throws -> String {
        let engine = engineProvider()
        let key = CacheKey(text: text, direction: direction, engineID: engine.id)

        if let cached = cache[key] {
            touch(key)
            return cached
        }

        if let existing = inFlight[key] {
            // 取消可能发生在排队等待既有 in-flight 请求之前;此时不应挂上去等一个我们已不关心的结果。
            try Task.checkCancellation()
            return try await existing.value
        }

        let task = Task<String, Error> {
            let results = try await engine.translate([text], direction: direction)
            guard let first = results.first else {
                // 引擎异常返回空数组:不得把空串当作合法译文写入缓存,视为该引擎不可用。
                throw PDFLabError.engineUnavailable(engineID: engine.id)
            }
            return first
        }
        inFlight[key] = task

        do {
            let result = try await task.value
            inFlight[key] = nil
            store(key, value: result)
            return result
        } catch {
            inFlight[key] = nil
            throw error
        }
    }

    // MARK: - LRU 内部实现

    private func touch(_ key: CacheKey) {
        if let idx = recencyOrder.firstIndex(of: key) {
            recencyOrder.remove(at: idx)
        }
        recencyOrder.append(key)
    }

    private func store(_ key: CacheKey, value: String) {
        touch(key)
        cache[key] = value
        while cache.count > cacheLimit, !recencyOrder.isEmpty {
            let oldest = recencyOrder.removeFirst()
            cache.removeValue(forKey: oldest)
        }
    }
}
