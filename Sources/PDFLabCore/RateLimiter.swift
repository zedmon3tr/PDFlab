import Foundation

/// FIFO limiter whose cancelled waiter is removed instead of leaving a reserved time slot.
public actor RateLimiter {
    private final class CancellationFlag: @unchecked Sendable {
        private let lock = NSLock()
        private var value = false
        func cancel() { lock.lock(); value = true; lock.unlock() }
        var isCancelled: Bool { lock.lock(); defer { lock.unlock() }; return value }
    }
    private enum Lifecycle { case pending, queued, active, cancelled }
    private struct Waiter {
        let id: UUID
        let flag: CancellationFlag
        let continuation: CheckedContinuation<Void, Error>
    }
    private let clock = ContinuousClock()
    private let minInterval: Duration
    private var lastFire: ContinuousClock.Instant?
    private var queue: [Waiter] = []
    private var activeID: UUID?
    private var activeTask: Task<Void, Never>?
    private var lifecycle: [UUID: Lifecycle] = [:]

    public init(minInterval: TimeInterval) {
        self.minInterval = .nanoseconds(Int64(max(0, minInterval) * 1_000_000_000))
    }

    public func waitTurn() async throws {
        let id = UUID()
        let flag = CancellationFlag()
        lifecycle[id] = .pending
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                enqueue(id: id, flag: flag, continuation: continuation)
            }
        } onCancel: {
            flag.cancel() // synchronous: closes the deadline-vs-actor-hop race
            Task { await self.cancel(id: id) }
        }
        // Cancellation can race with a deadline completion. Even if the continuation won,
        // a caller whose task is already cancelled must not observe a successful turn.
        try Task.checkCancellation()
    }

    private func enqueue(id: UUID, flag: CancellationFlag, continuation: CheckedContinuation<Void, Error>) {
        guard let state = lifecycle[id] else {
            continuation.resume(throwing: CancellationError())
            return
        }
        if state == .cancelled || flag.isCancelled {
            lifecycle.removeValue(forKey: id)
            continuation.resume(throwing: CancellationError())
            return
        }
        lifecycle[id] = .queued
        queue.append(Waiter(id: id, flag: flag, continuation: continuation))
        startNextIfNeeded()
    }

    private func cancel(id: UUID) {
        guard let state = lifecycle[id] else { return } // completed or otherwise retired
        switch state {
        case .pending:
            lifecycle[id] = .cancelled
        case .queued:
            guard let index = queue.firstIndex(where: { $0.id == id }) else { return }
            queue.remove(at: index).continuation.resume(throwing: CancellationError())
            lifecycle.removeValue(forKey: id)
        case .active:
            activeTask?.cancel()
        case .cancelled:
            break
        }
    }

    private func startNextIfNeeded() {
        guard activeID == nil, !queue.isEmpty else { return }
        let waiter = queue.removeFirst()
        activeID = waiter.id
        lifecycle[waiter.id] = .active
        let deadline = max(clock.now, lastFire?.advanced(by: minInterval) ?? clock.now)
        activeTask = Task {
            do {
                try await clock.sleep(until: deadline)
                guard !waiter.flag.isCancelled else { throw CancellationError() }
                complete(waiter, succeeded: true)
            } catch {
                complete(waiter, succeeded: false)
            }
        }
    }

    private func complete(_ waiter: Waiter, succeeded: Bool) {
        guard activeID == waiter.id else { return }
        activeID = nil; activeTask = nil
        lifecycle.removeValue(forKey: waiter.id)
        if succeeded {
            lastFire = clock.now
            waiter.continuation.resume()
        } else {
            waiter.continuation.resume(throwing: CancellationError())
        }
        startNextIfNeeded()
    }

#if DEBUG
    func debugLifecycleCount() -> Int { lifecycle.count }
#endif
}
