import AppKit
import PDFKit
import SwiftUI
import PDFLabCore

enum ViewerSide: Equatable {
    case primary
    case secondary
}

/// 查看器视图模式:single 聚焦单看某一侧,sideBySide 左右并排对照。
enum ViewerLayout: Equatable {
    case single(ViewerSide)
    case sideBySide
}

struct ViewerAlert: Identifiable {
    let id = UUID()
    var title: String
    var message: String
}

struct ViewerPasswordRequest {
    var url: URL
    var side: ViewerSide
}

/// 每侧独立的会话内缩放记忆(不写 AppStorage,不跨进程持久化)。
/// 默认 = 实际大小 100%(free + scale 1);命令流每侧独立 revision,
/// SinglePDFView 重建时按 command 重放恢复该侧缩放。
struct SideZoomState: Equatable {
    var selection: ViewerZoomSelection = .free
    var scale: Double = 1.0
    var command: ViewerZoomCommand?
}

/// 每侧独立的会话内页码状态(逐页查看用;挂后台保留,重开 app 重置——只活在常驻 session)。
struct SidePageState: Equatable {
    var pageIndex: Int = 0
    var pageCount: Int = 0
    var command: ViewerPageCommand?
}

/// 常驻查看会话(浏览器 tab 语义):文档标签与对照布局状态与查看器视图解耦。
/// 返回首页不销毁——标签继续显示在标题栏,点标签回到查看器时滚动/缩放原样保留;
/// 关掉全部标签才回到纯首页。
@MainActor
final class ViewerSession: ObservableObject {
    @Published private(set) var primary: ViewerDocument?
    @Published private(set) var secondary: ViewerDocument?
    /// 切标签/切布局绝不重置缩放:single(.primary)↔single(.secondary) 只是展示另一侧已存状态。
    @Published var layout: ViewerLayout = .single(.primary) {
        didSet {
            // 任何来源(点标签、关标签、装入文档、测试注入)把布局落到单看,
            // 都记住聚焦侧——退出对照浏览时回到它。
            if case .single(let side) = layout {
                lastSingleFocus = side
            }
        }
    }
    /// 最近一次单看聚焦侧(会话内记忆):退出对照浏览回到它,不换用户正在看的文档。
    private(set) var lastSingleFocus: ViewerSide = .primary
    @Published var ratioA = 1.0
    @Published var ratioB = 1.0
    @Published var alert: ViewerAlert?
    @Published var passwordRequest: ViewerPasswordRequest?
    @Published var passwordFailure: String?
    /// 查看器是否前置(false = 首页;会话与文档保留)。
    @Published var isViewerVisible = false

    // MARK: - 单 PDF 控制条状态(预览模式 + 缩放)

    /// 单文档预览模式偏好(双页/滚动)。对照模式不使用该值:DualPaneView 强制 continuous
    /// (分页模式每页可滚高度近零,会悄悄弄坏同步滚动)。
    @Published var readingLayout = ViewerReadingLayout.defaultLayout
    /// 每侧独立缩放记忆:文档挂后台(切标签/回首页)仍保留自己的缩放,
    /// 只有装入/替换该侧文档才重置为默认实际大小 100%。
    @Published private(set) var primaryZoom = SideZoomState()
    @Published private(set) var secondaryZoom = SideZoomState()

    // MARK: - 逐页查看状态(页码 + 翻页命令 + 锚点偏移)

    /// 每侧独立页码记忆:文档挂后台仍保留,只有装入/替换该侧文档才重置。
    @Published private(set) var primaryPage = SidePageState()
    @Published private(set) var secondaryPage = SidePageState()
    /// 微调锚点偏移:secondaryIndex − primaryIndex(0 计)。仅双 PDF 逐页对照使用。
    @Published private(set) var pageLinkOffset = 0

