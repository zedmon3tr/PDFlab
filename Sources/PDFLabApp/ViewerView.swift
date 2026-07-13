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
        // 进入逐页对照(切模式/进并排)时把副侧对齐到 主侧 + 锚点偏移,
        // 副侧命令 revision 前进,pane 重放跳页。
        .onChange(of: session.isPagedComparisonActive) { _, active in
            if active { session.realignLinkedPages() }
        }
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
                        readingLayout: session.readingLayout,
                        isPaged: session.isPagedComparisonActive,
                        leftPageCommand: session.primaryPage.command,
                        rightPageCommand: session.secondaryPage.command,
                        onLeftPageChange: { [weak session] index, count in
                            session?.noteObservedPage(index: index, pageCount: count, on: .primary)
                        },
                        onRightPageChange: { [weak session] index, count in
                            session?.noteObservedPage(index: index, pageCount: count, on: .secondary)
                        }
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
            if ViewerToolbarPolicy.showsComparisonModeControl(isSideBySide: isSideBySide) {
                comparisonModeControl
            }
            // 对照浏览开关:紧跟布局分段控件之后(单看=readingLayoutControl,
            // 并排=comparisonModeControl),独立成组、不并入分段。
            if ViewerToolbarPolicy.showsComparisonToggle(
                currentDocumentKind: session.currentSingleDocument?.kind,
                isSideBySide: isSideBySide
            ) {
                comparisonToggleControl
            }
            if ViewerToolbarPolicy.showsPageNavigation(
                currentDocumentKind: session.currentSingleDocument?.kind,
                isSideBySide: isSideBySide,
                readingLayout: session.readingLayout
            ) {
                pageNavigationControl
            }
            if ViewerToolbarPolicy.showsPageAnchorControl(
                isSideBySide: isSideBySide,
                readingLayout: session.readingLayout
            ) {
                PageAnchorControl(session: session)
            }
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 4)
    }

    /// 对照方式:滚动(连续同步滚动)/ 逐页(方向键同步翻页)。写回共享 readingLayout;
    /// 从“双页”进入并排时显示为“滚动”(双页在对照中本就强制 continuous)。
    private var comparisonModeControl: some View {
        Picker(L10n.t("viewer.comparisonMode"), selection: Binding(
            get: { session.readingLayout == .paged ? ViewerReadingLayout.paged : .continuous },
            set: { session.readingLayout = $0 }
        )) {
            Label(L10n.t("viewer.comparisonMode.scroll"), systemImage: "scroll")
                .tag(ViewerReadingLayout.continuous)
            Label(L10n.t("viewer.comparisonMode.paged"), systemImage: "doc.text")
                .tag(ViewerReadingLayout.paged)
        }
        .pickerStyle(.segmented)
        .labelsHidden()
        .fixedSize()
        .accessibilityLabel(L10n.t("viewer.comparisonMode"))
        .help(L10n.t("viewer.comparisonMode"))
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

    /// 对照浏览开关:普通图标按钮 + 并排时持续激活高亮(点按退出,回最近单看聚焦侧);
    /// 不足两个可对照 PDF 时禁用(与旧标题栏按钮语义一致)。
    private var comparisonToggleControl: some View {
        Button {
            session.toggleSideBySide()
        } label: {
            Image(systemName: "rectangle.split.2x1")
                .font(.system(size: 12, weight: .medium))
        }
        .buttonStyle(ControlBarIconButtonStyle(isActive: isSideBySide))
        .disabled(!session.comparisonEnabled)
        .accessibilityLabel(L10n.t(comparisonToggleLabelKey))
        .help(L10n.t(comparisonToggleHelpKey))
    }

    private var comparisonToggleLabelKey: String {
        isSideBySide ? "viewer.sideBySide.exit" : "viewer.sideBySide"
    }

    private var comparisonToggleHelpKey: String {
        guard session.comparisonEnabled else { return "viewer.sideBySide.disabled" }
        return comparisonToggleLabelKey
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
            .disabled(!session.canStepPageBackward)
            if !isSideBySide, let side = session.currentSingleSide {
                let state = session.pageState(for: side)
                Text("\(state.pageIndex + 1) / \(max(state.pageCount, 1))")
                    .font(.callout.monospacedDigit())
                    .foregroundStyle(.secondary)
                    .frame(minWidth: 64)
                    .accessibilityValue(Text("\(state.pageIndex + 1) / \(max(state.pageCount, 1))"))
            }
            controlBarIconButton("chevron.right", labelKey: "viewer.pageNext") {
                session.stepPage(by: 1)
            }
            .disabled(!session.canStepPageForward)
        }
    }
}

/// 微调控件:显示并可编辑两侧当前 1 计页码。非编辑期间跟随 session 实时刷新(翻页联动);
/// 提交时经 session.applyPageAnchor 校验建立锚点偏移,成功后 realignLinkedPages 把右栏
/// 按新偏移跳页(applyPageAnchor 本身只记录偏移、不发命令);非法输入弹 alert 并回显原值。
private struct PageAnchorControl: View {
    @ObservedObject var session: ViewerSession

    @State private var leftText = ""
    @State private var rightText = ""
    @FocusState private var focusedField: Side?

    private enum Side: Hashable { case left, right }

