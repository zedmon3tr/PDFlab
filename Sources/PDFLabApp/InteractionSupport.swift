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
        var types: [UTType] = [.pdf, .plainText, .text]
        for ext in ["md", "markdown", "docx"] {
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
                guard isEnabled else {
                    isHovering = false
                    return
                }
                isHovering = hovering
                if hovering {
                    NSCursor.pointingHand.push()
                } else {
                    NSCursor.pop()
                }
            }
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
                if hovering {
                    NSCursor.pointingHand.push()
                } else {
                    NSCursor.pop()
                }
            }
    }
}

extension View {
    func hoverHighlight() -> some View {
        modifier(HoverHighlightModifier())
    }
}
