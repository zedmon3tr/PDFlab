import AppKit

enum ViewerDocumentKind: Equatable {
    case pdf
    case text
    case unsupported
}

struct ViewerDocument: Equatable, Identifiable {
    var url: URL
    var kind: ViewerDocumentKind
    var password: String?

    var id: String {
        "\(kind)-\(url.path)-\(password == nil ? "no-password" : "password")"
    }

    var title: String {
        url.lastPathComponent
    }
}

enum ViewerTextLoader {
    static func load(from url: URL) -> String? {
        for encoding in candidateEncodings {
            if let text = try? String(contentsOf: url, encoding: encoding) {
                return text
            }
        }
        return nil
    }

    private static let candidateEncodings: [String.Encoding] = [
        .utf8,
        .utf16,
        .unicode,
        .isoLatin1,
        .windowsCP1252,
    ]
}

/// 只读文本查看视图(NSScrollView + NSTextView)的统一构造:
/// 对照面板与单文档文本视图共用,保证外观与原生文字选择行为一致。
enum ViewerTextViewFactory {
    @MainActor
    static func makeScrollable(text: String) -> (scrollView: NSScrollView, textView: NSTextView) {
        let scrollView = NSScrollView()
        scrollView.hasVerticalScroller = true
        scrollView.hasHorizontalScroller = false
        scrollView.borderType = .noBorder
        scrollView.drawsBackground = true
        scrollView.backgroundColor = .textBackgroundColor

        let textView = NSTextView()
        textView.isEditable = false
        textView.isSelectable = true
        textView.isRichText = false
        textView.importsGraphics = false
        textView.font = .systemFont(ofSize: 14)
        textView.textColor = .labelColor
        textView.backgroundColor = .textBackgroundColor
        textView.textContainerInset = NSSize(width: 24, height: 24)
        textView.isHorizontallyResizable = false
        textView.isVerticallyResizable = true
        textView.autoresizingMask = [.width]
        textView.minSize = NSSize(width: 0, height: scrollView.contentSize.height)
        textView.maxSize = NSSize(width: CGFloat.greatestFiniteMagnitude, height: CGFloat.greatestFiniteMagnitude)
        textView.textContainer?.containerSize = NSSize(
            width: scrollView.contentSize.width,
            height: CGFloat.greatestFiniteMagnitude
        )
        textView.textContainer?.widthTracksTextView = true
        textView.string = text

        scrollView.documentView = textView
        return (scrollView, textView)
    }
}
