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

/// Home 使用 Figma 1:2 的紧凑比例；数值集中在这里，避免三个入口各自漂移。
enum HomeLayout {
    static let horizontalInset: CGFloat = 40
    static let topInset: CGFloat = 22
    static let moduleCardHeight: CGFloat = 64
    static let moduleCardSpacing: CGFloat = 10
    static let moduleIconSize: CGFloat = 32
    /// 900pt 最小窗口：扣除两侧40、两段10、卡片内边距32、icon32与间距8后的单卡文字宽度。
    static let minimumModuleTextWidth: CGFloat = 194
    static let historyRowHeight: CGFloat = 40
    static let historyOpenedColumnWidth: CGFloat = 120
    static let historySizeColumnWidth: CGFloat = 90
}

enum HomeModulePresentation {
    static func fitsCompactSingleLine(
        _ text: String,
        availableWidth: CGFloat = HomeLayout.minimumModuleTextWidth
    ) -> Bool {
        let font = NSFont.systemFont(ofSize: NSFont.systemFontSize(for: .small), weight: .regular)
        let measured = (text as NSString).size(withAttributes: [.font: font]).width
        return measured <= availableWidth
    }
}

enum HomeHistoryPresentation {
    static let showsLeadingIcon = false

    static func formatOpenedAt(_ date: Date, timeZone: TimeZone = .current) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = timeZone
        formatter.dateFormat = "yyyy-MM-dd HH:mm"
        return formatter.string(from: date)
    }
}

enum HomeToolbarAction: Equatable {
    case none
    case returnHome
}

enum HomeToolbarPolicy {
    static func logoAction(hasNavigationPath: Bool) -> HomeToolbarAction {
        hasNavigationPath ? .returnHome : .none
    }

    static func showsAddDocument(hasNavigationPath: Bool) -> Bool {
        !hasNavigationPath
    }
}

enum ViewerSecondaryDocumentPicker {
    static var allowedContentTypes: [UTType] {
        [.pdf]
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

/// 悬停/按压反馈的动效决策——抽成纯函数以便单测覆盖 Reduce Motion 行为。
enum HoverMotion {
    /// 按压时的缩放系数。Reduce Motion 开启时不缩放,只保留透明度反馈。
    static func pressedScale(isPressed: Bool, reduceMotion: Bool) -> CGFloat {
        guard isPressed, !reduceMotion else { return 1 }
        return 0.98
    }

    /// 悬停/按压动画时长。Reduce Motion 开启时收敛为近乎即时的极短淡变。
    static func animationDuration(base: Double, reduceMotion: Bool) -> Double {
        reduceMotion ? min(base, 0.01) : base
    }
}

/// 增强对比度下的描边不透明度决策——抽成纯函数以便单测覆盖。
/// DESIGN.md:增强对比度开启时提高边界层级,不依赖低透明度维持层次。
enum HoverContrast {
    /// 只强化本就存在的边界(`base > 0`),不在静止态(`base == 0`)凭空造边框。
    static func strokeOpacity(base: Double, increasedContrast: Bool) -> Double {
        guard increasedContrast, base > 0 else { return base }
        return min(base * 1.875 + 0.10, 1.0)
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
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.colorSchemeContrast) private var colorSchemeContrast
    @State private var isHovering = false

    var body: some View {
        configuration.label
            .font(.callout.weight(variant == .toolbar ? .regular : .medium))
            .foregroundStyle(foreground)
            .padding(.horizontal, horizontalPadding)
            .padding(.vertical, verticalPadding)
            .background(background, in: RoundedRectangle(cornerRadius: 8))
            .overlay(
                RoundedRectangle(cornerRadius: 8)
                    .strokeBorder(stroke, lineWidth: 1)
            )
            .scaleEffect(HoverMotion.pressedScale(isPressed: configuration.isPressed, reduceMotion: reduceMotion))
            .opacity(isEnabled ? (configuration.isPressed ? 0.82 : 1) : 0.46)
            .animation(.easeOut(duration: HoverMotion.animationDuration(base: 0.12, reduceMotion: reduceMotion)), value: isHovering)
            .animation(.easeOut(duration: HoverMotion.animationDuration(base: 0.08, reduceMotion: reduceMotion)), value: configuration.isPressed)
            .onHover { hovering in
                isHovering = isEnabled && hovering
            }
            .clickableHoverCursor(enabled: isEnabled)
    }

    private var horizontalPadding: CGFloat {
        variant == .toolbar ? 8 : 12
    }

    private var verticalPadding: CGFloat {
        variant == .toolbar ? 4 : 6
    }

    private var increasedContrast: Bool {
        colorSchemeContrast == .increased
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
            return isHovering ? Color.accentColor.opacity(0.9) : Color.accentColor
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
            return Color.accentColor.opacity(HoverContrast.strokeOpacity(base: isHovering ? 0.55 : 0.25, increasedContrast: increasedContrast))
        case .danger:
            return Color.red.opacity(HoverContrast.strokeOpacity(base: isHovering ? 0.35 : 0.16, increasedContrast: increasedContrast))
        case .plain, .toolbar:
            return Color.primary.opacity(HoverContrast.strokeOpacity(base: isHovering ? 0.16 : 0.08, increasedContrast: increasedContrast))
        }
    }
}

struct HoverHighlightModifier: ViewModifier {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.colorSchemeContrast) private var colorSchemeContrast
    @State private var isHovering = false

    private var increasedContrast: Bool {
        colorSchemeContrast == .increased
    }

    func body(content: Content) -> some View {
        content
            .background(
                RoundedRectangle(cornerRadius: 8)
                    .fill(Color.primary.opacity(isHovering ? 0.07 : 0.0))
            )
            .overlay(
                RoundedRectangle(cornerRadius: 8)
                    .strokeBorder(
                        Color.primary.opacity(HoverContrast.strokeOpacity(base: isHovering ? 0.12 : 0.0, increasedContrast: increasedContrast)),
                        lineWidth: 1
                    )
            )
            .animation(.easeOut(duration: HoverMotion.animationDuration(base: 0.12, reduceMotion: reduceMotion)), value: isHovering)
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
