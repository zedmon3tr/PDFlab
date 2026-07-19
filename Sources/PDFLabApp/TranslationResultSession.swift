import Foundation
import PDFLabCore

/// A completed translation remains a session object until it is explicitly saved or discarded.
struct TranslationArtifact: Equatable {
    let id: UUID
    let sourceURL: URL
    let composed: ComposedDocument
    let options: ExportOptions
    var temporaryPDFURL: URL?
    var savedURL: URL?
    var isDirty: Bool

    init(sourceURL: URL, composed: ComposedDocument, options: ExportOptions) {
        id = UUID()
        self.sourceURL = sourceURL
        self.composed = composed
        self.options = options
        temporaryPDFURL = nil
        savedURL = nil
        isDirty = true
    }
}

enum TranslationLossAction: CaseIterable {
    case closeTab, closeSheet, startTranslation
}

enum TranslationTempStore {
    private static let directoryName = "com.pdflab.translation-results"
    static var directory: URL { FileManager.default.temporaryDirectory.appendingPathComponent(directoryName, isDirectory: true) }

    static func reserveURL() throws -> URL {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        return directory.appendingPathComponent("translation-\(UUID().uuidString).pdf")
    }

    static func remove(_ url: URL?) {
        guard let url, url.deletingLastPathComponent() == directory else { return }
        try? FileManager.default.removeItem(at: url)
    }

    static func sweep() {
        guard let urls = try? FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil) else { return }
        for url in urls where url.lastPathComponent.hasPrefix("translation-") && url.pathExtension == "pdf" {
            try? FileManager.default.removeItem(at: url)
        }
    }
}

enum UnsavedTranslationPolicy {
    static func requiresConfirmation(isDirty: Bool, action: TranslationLossAction) -> Bool { isDirty }
}

@MainActor
final class TranslationResultController: ObservableObject {
    @Published private(set) var artifact: TranslationArtifact?

    var hasUnsavedArtifact: Bool { artifact?.isDirty == true }

    func install(composed: ComposedDocument, sourceURL: URL, options: ExportOptions) {
        // A new run is only admitted after unsaved protection has been resolved.
        // Its former internal viewer file never becomes a user export, so reclaim it.
        TranslationTempStore.remove(artifact?.temporaryPDFURL)
        artifact = TranslationArtifact(sourceURL: sourceURL, composed: composed, options: options)
    }

    func setTemporaryPDFURL(_ url: URL) {
        artifact?.temporaryPDFURL = url
    }

    func setTemporaryPDFURLForTesting(_ url: URL) { setTemporaryPDFURL(url) }

    func markSaved(to url: URL) {
        artifact?.savedURL = url
        artifact?.isDirty = false
    }

    func discard() {
        TranslationTempStore.remove(artifact?.temporaryPDFURL)
        artifact = nil
    }

    func cleanUpTemporaryPDFs() {
        discard()
        TranslationTempStore.sweep()
    }

    nonisolated static func comparisonDocument(from document: ComposedDocument) -> ComposedDocument {
        // Extraction-only documents have no translated blocks; preserving their source content
        // makes the internal comparison PDF useful instead of blank.
        let hasTranslation = document.blocks.contains { block in
            if case .translatedText = block { return true }
            if case let .tableRegion(table) = block { return !table.translatedRows.isEmpty }
            return false
        }
        guard hasTranslation else { return document }
        return ComposedDocument(blocks: document.blocks.compactMap { block in
            switch block {
            case .pageBreak:
                return block
            case .translatedText:
                return block
            case .sourceText:
                return nil
            case .tableRegion(var table):
                table.content = .translationOnly
                return .tableRegion(table)
            }
        }, direction: document.direction)
    }
}
