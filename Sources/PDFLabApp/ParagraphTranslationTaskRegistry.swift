import Foundation

final class ParagraphTranslationTaskRegistry: @unchecked Sendable {
    private var tasks: [UUID: Task<Void, Never>] = [:]

    var count: Int {
        tasks.count
    }

    func insert(_ task: Task<Void, Never>, for id: UUID) {
        tasks[id]?.cancel()
        tasks[id] = task
    }

    func remove(_ id: UUID) {
        tasks.removeValue(forKey: id)
    }

    func cancelAll() {
        for task in tasks.values {
            task.cancel()
        }
        tasks.removeAll()
    }

    deinit {
        cancelAll()
    }
}
