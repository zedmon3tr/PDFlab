import AppKit
import SwiftUI

@MainActor
final class AppWindowRegistry {
    static let shared = AppWindowRegistry()

    private weak var mainWindow: NSWindow?

    private init() {}

    func registerMainWindow(_ window: NSWindow?) {
        guard let window else { return }
        mainWindow = window
    }

    func centerUtilityWindow(_ window: NSWindow) {
        guard let parent = mainWindow, parent !== window, parent.isVisible else {
            window.center()
            return
        }

        let parentFrame = parent.frame
        let childSize = window.frame.size
        let origin = NSPoint(
            x: parentFrame.midX - childSize.width / 2,
            y: parentFrame.midY - childSize.height / 2
        )
        let visibleFrame = parent.screen?.visibleFrame ?? NSScreen.main?.visibleFrame
        window.setFrameOrigin(origin.clamped(for: childSize, in: visibleFrame))
    }
}

struct CenteredUtilityWindow: NSViewRepresentable {
    func makeCoordinator() -> Coordinator {
        Coordinator()
    }

    func makeNSView(context: Context) -> NSView {
        let view = NSView()
        DispatchQueue.main.async {
            context.coordinator.centerIfNeeded(window: view.window)
        }
        return view
    }

    func updateNSView(_ nsView: NSView, context: Context) {
        DispatchQueue.main.async {
            context.coordinator.centerIfNeeded(window: nsView.window)
        }
    }

    final class Coordinator {
        private weak var centeredWindow: NSWindow?

        @MainActor
        func centerIfNeeded(window: NSWindow?) {
            guard let window, centeredWindow !== window else { return }
            centeredWindow = window
            AppWindowRegistry.shared.centerUtilityWindow(window)
        }
    }
}

private extension NSPoint {
    func clamped(for size: NSSize, in visibleFrame: NSRect?) -> NSPoint {
        guard let visibleFrame else { return self }

        return NSPoint(
            x: min(max(x, visibleFrame.minX), visibleFrame.maxX - size.width),
            y: min(max(y, visibleFrame.minY), visibleFrame.maxY - size.height)
        )
    }
}
