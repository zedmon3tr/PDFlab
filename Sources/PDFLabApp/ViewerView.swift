import AppKit
import PDFKit
import SwiftUI
import UniformTypeIdentifiers
import PDFLabCore

/// 查看器内容视图:单文档 / 对照面板 + 单 PDF 控制条。
/// 状态全部在常驻 ViewerSession 里(浏览器 tab 语义,回首页不销毁);
/// 标签条、比例/对照工具项与 alert 由 MainView 的唯一 toolbar 承载。
struct ViewerView: View {
    static var openableContentTypes: [UTType] {
        var types: [UTType] = [.pdf, .plainText]
        if let markdown = UTType(filenameExtension: "md") {
            types.append(markdown)
        }
        return types
    }

    @ObservedObject var session: ViewerSession
    /// 逐页模式方向键翻页监视器:ViewerView 常驻挂载(MainView ZStack 不销毁),
    /// 监视器一次安装、handler 内判活——非逐页态/查看器未前置时零损耗放行。
    @StateObject private var pagedKeys = ViewerPagedKeyMonitor()

    var body: some View {
        VStack(spacing: 0) {
            if showsControlBar {
                controlBar
                Divider()
            }
            viewerContent
        }
        .onAppear {
            pagedKeys.handler = { [weak session] delta in
                guard let session, session.isViewerVisible,
                      session.isPagedSingleActive || session.isPagedComparisonActive else { return false }
                session.stepPage(by: delta)
                return true
            }
            pagedKeys.start()
        }
        .onDisappear { pagedKeys.stop() }
    }

