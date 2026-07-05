import AppKit
import PDFKit
import SwiftUI
import UniformTypeIdentifiers
import PDFLabCore

struct ViewerView: View {
    static var openableContentTypes: [UTType] {
        ViewerSecondaryDocumentPicker.allowedContentTypes
    }

    let url: URL
    let secondaryURL: URL?
    let onDocumentOpened: (URL) -> Void
    let onClose: () -> Void

    @EnvironmentObject private var app: AppState

    @State private var didLoad = false
    @State private var primary: ViewerDocument?
    @State private var secondary: ViewerDocument?
    @State private var ratioA = 1.0
    @State private var ratioB = 1.0
    @State private var alert: ViewerAlert?
    @State private var passwordRequest: PasswordRequest?
    @State private var passwordInput = ""
    @State private var passwordFailure: String?

    init(
        url: URL,
        secondaryURL: URL? = nil,
        onDocumentOpened: @escaping (URL) -> Void = { _ in },
        onClose: @escaping () -> Void = {}
    ) {
        self.url = url
        self.secondaryURL = secondaryURL
        self.onDocumentOpened = onDocumentOpened
        self.onClose = onClose
    }

    var body: some View {
        VStack(spacing: 0) {
            documentTabBar
            Divider()
            viewerContent
        }
            .navigationTitle(primary?.title ?? url.lastPathComponent)
            .toolbar {
                ToolbarItemGroup {
                    if secondary != nil {
                        ratioControl(L10n.t("viewer.leftRatio"), value: $ratioA)
                        ratioControl(L10n.t("viewer.rightRatio"), value: $ratioB)
                        resetRatioButton
                    }
                }
            }
            .onAppear(perform: loadInitialDocuments)
            .alert(item: $alert) { item in
                Alert(
                    title: Text(item.title),
                    message: Text(item.message),
                    dismissButton: .default(Text(L10n.t("common.confirm")))
                )
            }
            .alert(
                L10n.t("viewer.password.title"),
                isPresented: Binding(
                    get: { passwordRequest != nil },
                    set: { isPresented in
                        if !isPresented {
                            passwordRequest = nil
                            passwordInput = ""
                            passwordFailure = nil
                        }
                    }
                )
            ) {
                SecureField(L10n.t("viewer.password.prompt"), text: $passwordInput)
                Button(L10n.t("viewer.password.open")) {
                    guard let request = passwordRequest else { return }
                    let password = passwordInput
                    passwordRequest = nil
                    passwordInput = ""
                    load(request.url, side: request.side, password: password)
                }
                Button(L10n.t("common.cancel"), role: .cancel) {
                    passwordRequest = nil
                    passwordInput = ""
                    passwordFailure = nil
                }
            } message: {
                if let passwordFailure {
                    Text(passwordFailure)
                } else {
                    Text(passwordRequest?.url.lastPathComponent ?? "")
                }
            }
    }