    #if DEBUG
    /// 仅测试:`layoutForTesting(.sideBySide)` 时置 true,让 `isPagedComparisonActive`
    /// 在没有真实 secondary 文档(`effectiveLayout` 退回 single)的情况下仍判定为对照中,
    /// 从而无需加载真实 PDF 就能测翻页联动数学。
    private var testingForcesComparison = false
    #endif

    /// 逐页对照是否生效:sideBySide 布局 + 逐页阅读模式。
    var isPagedComparisonActive: Bool {
        guard readingLayout == .paged else { return false }
        if case .sideBySide = layout {
            #if DEBUG
            if testingForcesComparison { return true }
            #endif
            return effectiveLayout == .sideBySide
        }
        return false
    }

    /// 单看 PDF 且处于逐页阅读模式。
    var isPagedSingleActive: Bool {
        readingLayout == .paged && currentSingleDocument?.kind == .pdf
    }

    func pageState(for side: ViewerSide) -> SidePageState {
        side == .primary ? primaryPage : secondaryPage
    }

    private func modifyPageState(on side: ViewerSide, _ body: (inout SidePageState) -> Void) {
        switch side {
        case .primary: body(&primaryPage)
        case .secondary: body(&secondaryPage)
        }
    }

    private func issuePageCommand(_ index: Int, on side: ViewerSide) {
        modifyPageState(on: side) { state in
            state.pageIndex = ViewerPageNavigation.clampedIndex(index, pageCount: state.pageCount)
            state.command = ViewerPageCommand(
                pageIndex: state.pageIndex,
                revision: (state.command?.revision ?? 0) + 1
            )
        }
    }

    /// 翻页(按钮/方向键共用):单看只动聚焦侧;逐页对照两侧按锚点偏移联动。
    func stepPage(by delta: Int) {
        if isPagedComparisonActive {
            let next = ViewerPageNavigation.steppedIndex(
                from: primaryPage.pageIndex, by: delta, pageCount: primaryPage.pageCount)
            issuePageCommand(next, on: .primary)
            issuePageCommand(
                ViewerPageNavigation.linkedIndex(
                    sourceIndex: next, offset: pageLinkOffset, targetPageCount: secondaryPage.pageCount),
                on: .secondary)
        } else if let side = currentSingleSide {
            let state = pageState(for: side)
            issuePageCommand(
                ViewerPageNavigation.steppedIndex(from: state.pageIndex, by: delta, pageCount: state.pageCount),
                on: side)
        }
    }

    /// 翻页按钮边界判定所用的当前相关页状态:逐页对照以主侧为准
    /// (副侧被动跟随,不单独判定边界);否则单看用聚焦侧。
    private var relevantPageStateForStepping: SidePageState? {
        if isPagedComparisonActive {
            return primaryPage
        }
        if let side = currentSingleSide {
            return pageState(for: side)
        }
        return nil
    }

    /// pageCount 为 0(尚无页信息)时视为不可翻,两个方向都禁用。
    var canStepPageBackward: Bool {
        guard let state = relevantPageStateForStepping, state.pageCount > 0 else { return false }
        return state.pageIndex > 0
    }

    var canStepPageForward: Bool {
        guard let state = relevantPageStateForStepping, state.pageCount > 0 else { return false }
        return state.pageIndex < state.pageCount - 1
    }

    /// 微调:用两侧当前 1 计页码建立锚点偏移。任一侧非法(非数字/越界)返回 false 且不改状态。
    /// 只记录 secondaryIndex − primaryIndex 的关系,不强制两侧跳转——用户已经手动对齐到
    /// 这两页才会点“建立锚点”,不应该反过来打断当前查看位置。
    func applyPageAnchor(primaryText: String, secondaryText: String) -> Bool {
        guard let primaryIndex = ViewerPageNavigation.pageIndex(fromDisplayText: primaryText, pageCount: primaryPage.pageCount),
              let secondaryIndex = ViewerPageNavigation.pageIndex(fromDisplayText: secondaryText, pageCount: secondaryPage.pageCount)
        else { return false }
        pageLinkOffset = secondaryIndex - primaryIndex
        return true
    }

