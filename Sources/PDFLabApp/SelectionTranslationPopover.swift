import AppKit
import PDFKit
import SwiftUI
import PDFLabCore

// MARK: - 可测纯逻辑:选区文本清洗

/// 划选选区文本的清洗规则(纯函数,可单测):
/// - 空 / 纯空白 → nil(不弹气泡);
/// - 空白归一:PDF 划选常把段落按行断开,重接时 CJK 相邻直接连接、其余以单空格连接;
/// - 超长截断到 `maxLength`(气泡场景保护引擎与 UI,不做整页翻译)。
enum SelectionTranslationText {
    /// 单次气泡翻译的字符上限。
    static let maxLength = 2000

    static func cleaned(_ raw: String?) -> String? {
        guard let raw, !raw.isEmpty else { return nil }
        let tokens = raw.split(whereSeparator: \.isWhitespace)
        guard !tokens.isEmpty else { return nil }

        var result = ""
        for token in tokens {
            if result.isEmpty {
                result = String(token)
            } else if let prev = result.last, let next = token.first, isCJK(prev), isCJK(next) {
                result += token
            } else {
                result += " " + token
            }
        }
        if result.count > maxLength {
            result = String(result.prefix(maxLength))
        }
        return result
    }

    private static func isCJK(_ character: Character) -> Bool {
        guard let scalar = character.unicodeScalars.first else { return false }
        // CJK 部首/统一表意区 + 全角标点区(与 ParagraphBuilder 的连接规则同一口径)。
        return (0x2E80...0x9FFF).contains(scalar.value) || (0xFF00...0xFFEF).contains(scalar.value)
    }
}

// MARK: - 可测纯逻辑:失败态文案映射

/// 气泡失败态呈现:错误文案(复用 `L10n.message(for:)`,不重写映射)+ 是否附
/// 「建议切换翻译引擎」提示。引擎/网络类失败建议切换;非中英选区(unsupportedLanguage)
/// 等按原样内联显示,切引擎也解决不了。
enum SelectionBubbleFailure {
    static func presentation(for error: Error) -> (message: String, suggestsEngineSwitch: Bool) {
        guard let error = error as? PDFLabError else {
            return (error.localizedDescription, false)
        }
        switch error {
        case .engineInvalidKey, .engineRateLimited, .engineUnavailable, .networkError, .languagePackMissing:
            return (L10n.message(for: error), true)
        default:
            return (L10n.message(for: error), false)
        }
    }
}

// MARK: - 气泡内容(SwiftUI)

@MainActor
final class SelectionBubbleModel: ObservableObject {
    enum State {
        case loading
        case translated(String)
        case failed(message: String, suggestsEngineSwitch: Bool)
    }

    let sourceText: String
    @Published var state: State = .loading

    init(sourceText: String) {
        self.sourceText = sourceText
    }
}

struct SelectionBubbleView: View {
    @ObservedObject var model: SelectionBubbleModel

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(model.sourceText)
                .font(.callout)
                .foregroundStyle(.secondary)
                .lineLimit(4)
                .truncationMode(.tail)

            Divider()

            switch model.state {
            case .loading:
                HStack {
                    Spacer()
                    ProgressView()
                        .controlSize(.small)
                    Spacer()
                }
                .padding(.vertical, 4)
            case .translated(let text):
                if text.count > 600 {
                    // 长译文限高滚动,避免气泡超出屏幕。
                    ScrollView {
                        translatedText(text)
                    }
                    .frame(height: 280)
                } else {
                    translatedText(text)
                }
            case .failed(let message, let suggestsEngineSwitch):
                VStack(alignment: .leading, spacing: 4) {
                    Text(message)
                        .font(.callout)
                        .foregroundStyle(.red)
                    if suggestsEngineSwitch {
                        Text(L10n.t("viewer.bubble.suggestSwitch"))
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
            }
        }
        .padding(12)
        .frame(width: 320, alignment: .leading)
    }

    private func translatedText(_ text: String) -> some View {
        Text(text)
            .font(.body)
            .textSelection(.enabled)
            .frame(maxWidth: .infinity, alignment: .leading)
    }
}

// MARK: - 气泡控制器

