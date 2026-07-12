import Foundation

public struct TranslationRetryPolicy: Sendable {
    public typealias Sleeper = @Sendable (UInt64) async throws -> Void

    public let maxRetries: Int
    private let baseDelayNanoseconds: UInt64
    private let jitter: @Sendable (UInt64) -> UInt64
    private let sleeper: Sleeper

    public init(
        maxRetries: Int = 2,
        baseDelayNanoseconds: UInt64 = 400_000_000,
        jitter: @escaping @Sendable (UInt64) -> UInt64 = { upperBound in
            upperBound == 0 ? 0 : UInt64.random(in: 0...upperBound)
        },
        sleeper: @escaping Sleeper = { try await Task.sleep(nanoseconds: $0) }
    ) {
        self.maxRetries = max(0, maxRetries)
        self.baseDelayNanoseconds = baseDelayNanoseconds
        self.jitter = jitter
        self.sleeper = sleeper
    }

    public static let immediate = TranslationRetryPolicy(
        maxRetries: 2,
        baseDelayNanoseconds: 0,
        jitter: { _ in 0 },
        sleeper: { _ in }
    )

    func wait(beforeRetry retry: Int) async throws {
        let shift = min(max(0, retry), 20)
        let exponential = baseDelayNanoseconds.multipliedReportingOverflow(by: UInt64(1 << shift))
        let base = exponential.overflow ? UInt64.max / 2 : exponential.partialValue
        let jitterCeiling = base / 2
        let extra = jitter(jitterCeiling)
        let total = base.addingReportingOverflow(extra)
        try await sleeper(total.overflow ? UInt64.max : total.partialValue)
    }
}