    /// PDFView 页回显(命令施加以外的任何来源)。主侧变化时在逐页对照下驱动副侧跟随
    /// (单向:副侧命令不会再产生主侧回显,不成环);副侧回显只更新显示。
    /// 命令存在时把 pageIndex 原位同步进去(不前进 revision)——活跃视图因 revision
    /// 相同不会重放,但该侧 PDFView 拆掉重建(切标签回来)时能重放出观察到的真实页码,
    /// 而不是命令签发时的旧页(PDF 内链点击、PDFKit 原生 Space/PageUp/PageDown 等非命令
    /// 来源的翻页都会走到这里)。与 `noteObservedZoomScale` 同一套约定。
    func noteObservedPage(index: Int, pageCount: Int, on side: ViewerSide) {
        modifyPageState(on: side) { state in
            state.pageCount = pageCount
            state.pageIndex = ViewerPageNavigation.clampedIndex(index, pageCount: pageCount)
            if state.command != nil {
                state.command?.pageIndex = state.pageIndex
            }
        }
        if side == .primary, isPagedComparisonActive {
            issuePageCommand(
                ViewerPageNavigation.linkedIndex(
                    sourceIndex: primaryPage.pageIndex, offset: pageLinkOffset, targetPageCount: secondaryPage.pageCount),
                on: .secondary)
        }
    }

    /// 进入逐页对照(切模式/进并排)时把副侧对齐到 主侧 + 偏移。
    func realignLinkedPages() {
        guard isPagedComparisonActive else { return }
        issuePageCommand(
            ViewerPageNavigation.linkedIndex(
                sourceIndex: primaryPage.pageIndex, offset: pageLinkOffset, targetPageCount: secondaryPage.pageCount),
            on: .secondary)
    }

    #if DEBUG
    /// 仅测试:注入页数,免加载真实 PDF。
    func setPageCountForTesting(_ count: Int, on side: ViewerSide) {
        modifyPageState(on: side) { $0.pageCount = count }
    }

    /// 仅测试:注入布局(含 sideBySide),配合 `testingForcesComparison` 让逐页对照联动
    /// 数学可测,免加载真实第二文档。
    func layoutForTesting(_ layout: ViewerLayout) {
        self.layout = layout
        if case .sideBySide = layout {
            testingForcesComparison = true
        } else {
            testingForcesComparison = false
        }
    }
    #endif

    /// 当前单看侧(sideBySide 时 nil):控制条读写与 PDFView 回显路由的唯一依据。
    var currentSingleSide: ViewerSide? {
        switch effectiveLayout {
        case .single(let side):
            return side
        case .sideBySide:
            return nil
        }
    }

    /// 当前单看侧的回显倍率(仅驱动百分比显示;sideBySide 无单看侧时给安全默认)。
    var zoomScale: Double {
        currentSingleSide.map { zoomState(for: $0).scale } ?? 1.0
    }

    var zoomSelection: ViewerZoomSelection {
        currentSingleSide.map { zoomState(for: $0).selection } ?? .free
    }

    /// 当前单看侧的缩放命令;SinglePDFView 按 revision 幂等施加,重建时重放恢复该侧缩放。
    var zoomCommand: ViewerZoomCommand? {
        currentSingleSide.flatMap { zoomState(for: $0).command }
    }

    func zoomIn() {
        guard let side = currentSingleSide else { return }
        issueZoomCommand(.scale(ViewerZoom.steppedUp(from: zoomState(for: side).scale)), selection: .free, on: side)
    }

    func zoomOut() {
        guard let side = currentSingleSide else { return }
        issueZoomCommand(.scale(ViewerZoom.steppedDown(from: zoomState(for: side).scale)), selection: .free, on: side)
    }