    @ViewBuilder
    private var viewerContent: some View {
        if let primary = session.primary {
            switch session.effectiveLayout {
            case .sideBySide:
                if let secondary = session.secondary {
                    DualPaneView(
                        left: primary,
                        right: secondary,
                        ratioA: session.ratioA,
                        ratioB: session.ratioB,
                        readingLayout: session.readingLayout
                    )
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                } else {
                    singleDocumentContent(primary)
                }
            case .single(.secondary):
                if let secondary = session.secondary {
                    singleDocumentContent(secondary)
                } else {
                    singleDocumentContent(primary)
                }
            case .single(.primary):
                singleDocumentContent(primary)
            }
        } else {
            Text(L10n.t("viewer.noDocument"))
                .foregroundStyle(.secondary)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }

    @ViewBuilder
    private func singleDocumentContent(_ document: ViewerDocument) -> some View {
        SingleDocumentView(
            document: document,
            readingLayout: session.readingLayout,
            zoomCommand: session.zoomCommand,
            isPaged: session.readingLayout == .paged,
            pageCommand: session.currentSingleSide.flatMap { session.pageState(for: $0).command },
            onScaleChange: { [weak session] scale in
                session?.noteObservedZoomScale(scale)
            },
            onUserZoom: { [weak session] in
                session?.noteUserZoomGesture()
            },
            onPageChange: { [weak session] index, count in
                // 单看时 currentSingleSide 即该文档所在侧;对照回显走 DualPane 自己的回调。
                guard let session, let side = session.currentSingleSide else { return }
                session.noteObservedPage(index: index, pageCount: count, on: side)
            }
        )
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    // MARK: - 单 PDF 控制条(Figma "viewing pdf" 帧:缩放组 + 预览模式切换,水平居中)

    private var isSideBySide: Bool {
        session.effectiveLayout == .sideBySide
    }

    private var showsControlBar: Bool {
        ViewerToolbarPolicy.showsZoomControl(
            currentDocumentKind: session.currentSingleDocument?.kind,
            isSideBySide: isSideBySide
        ) || ViewerToolbarPolicy.showsReadingLayoutControl(
            currentDocumentKind: session.currentSingleDocument?.kind,
            isSideBySide: isSideBySide
        ) || ViewerToolbarPolicy.showsComparisonModeControl(isSideBySide: isSideBySide)
            || ViewerToolbarPolicy.showsPageNavigation(
                currentDocumentKind: session.currentSingleDocument?.kind,
                isSideBySide: isSideBySide,
                readingLayout: session.readingLayout
            )
    }

    private var controlBar: some View {
        HStack(spacing: ViewerControlBarMetrics.groupSpacing) {
            if ViewerToolbarPolicy.showsZoomControl(
                currentDocumentKind: session.currentSingleDocument?.kind,
                isSideBySide: isSideBySide
            ) {
                zoomControl
            }
            if ViewerToolbarPolicy.showsReadingLayoutControl(
                currentDocumentKind: session.currentSingleDocument?.kind,
                isSideBySide: isSideBySide
            ) {
                readingLayoutControl
            }
            if ViewerToolbarPolicy.showsPageNavigation(
                currentDocumentKind: session.currentSingleDocument?.kind,
                isSideBySide: isSideBySide,
                readingLayout: session.readingLayout
            ) {
                pageNavigationControl
            }
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 4)
    }

    /// [-] [100%⌄] [+]:缩放值整块为原生菜单按钮。
    private var zoomControl: some View {
        HStack(spacing: ViewerControlBarMetrics.itemSpacing) {
            controlBarIconButton("minus", labelKey: "viewer.zoomOut") {
                session.zoomOut()
            }
            ViewerZoomPopUpButton(
                percent: ViewerZoom.percentLabel(for: session.zoomScale),
                checkedItem: ViewerZoom.checkedMenuItem(selection: session.zoomSelection, scale: session.zoomScale),
                accessibilityLabel: L10n.t("viewer.zoom"),
                onSelect: handleZoomMenuAction
            )
                .frame(
                    width: ViewerControlBarMetrics.zoomMenuWidth,
                    height: ViewerControlBarMetrics.buttonSize
                )
                .help(L10n.t("viewer.zoom"))
            controlBarIconButton("plus", labelKey: "viewer.zoomIn") {
                session.zoomIn()
            }
        }
    }

    private func handleZoomMenuAction(_ action: ViewerZoomMenuAction) {
        switch action {
        case .preset(let scale): session.selectZoomPreset(scale)
        case .actualSize: session.selectActualSize()
        case .fitPage: session.selectFitPage()
        case .fitWidth: session.selectFitWidth()
        case .fitHeight: session.selectFitHeight()
        }
    }

    private func controlBarIconButton(
        _ systemName: String,
        labelKey: String,
        action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            Image(systemName: systemName)
                .font(.system(size: 12, weight: .medium))
        }
        .buttonStyle(ControlBarIconButtonStyle())
        .accessibilityLabel(L10n.t(labelKey))
        .help(L10n.t(labelKey))
    }

    /// 双页 / 滚动预览模式分段切换。
    private var readingLayoutControl: some View {
        Picker(L10n.t("viewer.pageLayout"), selection: $session.readingLayout) {
            ForEach(ViewerReadingLayout.allCases) { layout in
                Label(L10n.t(layout.titleKey), systemImage: layout.iconName)
                    .tag(layout)
            }
        }
        .pickerStyle(.segmented)
        .labelsHidden()
        .fixedSize()
        .accessibilityLabel(L10n.t("viewer.pageLayout"))
        .help(L10n.t("viewer.pageLayout"))
    }

    /// 逐页翻页:◀ 页码/总页 ▶。并排时页码显示由 Task 5 的微调控件承担,这里只出按钮。
    private var pageNavigationControl: some View {
        HStack(spacing: ViewerControlBarMetrics.itemSpacing) {
            controlBarIconButton("chevron.left", labelKey: "viewer.pagePrevious") {
                session.stepPage(by: -1)
            }
            if !isSideBySide, let side = session.currentSingleSide {
                let state = session.pageState(for: side)
                Text("\(state.pageIndex + 1) / \(max(state.pageCount, 1))")
                    .font(.callout.monospacedDigit())
                    .foregroundStyle(.secondary)
                    .frame(minWidth: 64)
            }
            controlBarIconButton("chevron.right", labelKey: "viewer.pageNext") {
                session.stepPage(by: 1)
            }
        }
    }
}

enum ViewerZoomMenuAction: Equatable {
    case preset(Double)
    case actualSize
    case fitPage
    case fitWidth
    case fitHeight
}

/// AppKit 仅负责稳定的原生箭头/菜单呈现与 target-action；业务状态仍由 ViewerSession 持有。
struct ViewerZoomPopUpButton: NSViewRepresentable {
    var percent: String
    var checkedItem: ViewerZoomMenuItem?
    var accessibilityLabel: String
    var onSelect: (ViewerZoomMenuAction) -> Void

    func makeCoordinator() -> Coordinator { Coordinator(onSelect: onSelect) }

    func makeNSView(context: Context) -> NSPopUpButton {
        let button = Self.makeButton()
        update(button, coordinator: context.coordinator)
        return button
    }

