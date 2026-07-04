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
    private let lock = NSLock()

    public init(defaults: UserDefaults = .standard, maxEntries: Int = 20) {
        self.defaults = defaults
        self.maxEntries = maxEntries
    }

    /// Records a file open, deduping by path (moves to front, updates openedAt),
    /// and caps the list at maxEntries, dropping the oldest entries.
    public func record(url: URL) {
        lock.lock()
        defer { lock.unlock() }

        let path = url.path
        var current = loadEntries()
        current.removeAll { $0.path == path }

        let entry = HistoryEntry(path: path, fileName: url.lastPathComponent, openedAt: Date())
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
        return loadEntries()
    }

    /// Removes the entry matching the given path, if any.
    public func remove(path: String) {
        lock.lock()
        defer { lock.unlock() }

        var current = loadEntries()
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

    private func saveEntries(_ entries: [HistoryEntry]) {
        guard let data = try? JSONEncoder().encode(entries) else { return }
        defaults.set(data, forKey: Self.storageKey)
    }
}