    func selectZoomPreset(_ scale: Double) {
        guard let side = currentSingleSide else { return }
        issueZoomCommand(.scale(ViewerZoom.clampedScale(scale)), selection: .free, on: side)
    }

    func selectActualSize() { selectZoomPreset(1) }

    func selectFitPage() {
        guard let side = currentSingleSide else { return }
        issueZoomCommand(.fitPage, selection: .fitPage, on: side)
    }

    func selectFitWidth() {
        guard let side = currentSingleSide else { return }
        issueZoomCommand(.fitWidth, selection: .fitWidth, on: side)
    }

    func selectFitHeight() {
        guard let side = currentSingleSide else { return }
        issueZoomCommand(.fitHeight, selection: .fitHeight, on: side)
    }

    func noteUserZoomGesture() {
        guard let side = currentSingleSide else { return }
        modifyZoomState(on: side) { $0.selection = .free }
    }

    /// PDFView 侧回显(捏合/按钮/自动适配任何来源):只更新显示值,
    /// 绝不派生新缩放命令(revision 不前进)——防回环的最后一道约定。
    /// free 选择下把命令动作原位同步为回显倍率:活跃视图因 revision 相同不会重放,
    /// 但该侧 PDFView 拆掉重建(切标签回来)时能重放出捏合/步进后的真实缩放。
    func noteObservedZoomScale(_ scale: Double) {
        guard let side = currentSingleSide else { return }
        let clamped = ViewerZoom.clampedScale(scale)
        guard abs(clamped - zoomState(for: side).scale) > 0.0001 else { return }
        modifyZoomState(on: side) { state in
            state.scale = clamped
            if state.selection == .free, state.command != nil {
                state.command?.action = .scale(clamped)
            }
        }
    }

    private func zoomState(for side: ViewerSide) -> SideZoomState {
        side == .primary ? primaryZoom : secondaryZoom
    }

    private func modifyZoomState(on side: ViewerSide, _ body: (inout SideZoomState) -> Void) {
        switch side {
        case .primary:
            body(&primaryZoom)
        case .secondary:
            body(&secondaryZoom)
        }
    }

    private func issueZoomCommand(_ action: ViewerZoomAction, selection: ViewerZoomSelection, on side: ViewerSide) {
        modifyZoomState(on: side) { state in
            state.selection = selection
            state.command = ViewerZoomCommand(
                action: action,
                revision: (state.command?.revision ?? 0) + 1
            )
        }
    }

    /// 装入/替换该侧文档:回默认实际大小 100%(发真实 .scale(1) 命令驱动 PDFView),
    /// 只重置被换的一侧,另一侧与切标签路径都不受影响。
    private func resetZoom(on side: ViewerSide) {
        modifyZoomState(on: side) { state in
            state.selection = .free
            state.scale = 1.0
            state.command = ViewerZoomCommand(
                action: .scale(1),
                revision: (state.command?.revision ?? 0) + 1
            )
        }
    }

    /// 查看模块打开主文件成功时回调(MainView 挂历史记录;晋升/译文侧不回调)。
    var onRecordOpen: ((URL) -> Void)?

    var hasDocuments: Bool { primary != nil }
    var isFull: Bool { primary != nil && secondary != nil }

    /// 有效布局:处理边界(secondary 缺失时任何指向 secondary 的布局都退回单看 primary)。
    var effectiveLayout: ViewerLayout {
        switch layout {
        case .sideBySide where !comparisonEnabled:
            return .single(.primary)
        case .single(.secondary) where secondary == nil:
            return .single(.primary)
        default:
            return layout
        }
    }

    var comparisonEnabled: Bool {
        ViewerComparisonPolicy.isEnabled(
            primaryKind: primary?.kind,
            secondaryKind: secondary?.kind
        )
    }

    var currentSingleDocument: ViewerDocument? {
        switch effectiveLayout {
        case .single(.primary):
            return primary
        case .single(.secondary):
            return secondary
        case .sideBySide:
            return nil
        }
    }