    func updateNSView(_ button: NSPopUpButton, context: Context) {
        context.coordinator.onSelect = onSelect
        update(button, coordinator: context.coordinator)
    }

    static func makeButton() -> NSPopUpButton {
        let button = NSPopUpButton(
            frame: NSRect(
                x: 0,
                y: 0,
                width: ViewerControlBarMetrics.zoomMenuWidth,
                height: ViewerControlBarMetrics.buttonSize
            ),
            pullsDown: true
        )
        button.controlSize = .regular
        button.bezelStyle = .rounded
        button.font = .systemFont(ofSize: NSFont.systemFontSize)
        if let cell = button.cell as? NSPopUpButtonCell {
            cell.altersStateOfSelectedItem = false
            cell.arrowPosition = .arrowAtCenter
        }
        return button
    }

    func update(_ button: NSPopUpButton, coordinator: Coordinator) {
        let menu = NSMenu()
        // pullsDown 的第 0 项只负责按钮标题；加入不可见 word joiner，避免它与 100% 动作项
        // 同名时 NSPopUpButton 把动作项也当作当前展示项并清掉其 checkmark。
        menu.addItem(NSMenuItem(title: percent + "\u{2060}", action: nil, keyEquivalent: ""))

        for (index, preset) in ViewerZoom.presets.enumerated() {
            let item = coordinator.item(
                title: ViewerZoom.percentLabel(for: preset),
                action: .preset(preset),
                tag: 100 + index
            )
            item.state = checkedItem == .preset(preset) ? .on : .off
            menu.addItem(item)
        }
        menu.addItem(.separator())
        menu.addItem(coordinator.item(title: L10n.t("viewer.zoomActualSize"), action: .actualSize, tag: 200))
        menu.addItem(coordinator.fitItem(title: L10n.t("viewer.zoomFitPage"), action: .fitPage, tag: 201, checked: checkedItem == .fitPage))
        menu.addItem(coordinator.fitItem(title: L10n.t("viewer.zoomFitWidth"), action: .fitWidth, tag: 202, checked: checkedItem == .fitWidth))
        menu.addItem(coordinator.fitItem(title: L10n.t("viewer.zoomFitHeight"), action: .fitHeight, tag: 203, checked: checkedItem == .fitHeight))

        button.menu = menu
        button.selectItem(at: 0)
        // NSPopUpButton 安装菜单/选择展示项时会重写 state；最后再同步业务勾选。
        for item in menu.items {
            switch item.tag {
            case 100 ..< 100 + ViewerZoom.presets.count:
                let preset = ViewerZoom.presets[item.tag - 100]
                item.state = checkedItem == .preset(preset) ? .on : .off
            case 201: item.state = checkedItem == .fitPage ? .on : .off
            case 202: item.state = checkedItem == .fitWidth ? .on : .off
            case 203: item.state = checkedItem == .fitHeight ? .on : .off
            default: item.state = .off
            }
        }
        button.setAccessibilityLabel(accessibilityLabel)
        button.setAccessibilityValue(percent)
    }

    final class Coordinator: NSObject {
        var onSelect: (ViewerZoomMenuAction) -> Void
        private var actions: [Int: ViewerZoomMenuAction] = [:]

        init(onSelect: @escaping (ViewerZoomMenuAction) -> Void) {
            self.onSelect = onSelect
        }

        func item(title: String, action: ViewerZoomMenuAction, tag: Int) -> NSMenuItem {
            actions[tag] = action
            let item = NSMenuItem(title: title, action: #selector(selectMenuItem(_:)), keyEquivalent: "")
            item.target = self
            item.tag = tag
            return item
        }

        func fitItem(title: String, action: ViewerZoomMenuAction, tag: Int, checked: Bool) -> NSMenuItem {
            let item = item(title: title, action: action, tag: tag)
            item.state = checked ? .on : .off
            return item
        }

        @objc func selectMenuItem(_ sender: NSMenuItem) {
            guard let action = actions[sender.tag] else { return }
            onSelect(action)
        }
    }
}

/// 控制条度量(Figma "viewing pdf" 帧)。
enum ViewerControlBarMetrics {
    /// 加/减按钮边长(命中区,≥ DESIGN.md 图标按钮 24×24 下限)。
    static let buttonSize: CGFloat = 32
    /// 百分比静态文本框宽度。
    static let zoomMenuWidth: CGFloat = 76
    /// 缩放组内元素间距。
    static let itemSpacing: CGFloat = 2
    /// 缩放组与预览模式切换组件的间距。
    static let groupSpacing: CGFloat = 27
    /// 控件圆角(DESIGN.md 紧凑控件 6pt)。
    static let cornerRadius: CGFloat = 6
}

/// 控制条 32×32 图标按钮:整块命中区 + 轻 hover 反馈,遵循 Reduce Motion / 增强对比度。
private struct ControlBarIconButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        ControlBarIconButtonBody(configuration: configuration)
    }
}