/// 划选即时翻译气泡控制器:一个查看面板(PDFView 或 NSTextView)配一个实例。
///
/// 时机判定(选 NSEvent 本地监听而非 0.3s 去抖):选区变化通知在拖选过程中持续触发,
/// 仅在鼠标左键按下期间标记"待评估",等 `leftMouseUp` 事件到达后再评估弹泡——
/// 气泡恰在松开瞬间出现,无人为延迟;去抖方案在慢速拖选停顿时会提前闪泡,故不取。
///
/// 关闭语义:滚动(scrollWheel 监听,气泡内部滚动除外)、翻页(PDFViewPageChanged)、
/// 点击气泡外(NSPopover `.transient`)、新划选(先关旧再开新)、点击空白清空选区。
@MainActor
final class SelectionTranslationController: NSObject, NSPopoverDelegate {
    private let translation: ViewerTranslationService

    private weak var pdfView: PDFView?
    private weak var textView: NSTextView?

    private var notificationObservers: [NSObjectProtocol] = []
    private var eventMonitor: Any?

    /// 拖选中(左键按下)发生过选区变化,等松开后评估。
    private var pendingEvaluation = false

    private var popover: NSPopover?
    private var translationTask: Task<Void, Never>?

    /// init 保持 nonisolated:仅存入 Sendable 的 service,便于非隔离的
    /// representable Coordinator 直接持有(挂接经 attach 在主线程完成)。
    nonisolated init(translation: ViewerTranslationService) {
        self.translation = translation
    }

    // MARK: 挂接 / 拆除

    func attach(to pdfView: PDFView) {
        self.pdfView = pdfView
        observe(name: .PDFViewSelectionChanged, object: pdfView) { [weak self] in
            self?.markPendingIfDragging()
        }
        // 翻页(键盘/跳转)关闭气泡;连续滚动翻页由 scrollWheel 分支覆盖。
        observe(name: .PDFViewPageChanged, object: pdfView) { [weak self] in
            self?.closeBubble()
        }
        installEventMonitorIfNeeded()
    }

    func attach(to textView: NSTextView) {
        self.textView = textView
        observe(name: NSTextView.didChangeSelectionNotification, object: textView) { [weak self] in
            self?.markPendingIfDragging()
        }
        installEventMonitorIfNeeded()
    }

    func detach() {
        for observer in notificationObservers {
            NotificationCenter.default.removeObserver(observer)
        }
        notificationObservers.removeAll()
        if let eventMonitor {
            NSEvent.removeMonitor(eventMonitor)
            self.eventMonitor = nil
        }
        closeBubble()
    }

    deinit {
        // 正常路径由宿主在 dismantleNSView 里显式 detach;这里兜底防监听器泄漏。
        if let eventMonitor {
            NSEvent.removeMonitor(eventMonitor)
        }
        for observer in notificationObservers {
            NotificationCenter.default.removeObserver(observer)
        }
    }

    /// 挂通知观察(queue 固定 .main,故 assumeIsolated 安全)。
    private func observe(name: Notification.Name, object: AnyObject, handler: @escaping @MainActor () -> Void) {
        let observer = NotificationCenter.default.addObserver(
            forName: name,
            object: object,
            queue: .main
        ) { _ in
            MainActor.assumeIsolated(handler)
        }
        notificationObservers.append(observer)
    }

    /// 仅左键按下期间的选区变化才标记待评估:排除键盘改选等无 mouseUp 跟随的路径,
    /// 避免陈旧标记在之后某次无关点击时突然弹泡。
    private func markPendingIfDragging() {
        if NSEvent.pressedMouseButtons & 0x1 != 0 {
            pendingEvaluation = true
        }
    }

    // MARK: 事件监听

    private func installEventMonitorIfNeeded() {
        guard eventMonitor == nil else { return }
        // 本地监听回调总在主线程(事件派发线程),assumeIsolated 安全。
        eventMonitor = NSEvent.addLocalMonitorForEvents(matching: [.leftMouseUp, .scrollWheel]) { [weak self] event in
            MainActor.assumeIsolated {
                self?.handle(event)
            }
            return event
        }
    }

    private func handle(_ event: NSEvent) {
        switch event.type {
        case .scrollWheel:
            // 任何滚动都关闭气泡(在气泡自己的窗口里滚动除外,如滚动长译文)。
            if let popover, popover.isShown,
               event.window !== popover.contentViewController?.view.window {
                closeBubble()
            }
        case .leftMouseUp:
            guard pendingEvaluation else { return }
            pendingEvaluation = false
            guard event.window === hostView?.window else { return }
            // 本地监听先于事件派发触发;等本轮事件送达视图、选区落定后再评估
            // (Task 继承 MainActor,排到当前事件处理之后执行)。
            Task { [weak self] in
                self?.evaluateSelection()
            }
        default:
            break
        }
    }