    /// 标签是否处于激活态:查看器前置时,sideBySide 下两侧都算激活、single 下仅聚焦侧激活;
    /// 回到首页后全部失焦(挂后台)——logo 只是"回主页"动作按钮,不承载长亮状态,
    /// 标签高亮只表达"查看器当前聚焦谁"。
    func isTabActive(_ side: ViewerSide) -> Bool {
        guard isViewerVisible else { return false }
        switch effectiveLayout {
        case .sideBySide:
            return true
        case .single(let focused):
            return focused == side
        }
    }

    // MARK: - 导航(浏览器语义)

    /// 点 logo 回首页:只切换可见性,会话不动。
    func returnHome() {
        isViewerVisible = false
    }

    /// 控制条“对照浏览”开关:未对照且满足对照条件 → 进入并排;
    /// 已并排 → 退出,回到最近一次单看聚焦侧(该侧文档已不在时兜底回主侧)。
    /// 不足两个可对照 PDF 时 no-op(按钮同时处于禁用态,这里是最后一道守卫)。
    func toggleSideBySide() {
        if effectiveLayout == .sideBySide {
            let side: ViewerSide = (lastSingleFocus == .secondary && secondary != nil) ? .secondary : .primary
            layout = .single(side)
        } else if comparisonEnabled {
            layout = .sideBySide
        }
    }

    /// 点标签:聚焦该文档并前置查看器(首页点标签 = 回到查看器)。
    func focusTab(_ side: ViewerSide) {
        layout = .single(side)
        isViewerVisible = true
    }

    /// 关标签:关副文档回单文档;关主文档时副文档晋升(晋升不写历史);
    /// 关最后一个标签回到纯首页。
    func closeTab(_ side: ViewerSide) {
        switch side {
        case .secondary:
            secondary = nil
            secondaryZoom = SideZoomState()
            secondaryPage = SidePageState()
            pageLinkOffset = 0
            layout = .single(.primary)
            resetRatios()
        case .primary:
            // 页状态迁移与文档/缩放晋升解耦:不依赖 `secondary` 是否有真实文档
            // ——没有真实副文档时 secondaryPage 本就是默认值,这里的赋值等价于重置,
            // 与"关最后一个标签"分支的目标状态一致,同时让页状态可以脱离真实 PDF 单独测试。
            primaryPage = secondaryPage
            secondaryPage = SidePageState()
            pageLinkOffset = 0
            if let promoted = secondary {
                primary = promoted
                secondary = nil
                // 晋升者带着自己的缩放记忆上位(不重置、不补发命令);
                // 腾出的 secondary 档位回干净默认。文档更换后的命令重放由
                // SinglePDFView 的 noteDocumentChanged(revision 归 nil)保证。
                primaryZoom = secondaryZoom
                secondaryZoom = SideZoomState()
                layout = .single(.primary)
                resetRatios()
            } else {
                primary = nil
                primaryZoom = SideZoomState()
                layout = .single(.primary)
                isViewerVisible = false
            }
        }
    }

    func resetRatios() {
        ratioA = 1.0
        ratioB = 1.0
    }

    var isDefaultRatio: Bool {
        abs(ratioA - 1.0) < 0.001 && abs(ratioB - 1.0) < 0.001
    }

    // MARK: - 打开文档

    /// 从首页/工具栏打开:自动填空位(先主后副)并聚焦;已满 2 个则弹提示。
    func open(url: URL) {
        if primary == nil {
            load(url, side: .primary)
        } else if secondary == nil {
            load(url, side: .secondary)
        } else {
            alert = ViewerAlert(title: L10n.t("viewer.tabsFull"), message: url.lastPathComponent)
        }
    }

    /// 翻译完成"立即对照查看":整体替换会话内容并直接进入对照。
    func replacePair(source: URL, output: URL) {
        primary = nil
        secondary = nil
        layout = .single(.primary)
        resetRatios()
        primaryPage = SidePageState()
        secondaryPage = SidePageState()
        pageLinkOffset = 0
        load(source, side: .primary)
        load(output, side: .secondary)
        if primary != nil && secondary != nil {
            layout = .sideBySide
        }
    }

