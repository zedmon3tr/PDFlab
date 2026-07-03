import Foundation
public actor RateLimiter {
    private let minInterval: TimeInterval
    private var lastFire: Date = .distantPast
    public init(minInterval: TimeInterval) { self.minInterval = minInterval }
    public func waitTurn() async {
        let wait = minInterval - Date().timeIntervalSince(lastFire)
        if wait > 0 { try? await Task.sleep(nanoseconds: UInt64(wait * 1e9)) }
        lastFire = Date()
    }
}
