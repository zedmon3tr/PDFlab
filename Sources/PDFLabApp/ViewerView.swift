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

    var body: some View {
        VStack(spacing: 0) {
            if showsControlBar {
                controlBar
                Divider()
            }
            viewerContent
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
            onScaleChange: { [weak session] scale in
                session?.noteObservedZoomScale(scale)
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
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 4)
    }

    /// [-] [100%] [+]:按钮 32×32、百分比静态文本框 56×32、间距 2。
    private var zoomControl: some View {
        HStack(spacing: ViewerControlBarMetrics.itemSpacing) {
            controlBarIconButton("minus", labelKey: "viewer.zoomOut") {
                session.zoomOut()
            }
            Text(ViewerZoom.percentLabel(for: session.zoomScale))
                .font(.callout)
                .monospacedDigit()
                .frame(
                    width: ViewerControlBarMetrics.percentWidth,
                    height: ViewerControlBarMetrics.buttonSize
                )
                .background(
                    .quaternary.opacity(0.5),
                    in: RoundedRectangle(cornerRadius: ViewerControlBarMetrics.cornerRadius)
                )
                .accessibilityLabel(L10n.t("viewer.zoom"))
                .help(L10n.t("viewer.zoom"))
            controlBarIconButton("plus", labelKey: "viewer.zoomIn") {
                session.zoomIn()
            }
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
}

/// 控制条度量(Figma "viewing pdf" 帧)。
enum ViewerControlBarMetrics {
    /// 加/减按钮边长(命中区,≥ DESIGN.md 图标按钮 24×24 下限)。
    static let buttonSize: CGFloat = 32
    /// 百分比静态文本框宽度。
    static let percentWidth: CGFloat = 56
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
}

enum ViewerComparisonPolicy {
    static func isEnabled(
        primaryKind: ViewerDocumentKind?,
        secondaryKind: ViewerDocumentKind?
    ) -> Bool {
        primaryKind == .pdf && secondaryKind == .pdf
    }
}