    private var hostView: NSView? {
        pdfView ?? textView
    }

    // MARK: 选区评估

    private func evaluateSelection() {
        if let pdfView {
            evaluatePDFSelection(in: pdfView)
        } else if let textView {
            evaluateTextSelection(in: textView)
        }
    }

    private func evaluatePDFSelection(in pdfView: PDFView) {
        guard let selection = pdfView.currentSelection,
              let cleaned = SelectionTranslationText.cleaned(selection.string),
              let anchor = anchorRect(for: selection, in: pdfView) else {
            // 点击空白清空选区等 → 关闭。
            closeBubble()
            return
        }
        show(sourceText: cleaned, relativeTo: anchor, of: pdfView)
    }

    private func evaluateTextSelection(in textView: NSTextView) {
        let range = textView.selectedRange()
        guard range.length > 0 else {
            closeBubble()
            return
        }
        let raw = (textView.string as NSString).substring(with: range)
        guard let cleaned = SelectionTranslationText.cleaned(raw),
              let anchor = anchorRect(for: range, in: textView) else {
            closeBubble()
            return
        }
        show(sourceText: cleaned, relativeTo: anchor, of: textView)
    }

    /// PDF 选区锚点:取选区所在页中第一个可见的 bounds(页坐标 → 视图坐标,截到可见区)。
    private func anchorRect(for selection: PDFSelection, in pdfView: PDFView) -> NSRect? {
        for page in selection.pages {
            let rect = pdfView.convert(selection.bounds(for: page), from: page)
            let visible = rect.intersection(pdfView.visibleRect)
            if !visible.isEmpty {
                return visible
            }
        }
        return nil
    }

    /// NSTextView 选区锚点:layoutManager 的字形包围盒 + 容器原点偏移,截到可见区。
    private func anchorRect(for range: NSRange, in textView: NSTextView) -> NSRect? {
        guard let layoutManager = textView.layoutManager,
              let container = textView.textContainer else { return nil }
        let glyphRange = layoutManager.glyphRange(forCharacterRange: range, actualCharacterRange: nil)
        var rect = layoutManager.boundingRect(forGlyphRange: glyphRange, in: container)
        rect.origin.x += textView.textContainerOrigin.x
        rect.origin.y += textView.textContainerOrigin.y
        let visible = rect.intersection(textView.visibleRect)
        return visible.isEmpty ? nil : visible
    }

    // MARK: 气泡展示

    private func show(sourceText: String, relativeTo rect: NSRect, of view: NSView) {
        // 新划选先关旧气泡(含取消进行中的翻译任务),不叠泡。
        closeBubble()

        let model = SelectionBubbleModel(sourceText: sourceText)
        let hosting = NSHostingController(rootView: SelectionBubbleView(model: model))
        hosting.sizingOptions = .preferredContentSize

        let popover = NSPopover()
        popover.behavior = .transient
        popover.animates = false
        popover.contentViewController = hosting
        popover.delegate = self
        self.popover = popover

        var anchor = rect
        anchor.size.width = max(anchor.width, 1)
        anchor.size.height = max(anchor.height, 1)
        // 显示在选区下方:flipped 视图(PDFView/NSTextView 文档侧)maxY 是视觉下缘。
        popover.show(relativeTo: anchor, of: view, preferredEdge: view.isFlipped ? .maxY : .minY)

        translationTask = Task { [translation] in
            do {
                let result = try await translation.translate(sourceText)
                model.state = .translated(result.text)
            } catch is CancellationError {
                // 新划选/关闭时取消旧任务:静默。
            } catch PDFLabError.cancelled {
                // 同上。
            } catch {
                let presentation = SelectionBubbleFailure.presentation(for: error)
                model.state = .failed(
                    message: presentation.message,
                    suggestsEngineSwitch: presentation.suggestsEngineSwitch
                )
            }
        }
    }

    private func closeBubble() {
        translationTask?.cancel()
        translationTask = nil
        if let popover, popover.isShown {
            popover.performClose(nil)
        }
        popover = nil
    }

    // MARK: NSPopoverDelegate

    /// transient 点击外部关闭时取消还在跑的翻译任务,不浪费引擎调用。
    nonisolated func popoverDidClose(_ notification: Notification) {
        Task { @MainActor in
            self.translationTask?.cancel()
            self.translationTask = nil
        }
    }
}
