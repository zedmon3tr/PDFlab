import AppKit
import UniformTypeIdentifiers
import PDFLabCore

enum TranslationTerminationDecision: Equatable {
    case terminateNow
    case terminateCancel
    case terminateLater
}

@MainActor
final class TranslationTerminationBridge: NSObject, NSApplicationDelegate {
    /// Set by the root App scene, which outlives windows and MainView instances.
    static var owner: AppState?
    private static var awaitingReply = false

    nonisolated static func decision(hasUnsavedArtifact: Bool, choseSave: Bool?, savePanelAccepted: Bool = false) -> TranslationTerminationDecision {
        guard hasUnsavedArtifact else { return .terminateNow }
        guard let choseSave else { return .terminateCancel }
        return choseSave && savePanelAccepted ? .terminateLater : (choseSave ? .terminateCancel : .terminateNow)
    }

    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        guard !Self.awaitingReply, let owner = Self.owner else { return Self.awaitingReply ? .terminateLater : .terminateNow }
        guard let artifact = owner.translationResult.artifact, artifact.isDirty else { return .terminateNow }

        let alert = NSAlert()
        alert.messageText = L10n.t("translation.unsaved.title")
        alert.informativeText = L10n.t("translation.unsaved.message")
        alert.addButton(withTitle: L10n.t("translation.saveAs"))
        alert.addButton(withTitle: L10n.t("translation.discard"))
        let response = alert.runModal()
        if response == .alertSecondButtonReturn {
            owner.translationResult.discard()
            return .terminateNow
        }

        let panel = NSSavePanel()
        panel.allowedContentTypes = [Self.contentType(for: artifact.options.format)]
        panel.canCreateDirectories = true
        let suggested = TranslateFlowState.defaultOutputURL(sourceURL: artifact.sourceURL, format: artifact.options.format)
        panel.directoryURL = suggested.deletingLastPathComponent()
        panel.nameFieldStringValue = suggested.lastPathComponent
        guard panel.runModal() == .OK, let outputURL = panel.url else { return .terminateCancel }

        let artifactID = artifact.id
        Self.awaitingReply = true
        Task {
            do {
                try await Task.detached(priority: .userInitiated) {
                    try TranslateFlowView.performExport(
                        artifact.composed, to: outputURL, sourceURL: artifact.sourceURL,
                        format: artifact.options.format, uiLanguageChinese: L10n.isChinese
                    )
                }.value
                guard owner.translationResult.artifact?.id == artifactID else {
                    Self.finish(reply: false)
                    return
                }
                owner.translationResult.markSaved(to: outputURL)
                Self.finish(reply: true)
            } catch {
                let errorAlert = NSAlert(error: error)
                errorAlert.runModal()
                Self.finish(reply: false)
            }
        }
        return .terminateLater
    }

    func applicationWillTerminate(_ notification: Notification) {
        Self.owner?.translationResult.cleanUpTemporaryPDFs()
    }

    private static func finish(reply: Bool) {
        guard awaitingReply else { return }
        awaitingReply = false
        NSApp.reply(toApplicationShouldTerminate: reply)
    }

    private static func contentType(for format: OutputFormat) -> UTType {
        switch format {
        case .markdown: return UTType(filenameExtension: "md") ?? .plainText
        case .pdf: return .pdf
        case .docx: return UTType(filenameExtension: "docx") ?? .data
        }
    }
}
