import PDFKit
import SwiftUI
import UniformTypeIdentifiers
import PDFLabCore

struct ViewerView: View {
    static var openableContentTypes: [UTType] {
        var types: [UTType] = [.pdf, .plainText, .text]
        for ext in ["md", "markdown", "docx"] {
            if let type = UTType(filenameExtension: ext) {
                types.append(type)
            }
        }
        return types
    }

    let url: URL
    let secondaryURL: URL?

    @EnvironmentObject private var app: AppState

    @State private var didLoad = false
    @State private var primary: ViewerDocument?
    @State private var secondary: ViewerDocument?
    @State private var ratioA = 1.0
    @State private var ratioB = 1.0
    @State private var showTranslationImporter = false
    @State private var alert: ViewerAlert?
    @State private var passwordRequest: PasswordRequest?
    @State private var passwordInput = ""
    @State private var passwordFailure: String?

    init(url: URL, secondaryURL: URL? = nil) {
        self.url = url
        self.secondaryURL = secondaryURL
    }

    var body: some View {
        viewerContent
            .navigationTitle(primary?.title ?? url.lastPathComponent)
            .toolbar {
                ToolbarItemGroup {
                    Button {
                        showTranslationImporter = true
                    } label: {
                        Label(L10n.t("viewer.addTranslation"), systemImage: "plus")
                    }

                    if secondary != nil {
                        ratioStepper(L10n.t("viewer.leftRatio"), value: $ratioA)
                        ratioStepper(L10n.t("viewer.rightRatio"), value: $ratioB)
                    }
                }
            }
            .onAppear(perform: loadInitialDocuments)
            .fileImporter(
                isPresented: $showTranslationImporter,
                allowedContentTypes: Self.openableContentTypes,
                allowsMultipleSelection: false
            ) { result in
                switch result {
                case .success(let urls):
                    guard let picked = urls.first else { return }
                    load(picked, side: .secondary)
                case .failure(let error):
                    alert = ViewerAlert(title: L10n.t("viewer.openFailed"), message: error.localizedDescription)
                }
            }
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

    private func ratioStepper(_ title: String, value: Binding<Double>) -> some View {
        Stepper(value: value, in: 0.5...2.0, step: 0.1) {
            Text("\(title) \(Int((value.wrappedValue * 100).rounded()))%")
                .frame(minWidth: 92, alignment: .leading)
        }
    }

    private func loadInitialDocuments() {
        guard !didLoad else { return }
        didLoad = true
        load(url, side: .primary)
        if let secondaryURL {
            load(secondaryURL, side: .secondary)
        }
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
            app.history.record(url: url)
        case .pdf:
            do {
                _ = try PDFTextExtractor.openDocument(at: url, password: password)
                assign(ViewerDocument(url: url, kind: .pdf, password: password), side: side)
                passwordFailure = nil
                app.history.record(url: url)
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

    private func assign(_ document: ViewerDocument, side: ViewerSide) {
        switch side {
        case .primary:
            primary = document
        case .secondary:
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
