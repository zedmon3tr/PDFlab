import SwiftUI
import PDFLabCore
#if DEBUG
import AppKit
#endif

@main
struct PDFLabApp: App {
    @StateObject private var appState = AppState()
    @NSApplicationDelegateAdaptor(TranslationTerminationBridge.self) private var terminationBridge

    init() {
        // 开发运行时把通用可执行图标换成真实 logo(标题栏按钮读 NSApp.applicationIconImage)。
        AppIconResource.install()
    }

    var body: some Scene {
        WindowGroup {
            MainView()
                .environmentObject(appState)
                .frame(minWidth: 900, minHeight: 600)
                // macOS 15 Apple 本地翻译宿主:常驻挂载,供 AppleLocalEngine 的
                // legacyRunner 执行 .translationTask 会话。
                .background(translationHostBackground)
                .onAppear {
                    appState.applyAppearance()
                    TranslationTerminationBridge.owner = appState
                }
        }
        .defaultSize(width: 960, height: 680)
        // 设置不再使用 `Settings` 独立窗口场景(关窗会腐蚀主窗口工具栏按钮状态,
        // 见 product-spec-changelog.md 2026-07-10),改为主窗口 sheet;
        // ⌘, 菜单命令在此接管,与齿轮按钮共用同一呈现状态。
        .commands {
            CommandGroup(replacing: .newItem) {}
            CommandGroup(replacing: .appSettings) {
                Button(L10n.t("settings.menu")) {
                    appState.presentSettingsIfIdle()
                }
                .keyboardShortcut(",", modifiers: .command)
            }
#if DEBUG
            CommandMenu(L10n.t("diagnostics.menu")) {
                Button(L10n.t("diagnostics.open")) {
                    Task {
                        if let directory = await TranslationDiagnostics.prepareDirectory() {
                            NSWorkspace.shared.open(directory)
                        }
                    }
                }
                .disabled(TranslationDiagnostics.logURL == nil)
                Button(L10n.t("diagnostics.clear")) { Task { await TranslationDiagnostics.clear() } }
            }
#endif
        }
    }

    @ViewBuilder
    private var translationHostBackground: some View {
        if #available(macOS 15.0, *) {
            AppleTranslationHost.shared.view
        } else {
            EmptyView()
        }
    }
}