    @ViewBuilder
    private var viewerContent: some View {
        if let primary {
            if let secondary {
                DualPaneController(left: primary, right: secondary, ratioA: ratioA, ratioB: ratioB)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                SingleDocumentView(document: primary)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        } else {
            Text(L10n.t("viewer.noDocument"))
                .foregroundStyle(.secondary)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }

    // MARK: - Chrome 式文档标签条

    @ViewBuilder
    private var documentTabBar: some View {
        HStack(spacing: 6) {
            if let primary {
                documentTab(title: primary.title) { closePrimary() }
            }
            if let secondary {
                documentTab(title: secondary.title) { closeSecondary() }
            }
            // 已开 2 个文档时隐藏 "+"(最多 2 个)。
            if primary == nil || secondary == nil {
                Button {
                    openSecondaryDocument()
                } label: {
                    Image(systemName: "plus")
                        .font(.callout.weight(.medium))
                }
                .buttonStyle(HoverButtonStyle(variant: .toolbar))
                .help(L10n.t("viewer.addTab"))
            }
            Spacer()
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 6)
        .background(.quaternary.opacity(0.35))
    }

    private func documentTab(title: String, onCloseTab: @escaping () -> Void) -> some View {
        HStack(spacing: 6) {
            Text(title)
                .font(.callout)
                .lineLimit(1)
                .truncationMode(.middle)
                .frame(maxWidth: 220, alignment: .leading)
            Button(action: onCloseTab) {
                Image(systemName: "xmark")
                    .font(.system(size: 9, weight: .bold))
            }
            .buttonStyle(TabCloseButtonStyle())
            .help(L10n.t("viewer.closeTab"))
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 5)
        .background(.background, in: RoundedRectangle(cornerRadius: 7))
        .overlay(
            RoundedRectangle(cornerRadius: 7)
                .strokeBorder(Color.primary.opacity(0.10), lineWidth: 1)
        )
    }

    // 关闭 secondary:回到 primary 单文档。
    private func closeSecondary() {
        secondary = nil
        ratioA = 1.0
        ratioB = 1.0
    }

    // 关闭 primary:secondary 晋升为唯一文档(晋升不写历史);无 secondary 则返回主界面。
    private func closePrimary() {
        if let promoted = secondary {
            primary = promoted
            secondary = nil
            ratioA = 1.0
            ratioB = 1.0
        } else {
            onClose()
        }
    }

    // macOS 工具栏常不渲染 Stepper 的 label,数值必须用独立 Text 显式呈现。
    private func ratioControl(_ title: String, value: Binding<Double>) -> some View {
        HStack(spacing: 4) {
            Text("\(title) \(Int((value.wrappedValue * 100).rounded()))%")
                .monospacedDigit()
                .frame(minWidth: 72, alignment: .trailing)
            Stepper(title, value: value, in: 0.5...2.0, step: 0.1)
                .labelsHidden()
        }
    }

    private var isDefaultRatio: Bool {
        abs(ratioA - 1.0) < 0.001 && abs(ratioB - 1.0) < 0.001
    }

    private var resetRatioButton: some View {
        Button {
            ratioA = 1.0
            ratioB = 1.0
        } label: {
            Label(L10n.t("viewer.resetRatio"), systemImage: "arrow.counterclockwise")
        }
        .buttonStyle(HoverButtonStyle(variant: .toolbar))
        .disabled(isDefaultRatio)
        .help(L10n.t("viewer.resetRatio"))
    }

    private func loadInitialDocuments() {
        guard !didLoad else { return }
        didLoad = true
        load(url, side: .primary)
        if let secondaryURL {
            load(secondaryURL, side: .secondary)
        }
    }

    private func openSecondaryDocument() {
        guard let picked = ViewerSecondaryDocumentPicker.pick() else { return }
        load(picked, side: .secondary)
    }

    private func load(_ url: URL, side: ViewerSide, password: String? = nil) {
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
                _ = try PDFTextExtractor.openDocument(at: url, password: password)
                assign(ViewerDocument(url: url, kind: .pdf, password: password), side: side)
                passwordFailure = nil
                recordOpen(url, side: side)
            } catch PDFLabError.encryptedPDFWrongPassword {
                passwordFailure = password == nil ? nil : L10n.message(for: .encryptedPDFWrongPassword)
                passwordRequest = PasswordRequest(url: url, side: side)
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
        app.history.record(url: url)
        onDocumentOpened(url)
    }

    private func assign(_ document: ViewerDocument, side: ViewerSide) {
        switch side {
        case .primary:
            primary = document
        case .secondary:
            // 每次进入/更换对照文档时把滚动比例恢复默认,不带上次残留值。
            ratioA = 1.0
            ratioB = 1.0
            secondary = document
        }
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

/// 标签页 × 关闭按钮:小圆形命中区,hover 显示浅底 + pointingHand。
private struct TabCloseButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        TabCloseButtonBody(configuration: configuration)
    }

    private struct TabCloseButtonBody: View {
        let configuration: ButtonStyle.Configuration
        @State private var isHovering = false

        var body: some View {
            configuration.label
                .foregroundStyle(isHovering ? AnyShapeStyle(.primary) : AnyShapeStyle(.secondary))
                .frame(width: 16, height: 16)
                .background(
                    Circle().fill(Color.primary.opacity(isHovering ? 0.12 : 0.0))
                )
                .opacity(configuration.isPressed ? 0.7 : 1)
                .animation(.easeOut(duration: 0.1), value: isHovering)
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
}

private enum ViewerSide {
    case primary
    case secondary
}

private struct PasswordRequest {
    var url: URL
    var side: ViewerSide
}

private struct ViewerAlert: Identifiable {
    let id = UUID()
    var title: String
    var message: String
}

private struct SingleDocumentView: View {
    var document: ViewerDocument

    var body: some View {
        switch document.kind {
        case .pdf:
            SinglePDFView(document: document)
        case .text:
            ScrollView {
                Text(ViewerTextLoader.load(from: document.url) ?? L10n.t("viewer.openFailed"))
                    .font(.body)
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(24)
            }
        case .unsupported:
            Text(L10n.t("viewer.unsupported"))
                .foregroundStyle(.secondary)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }
}

private struct SinglePDFView: NSViewRepresentable {
    var document: ViewerDocument

    func makeCoordinator() -> Coordinator {
        Coordinator()
    }

    func makeNSView(context: Context) -> PDFView {
        let pdfView = PDFView()
        configure(pdfView, context: context)
        return pdfView
    }

    func updateNSView(_ pdfView: PDFView, context: Context) {
        configure(pdfView, context: context)
    }

    private func configure(_ pdfView: PDFView, context: Context) {
        guard context.coordinator.documentID != document.id else { return }
        context.coordinator.documentID = document.id

        pdfView.displayMode = .singlePageContinuous
        pdfView.displayDirection = .vertical
        pdfView.displaysPageBreaks = true
        pdfView.autoScales = true
        pdfView.backgroundColor = .textBackgroundColor
        pdfView.document = try? PDFTextExtractor.openDocument(at: document.url, password: document.password)
    }

    final class Coordinator {
        var documentID: String?
    }
}
