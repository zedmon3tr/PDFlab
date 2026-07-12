import Foundation

#if DEBUG

public struct TranslationDiagnosticContext: Equatable, Sendable {
    public let runID: UUID
    public let batch: Int?
    public let pageStart: Int?
    public let pageEnd: Int?
    public init(runID: UUID, batch: Int? = nil, pageStart: Int? = nil, pageEnd: Int? = nil) {
        self.runID = runID; self.batch = batch; self.pageStart = pageStart; self.pageEnd = pageEnd
    }
}

public enum TranslationDiagnosticScope {
    @TaskLocal public static var current: TranslationDiagnosticContext?
}

public struct TranslationDiagnosticEvent: Codable, Equatable, Sendable {
    public let timestamp: Date
    public let runID: UUID
    public let requestID: UUID?
    public let engine: String
    public let stage: String
    public let direction: String
    public let batch: Int?
    public let pageStart: Int?
    public let pageEnd: Int?
    public let characterCount: Int
    public let durationMilliseconds: Int?
    public let httpStatus: Int?
    public let retryCount: Int
    public let errorCategory: String?

    public init(timestamp: Date = Date(), runID: UUID, requestID: UUID? = nil,
                engine: String, stage: String, direction: TranslationDirection,
                batch: Int? = nil, pageStart: Int? = nil, pageEnd: Int? = nil, characterCount: Int,
                durationMilliseconds: Int? = nil, httpStatus: Int? = nil,
                retryCount: Int = 0, errorCategory: String? = nil) {
        self.timestamp = timestamp; self.runID = runID; self.requestID = requestID
        self.engine = engine; self.stage = stage
        self.direction = direction == .enToZh ? "en-zh" : "zh-en"
        self.batch = batch; self.pageStart = pageStart; self.pageEnd = pageEnd; self.characterCount = characterCount
        self.durationMilliseconds = durationMilliseconds; self.httpStatus = httpStatus
        self.retryCount = retryCount; self.errorCategory = errorCategory
    }
}

public protocol TranslationDiagnosticSink: Sendable {
    func record(_ event: TranslationDiagnosticEvent) async
}

enum TranslationDiagnosticLocation {
    static func resolveProjectRoot(
        bundleURL: URL = Bundle.main.bundleURL,
        workingDirectory: URL = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
    ) -> URL? {
        for start in [bundleURL, workingDirectory] {
            var candidate = start.pathExtension == "app" ? start.deletingLastPathComponent() : start
            for _ in 0..<10 {
                if isPDFlabRoot(candidate) { return candidate }
                let parent = candidate.deletingLastPathComponent()
                if parent == candidate { break }
                candidate = parent
            }
        }
        return nil
    }

    private static func isPDFlabRoot(_ candidate: URL) -> Bool {
        let packageURL = candidate.appendingPathComponent("Package.swift")
        guard let package = try? String(contentsOf: packageURL, encoding: .utf8),
              package.contains("name: \"PDFlab\"") else { return false }
        let fileManager = FileManager.default
        return fileManager.fileExists(atPath: candidate.appendingPathComponent("Makefile").path)
            && fileManager.fileExists(atPath: candidate.appendingPathComponent("Sources/PDFLabCore").path)
            && fileManager.fileExists(atPath: candidate.appendingPathComponent("Sources/PDFLabApp").path)
    }
}

public enum TranslationDiagnostics {
    public static let logURL = TranslationDiagnosticLocation.resolveProjectRoot()?
        .appendingPathComponent(".pdflab-dev/translation.jsonl")
    static let fileLog = logURL.map { TranslationDiagnosticFileLog(url: $0) }
    public static let shared: any TranslationDiagnosticSink = {
        if let fileLog { return fileLog }
        return DisabledTranslationDiagnosticSink()
    }()
    public static func clear() async { await fileLog?.clear() }
    public static func prepareDirectory() async -> URL? { await fileLog?.prepareDirectory() }
}

private struct DisabledTranslationDiagnosticSink: TranslationDiagnosticSink {
    func record(_ event: TranslationDiagnosticEvent) async {}
}
actor TranslationDiagnosticFileLog: TranslationDiagnosticSink {
    private let url: URL
    private let maxBytes: Int
    private let maxArchives: Int
    private let encoder: JSONEncoder

    init(url: URL, maxBytes: Int = 5 * 1024 * 1024, maxArchives: Int = 3) {
        self.url = url; self.maxBytes = max(1, maxBytes); self.maxArchives = max(0, maxArchives)
        self.encoder = JSONEncoder(); self.encoder.dateEncodingStrategy = .iso8601
    }

    func prepareDirectory() -> URL {
        let directory = url.deletingLastPathComponent()
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true,
            attributes: [.posixPermissions: 0o700])
        try? FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: directory.path)
        return directory
    }

    func clear() {
        try? FileManager.default.removeItem(at: url)
        guard maxArchives > 0 else { return }
        for index in 1...maxArchives { try? FileManager.default.removeItem(at: archiveURL(index)) }
    }

    func record(_ event: TranslationDiagnosticEvent) async {
        guard var data = try? encoder.encode(event) else { return }
        data.append(0x0A)
        _ = prepareDirectory()
        rotateIfNeeded(adding: data.count)
        if !FileManager.default.fileExists(atPath: url.path) {
            FileManager.default.createFile(atPath: url.path, contents: nil,
                attributes: [.posixPermissions: 0o600])
        }
        do {
            try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
            let handle = try FileHandle(forWritingTo: url)
            try handle.seekToEnd(); try handle.write(contentsOf: data); try handle.close()
        } catch { /* diagnostics must never break translation */ }
    }

    private func rotateIfNeeded(adding bytes: Int) {
        let current = (try? FileManager.default.attributesOfItem(atPath: url.path)[.size] as? NSNumber)?.intValue ?? 0
        guard current + bytes > maxBytes else { return }
        if maxArchives > 0 {
            try? FileManager.default.removeItem(at: archiveURL(maxArchives))
            if maxArchives > 1 {
                for index in stride(from: maxArchives - 1, through: 1, by: -1) {
                    try? FileManager.default.moveItem(at: archiveURL(index), to: archiveURL(index + 1))
                }
            }
            try? FileManager.default.moveItem(at: url, to: archiveURL(1))
        } else { try? FileManager.default.removeItem(at: url) }
    }

    private func archiveURL(_ index: Int) -> URL {
        URL(fileURLWithPath: url.path + ".\(index)")
    }
}
#endif