    func submitPassword(_ password: String) {
        guard let request = passwordRequest else { return }
        passwordRequest = nil
        load(request.url, side: request.side, password: password)
    }

    func cancelPasswordRequest() {
        passwordRequest = nil
        passwordFailure = nil
    }

    func load(_ url: URL, side: ViewerSide, password: String? = nil) {
        let kind = Self.kind(for: url)

        switch kind {
        case .unsupported:
            if side == .primary {
                assign(ViewerDocument(url: url, kind: .unsupported, password: nil), side: side)
            }
            alert = ViewerAlert(title: L10n.t("viewer.unsupported"), message: url.lastPathComponent)
        case .text:
            guard Self.canReadText(url) else {
                if side == .primary {
                    assign(ViewerDocument(url: url, kind: .unsupported, password: nil), side: side)
                }
                alert = ViewerAlert(title: L10n.t("viewer.openFailed"), message: url.lastPathComponent)
                return
            }
            assign(ViewerDocument(url: url, kind: .text, password: nil), side: side)
            recordOpen(url, side: side)
        case .pdf:
            do {
                let document = try PDFTextExtractor.openDocument(at: url, password: password)
                assign(ViewerDocument(url: url, kind: .pdf, password: password), side: side, pageCount: document.pageCount)
                passwordFailure = nil
                recordOpen(url, side: side)
            } catch PDFLabError.encryptedPDFWrongPassword {
                passwordFailure = password == nil ? nil : L10n.message(for: .encryptedPDFWrongPassword)
                passwordRequest = ViewerPasswordRequest(url: url, side: side)
            } catch let error as PDFLabError {
                if side == .primary {
                    assign(ViewerDocument(url: url, kind: .unsupported, password: nil), side: side)
                }
                alert = ViewerAlert(title: L10n.t("viewer.openFailed"), message: L10n.message(for: error))
            } catch {
                if side == .primary {
                    assign(ViewerDocument(url: url, kind: .unsupported, password: nil), side: side)
                }
                alert = ViewerAlert(title: L10n.t("viewer.openFailed"), message: error.localizedDescription)
            }
        }
    }

    private func recordOpen(_ url: URL, side: ViewerSide) {
        // 需求 3.1:历史只记录主文件(左侧首个文档),加载的译文对照文件不入历史。
        guard side == .primary else { return }
        onRecordOpen?(url)
    }

    private func assign(_ document: ViewerDocument, side: ViewerSide, pageCount: Int = 0) {
        switch side {
        case .primary:
            primary = document
        case .secondary:
            // 每次进入/更换对照文档时把滚动比例恢复默认,不带上次残留值。
            resetRatios()
            secondary = document
            layout = .single(.secondary)
        }
        // 每次成功装入/替换文档只重置该侧缩放为默认实际大小 100%。
        resetZoom(on: side)
        // 每次成功装入/替换文档只重置该侧页状态;副侧另需清掉锚点偏移
        // (旧偏移是相对旧文档的,换文档后不再有意义)。
        switch side {
        case .primary:
            primaryPage = SidePageState(pageCount: pageCount)
        case .secondary:
            secondaryPage = SidePageState(pageCount: pageCount)
            pageLinkOffset = 0
        }
        // 任何成功装入的文档都把查看器前置(含密码解锁后)。
        isViewerVisible = true
    }

    private static func kind(for url: URL) -> ViewerDocumentKind {
        switch url.pathExtension.lowercased() {
        case "pdf":
            return .pdf
        case "md", "markdown", "txt", "text":
            return .text
        default:
            return .unsupported
        }
    }

    private static func canReadText(_ url: URL) -> Bool {
        ViewerTextLoader.load(from: url) != nil
    }
}
