import AppKit
import SwiftUI
import UniformTypeIdentifiers
import PDFLabCore

struct MainHistoryState: Equatable {
    var entries: [HistoryEntry] = []

    mutating func reload(history: HistoryStore) {
        entries = history.entries()
    }

    mutating func clear(history: HistoryStore) {
        history.clear()
        entries = []
    }

    mutating func viewerDidOpen(_ url: URL, history: HistoryStore) {
        let currentEntries = history.entries()
        if currentEntries.first?.path == url.path {
            entries = currentEntries
            return
        }

        history.record(url: url)
        reload(history: history)
    }
}

enum ViewerSecondaryDocumentPicker {
    static var allowedContentTypes: [UTType] {
        var types: [UTType] = [.pdf, .plainText]
        for ext in ["md"] {
            if let type = UTType(filenameExtension: ext) {
                types.append(type)
            }
        }
        return types
    }

    @MainActor
    static func pick() -> URL? {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = allowedContentTypes
        panel.allowsMultipleSelection = false
        panel.canChooseFiles = true
        panel.canChooseDirectories = false
        return panel.runModal() == .OK ? panel.url : nil
    }
}

struct HoverButtonStyle: ButtonStyle {
    enum Variant {
        case plain
        case primary
        case danger
        case toolbar
    }

    var variant: Variant = .plain

    func makeBody(configuration: Configuration) -> some View {
        HoverButtonBody(configuration: configuration, variant: variant)
    }
}

private struct HoverButtonBody: View {
    let configuration: ButtonStyle.Configuration
    let variant: HoverButtonStyle.Variant

    @Environment(\.isEnabled) private var isEnabled
    @State private var isHovering = false

    var body: some View {
        configuration.label
            .font(.callout.weight(variant == .toolbar ? .regular : .medium))
            .foregroundStyle(foreground)
            .padding(.horizontal, horizontalPadding)
            .padding(.vertical, verticalPadding)
            .background(background, in: RoundedRectangle(cornerRadius: 7))
            .overlay(
                RoundedRectangle(cornerRadius: 7)
                    .strokeBorder(stroke, lineWidth: 1)
            )
            .scaleEffect(configuration.isPressed ? 0.98 : 1)
            .opacity(isEnabled ? (configuration.isPressed ? 0.82 : 1) : 0.46)
            .animation(.easeOut(duration: 0.12), value: isHovering)
            .animation(.easeOut(duration: 0.08), value: configuration.isPressed)
            .onHover { hovering in
                isHovering = isEnabled && hovering
            }
            .clickableHoverCursor(enabled: isEnabled)
    }

    private var horizontalPadding: CGFloat {
        variant == .toolbar ? 8 : 12
    }

    private var verticalPadding: CGFloat {
        variant == .toolbar ? 5 : 7
    }

    private var foreground: AnyShapeStyle {
        guard isEnabled else { return AnyShapeStyle(.secondary) }
        switch variant {
        case .primary:
            return AnyShapeStyle(.white)
        case .danger:
            return AnyShapeStyle(isHovering ? .red : .primary)
        case .plain, .toolbar:
            return AnyShapeStyle(.primary)
        }
    }

    private var background: Color {
        guard isEnabled else { return Color.primary.opacity(0.02) }
        switch variant {
        case .primary:
            return Color.accentColor.opacity(isHovering ? 0.92 : 0.82)
        case .danger:
            return Color.red.opacity(isHovering ? 0.12 : 0.05)
        case .plain, .toolbar:
            return Color.primary.opacity(isHovering ? 0.08 : 0.035)
        }
    }

    private var stroke: Color {
        guard isEnabled else { return Color.primary.opacity(0.06) }
        switch variant {
        case .primary:
            return Color.accentColor.opacity(isHovering ? 0.55 : 0.25)
        case .danger:
            return Color.red.opacity(isHovering ? 0.35 : 0.16)
        case .plain, .toolbar:
            return Color.primary.opacity(isHovering ? 0.16 : 0.08)
        }
    }
}

struct HoverHighlightModifier: ViewModifier {
    @State private var isHovering = false

    func body(content: Content) -> some View {
        content
            .background(
                RoundedRectangle(cornerRadius: 8)
                    .fill(Color.primary.opacity(isHovering ? 0.07 : 0.0))
            )
            .overlay(
                RoundedRectangle(cornerRadius: 8)
                    .strokeBorder(Color.primary.opacity(isHovering ? 0.12 : 0.0), lineWidth: 1)
            )
            .animation(.easeOut(duration: 0.12), value: isHovering)
            .onHover { hovering in
                isHovering = hovering
            }
            .onDisappear { isHovering = false }
            .clickableHoverCursor()
    }
}

extension View {
    func hoverHighlight() -> some View {
        modifier(HoverHighlightModifier())
    }

    /// 可点击区域的悬停光标。
    /// macOS 15+ 走 SwiftUI 原生 `pointerStyle`——按视图作用域自动管理,离开即恢复,
    /// 不碰进程级 NSCursor 栈,因此不会出现 push/pop 失衡导致别处(如工具栏设置按钮)
    /// 光标卡住的老问题。macOS 14 回退到 push/pop,但用 didPush 守卫 + onDisappear/禁用
    /// 兜底,保证每次 push 都有且仅有一次配对 pop。
    @ViewBuilder
    func clickableHoverCursor(enabled: Bool = true) -> some View {
        if #available(macOS 15.0, *) {
            pointerStyle(enabled ? .link : nil)
        } else {
            modifier(LegacyHoverCursor(enabled: enabled))
        }
    }
}

/// macOS 14 兜底:配平的 NSCursor push/pop。
private struct LegacyHoverCursor: ViewModifier {
    let enabled: Bool
    @State private var didPush = false

    func body(content: Content) -> some View {
        content
            .onHover { hovering in
                if hovering && enabled {
                    guard !didPush else { return }
                    NSCursor.pointingHand.push()
                    didPush = true
                } else {
                    popIfNeeded()
                }
            }
            .onChange(of: enabled) { _, newValue in
                if !newValue { popIfNeeded() }
            }
            .onDisappear { popIfNeeded() }
    }

    private func popIfNeeded() {
        guard didPush else { return }
        NSCursor.pop()
        didPush = false
    }
}