    var body: some View {
        HStack(spacing: 6) {
            Text(L10n.t("viewer.pageAnchor.left"))
                .font(.callout)
                .foregroundStyle(.secondary)
            anchorField($leftText, side: .left)
            Text("=")
                .font(.callout)
                .foregroundStyle(.secondary)
            Text(L10n.t("viewer.pageAnchor.right"))
                .font(.callout)
                .foregroundStyle(.secondary)
            anchorField($rightText, side: .right)
        }
        .help(L10n.t("viewer.pageAnchor.help"))
        .onAppear { refreshFromSession() }
        .onChange(of: session.primaryPage.pageIndex) { refreshFromSession() }
        .onChange(of: session.secondaryPage.pageIndex) { refreshFromSession() }
    }

    private func anchorField(_ text: Binding<String>, side: Side) -> some View {
        TextField("", text: text)
            .textFieldStyle(.roundedBorder)
            .font(.callout.monospacedDigit())
            .multilineTextAlignment(.center)
            .frame(width: 44)
            .focused($focusedField, equals: side)
            .onSubmit { commit() }
            .accessibilityLabel(side == .left ? L10n.t("viewer.pageAnchor.left") : L10n.t("viewer.pageAnchor.right"))
    }

    /// 翻页联动:仅在两个输入框都未聚焦时跟随会话刷新,不打断用户输入。
    private func refreshFromSession() {
        guard focusedField == nil else { return }
        leftText = "\(session.primaryPage.pageIndex + 1)"
        rightText = "\(session.secondaryPage.pageIndex + 1)"
    }

    private func commit() {
        if session.applyPageAnchor(primaryText: leftText, secondaryText: rightText) {
            // applyPageAnchor 只校验并记录偏移,不发页命令;
            // 这里显式重对齐,右栏立即按新锚点跳页。
            session.realignLinkedPages()
        } else {
            session.alert = ViewerAlert(
                title: L10n.t("viewer.pageAnchor.invalidTitle"),
                message: L10n.t("viewer.pageAnchor.invalidMessage")
            )
        }
        focusedField = nil
        leftText = "\(session.primaryPage.pageIndex + 1)"
        rightText = "\(session.secondaryPage.pageIndex + 1)"
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

/// 控制条方形图标按钮:整块命中区 + 轻 hover 反馈,遵循 Reduce Motion / 增强对比度。
/// `isActive` 表达持续开启态(如对照浏览进行中):tonal fill + 描边 + accent 图标
/// 三重信号,不只靠颜色(DESIGN.md 选中态)。
struct ControlBarIconButtonStyle: ButtonStyle {
    var isActive = false

    /// 激活态度量(供测试校验落在 DESIGN.md 克制区间):
    /// fill 明显强于非激活 hover(0.08),描边基值 > 0 保证增强对比度可抬升。
    static let activeFillOpacity = 0.14
    static let activeHoverFillOpacity = 0.18
    static let activeStrokeOpacity = 0.16
    static let activeHoverStrokeOpacity = 0.24

    func makeBody(configuration: Configuration) -> some View {
        ControlBarIconButtonBody(configuration: configuration, isActive: isActive)
    }
}

private struct ControlBarIconButtonBody: View {
    let configuration: ButtonStyle.Configuration
    var isActive = false

    @Environment(\.isEnabled) private var isEnabled
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.colorSchemeContrast) private var colorSchemeContrast
    @State private var isHovering = false

    private var fillOpacity: Double {
        if isActive {
            return isHovering
                ? ControlBarIconButtonStyle.activeHoverFillOpacity
                : ControlBarIconButtonStyle.activeFillOpacity
        }
        return isHovering ? 0.08 : 0.035
    }

    private var strokeBaseOpacity: Double {
        if isActive {
            return isHovering
                ? ControlBarIconButtonStyle.activeHoverStrokeOpacity
                : ControlBarIconButtonStyle.activeStrokeOpacity
        }
        return isHovering ? 0.16 : 0.08
    }

    private var iconStyle: AnyShapeStyle {
        guard isEnabled else { return AnyShapeStyle(.secondary) }
        return isActive ? AnyShapeStyle(Color.accentColor) : AnyShapeStyle(.primary)
    }

    var body: some View {
        configuration.label
            .foregroundStyle(iconStyle)
            .frame(
                width: ViewerControlBarMetrics.buttonSize,
                height: ViewerControlBarMetrics.buttonSize
            )
            .background(
                Color.primary.opacity(fillOpacity),
                in: RoundedRectangle(cornerRadius: ViewerControlBarMetrics.cornerRadius)
            )
            .overlay(
                RoundedRectangle(cornerRadius: ViewerControlBarMetrics.cornerRadius)
                    .strokeBorder(
                        Color.primary.opacity(
                            HoverContrast.strokeOpacity(
                                base: strokeBaseOpacity,
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

    /// 对照浏览开关:PDF 语境(单看 PDF 或已并排)时显示;
    /// 不足两个可对照 PDF 时禁用而非隐藏(禁用逻辑在按钮侧,用 comparisonEnabled)。
    static func showsComparisonToggle(currentDocumentKind: ViewerDocumentKind?, isSideBySide: Bool) -> Bool {
        isSideBySide || currentDocumentKind == .pdf
    }

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