private struct ControlBarIconButtonBody: View {
    let configuration: ButtonStyle.Configuration

    @Environment(\.isEnabled) private var isEnabled
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.colorSchemeContrast) private var colorSchemeContrast
    @State private var isHovering = false

    var body: some View {
        configuration.label
            .foregroundStyle(isEnabled ? AnyShapeStyle(.primary) : AnyShapeStyle(.secondary))
            .frame(
                width: ViewerControlBarMetrics.buttonSize,
                height: ViewerControlBarMetrics.buttonSize
            )
            .background(
                Color.primary.opacity(isHovering ? 0.08 : 0.035),
                in: RoundedRectangle(cornerRadius: ViewerControlBarMetrics.cornerRadius)
            )
            .overlay(
                RoundedRectangle(cornerRadius: ViewerControlBarMetrics.cornerRadius)
                    .strokeBorder(
                        Color.primary.opacity(
                            HoverContrast.strokeOpacity(
                                base: isHovering ? 0.16 : 0.08,
                                increasedContrast: colorSchemeContrast == .increased
                            )
                        ),
                        lineWidth: 1
                    )
            )
            .contentShape(RoundedRectangle(cornerRadius: ViewerControlBarMetrics.cornerRadius))
            .scaleEffect(HoverMotion.pressedScale(isPressed: configuration.isPressed, reduceMotion: reduceMotion))
            .opacity(isEnabled ? (configuration.isPressed ? 0.82 : 1) : 0.46)
            .animation(.easeOut(duration: HoverMotion.animationDuration(base: 0.12, reduceMotion: reduceMotion)), value: isHovering)
            .animation(.easeOut(duration: HoverMotion.animationDuration(base: 0.08, reduceMotion: reduceMotion)), value: configuration.isPressed)
            .onHover { hovering in
                isHovering = isEnabled && hovering
            }
            .clickableHoverCursor(enabled: isEnabled)
    }
}

/// 标题栏文档标签度量(参考图:Chrome/PDF Expert 式标签)。
enum ViewerTabMetrics {
    /// 标签高度:尽量占满 macOS 标题栏工具项可用高度。
    static let height: CGFloat = 28
    static let horizontalPadding: CGFloat = 12
    static let maxTitleWidth: CGFloat = 220
    /// 标签区与 "+" 之间的细竖分隔线。
    static let separatorWidth: CGFloat = 1
    static let separatorHeight: CGFloat = 18
}

/// 单 PDF 控制条显隐策略:仅当前单看文档为 PDF 时显示;
/// 对照阅读两栏各自连续滚动并由同步控制器协调,单文档布局/缩放控件不参与。
enum ViewerToolbarPolicy {
    static func showsReadingLayoutControl(currentDocumentKind: ViewerDocumentKind?, isSideBySide: Bool) -> Bool {
        currentDocumentKind == .pdf && !isSideBySide
    }

    static func showsZoomControl(currentDocumentKind: ViewerDocumentKind?, isSideBySide: Bool) -> Bool {
        currentDocumentKind == .pdf && !isSideBySide
    }

    static func showsPageNavigation(
        currentDocumentKind: ViewerDocumentKind?, isSideBySide: Bool, readingLayout: ViewerReadingLayout
    ) -> Bool {
        readingLayout == .paged && (isSideBySide || currentDocumentKind == .pdf)
    }

    static func showsComparisonModeControl(isSideBySide: Bool) -> Bool { isSideBySide }

    static func showsPageAnchorControl(isSideBySide: Bool, readingLayout: ViewerReadingLayout) -> Bool {
        isSideBySide && readingLayout == .paged
    }

    static func showsRatioControls(isSideBySide: Bool, readingLayout: ViewerReadingLayout) -> Bool {
        isSideBySide && readingLayout != .paged
    }
}

enum ViewerComparisonPolicy {
    static func isEnabled(
        primaryKind: ViewerDocumentKind?,
        secondaryKind: ViewerDocumentKind?
    ) -> Bool {
        primaryKind == .pdf && secondaryKind == .pdf
    }
}
