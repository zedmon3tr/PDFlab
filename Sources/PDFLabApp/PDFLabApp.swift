import SwiftUI
import PDFLabCore

@main
struct PDFLabApp: App {
    @StateObject private var appState = AppState()

    var body: some Scene {
        WindowGroup {
            MainView()
                .environmentObject(appState)
                .frame(minWidth: 900, minHeight: 600)
                // macOS 15 Apple 本地翻译宿主:常驻挂载,供 AppleLocalEngine 的
                // legacyRunner 执行 .translationTask 会话。
                .background(AppleTranslationHost.shared.view)
                .onAppear { appState.applyAppearance() }
        }
        .defaultSize(width: 960, height: 680)

        Settings {
            SettingsView()
                .environmentObject(appState)
        }
    }
}
