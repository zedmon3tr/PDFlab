import Foundation

/// A single entry in the file-open history.
public struct HistoryEntry: Codable, Equatable, Sendable {
    public var path: String
    public var fileName: String
    public var openedAt: Date

    public init(path: String, fileName: String, openedAt: Date) {
        self.path = path
        self.fileName = fileName
        self.openedAt = openedAt
    }
}

/// Persists a bounded, newest-first, deduped history of opened files in UserDefaults.
public final class HistoryStore: @unchecked Sendable {
    private static let storageKey = "pdflab.history"

    private let defaults: UserDefaults
    private let maxEntries: Int
    private let retentionDays: Int
    private let now: @Sendable () -> Date
    private let lock = NSLock()

    public init(
        defaults: UserDefaults = .standard,
        maxEntries: Int = 20,
        retentionDays: Int = 30,
        now: @escaping @Sendable () -> Date = { Date() }
    ) {
        self.defaults = defaults
        self.maxEntries = maxEntries
        self.retentionDays = retentionDays
        self.now = now
    }

    /// Records a file open, deduping by path (moves to front, updates openedAt),
    /// pruning old entries, and capping the list at maxEntries.
    public func record(url: URL) {
        lock.lock()
        defer { lock.unlock() }

        let path = url.path
        let openedAt = now()
        var current = pruneExpired(loadEntries(), relativeTo: openedAt)
        current.removeAll { $0.path == path }

        let entry = HistoryEntry(path: path, fileName: url.lastPathComponent, openedAt: openedAt)
        current.insert(entry, at: 0)

        if current.count > maxEntries {
            current = Array(current.prefix(maxEntries))
        }

        saveEntries(current)
    }

    /// Returns all history entries, newest first.
    public func entries() -> [HistoryEntry] {
        lock.lock()
        defer { lock.unlock() }
        let loaded = loadEntries()
        let pruned = pruneExpired(loaded, relativeTo: now())
        if pruned != loaded {
            saveEntries(pruned)
        }
        return pruned
    }

    /// Removes the entry matching the given path, if any.
    public func remove(path: String) {
        lock.lock()
        defer { lock.unlock() }

        var current = pruneExpired(loadEntries(), relativeTo: now())
        current.removeAll { $0.path == path }
        saveEntries(current)
    }

    /// Removes all history entries.
    public func clear() {
        lock.lock()
        defer { lock.unlock() }
        defaults.removeObject(forKey: Self.storageKey)
    }

    private func loadEntries() -> [HistoryEntry] {
        guard let data = defaults.data(forKey: Self.storageKey) else { return [] }
        guard let decoded = try? JSONDecoder().decode([HistoryEntry].self, from: data) else { return [] }
        return decoded
    }

    private func pruneExpired(_ entries: [HistoryEntry], relativeTo referenceDate: Date) -> [HistoryEntry] {
        let retentionInterval = TimeInterval(max(retentionDays, 0)) * 24 * 60 * 60
        let cutoff = referenceDate.addingTimeInterval(-retentionInterval)
        return entries.filter { $0.openedAt >= cutoff }
    }

    private func saveEntries(_ entries: [HistoryEntry]) {
        guard let data = try? JSONEncoder().encode(entries) else { return }
        defaults.set(data, forKey: Self.storageKey)
    }
}
