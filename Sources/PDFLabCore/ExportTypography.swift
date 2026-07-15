import CoreGraphics

enum ExportParagraphSpacing: Equatable, Sendable {
    case intraGroup
    case outer
}

enum ExportTextAlignment: Equatable, Sendable {
    case left
}

struct ExportParagraphLayout: Equatable, Sendable {
    var lineHeight: CGFloat
    var paragraphSpacing: CGFloat
    var firstLineIndent: CGFloat
    var alignment: ExportTextAlignment
}

/// PDF 与 Word 共用的正文排版决策，避免两个导出器的数值与语系规则分叉。
enum ExportTypography {
    static let pageWidth: CGFloat = 595
    static let pageHeight: CGFloat = 842
    static let margin: CGFloat = 60
    static let fontSize: CGFloat = 12
    static let lineHeight: CGFloat = fontSize * 1.4
    static let contentWidth: CGFloat = pageWidth - 2 * margin
    static let sourceGray: CGFloat = 0.30
    static let intraGroupSpacing: CGFloat = 3

    static func layout(for text: String, spacingAfter: ExportParagraphSpacing) -> ExportParagraphLayout {
        let cjk = isCJKParagraph(text)
        let paragraphSpacing: CGFloat
        switch spacingAfter {
        case .intraGroup:
            paragraphSpacing = intraGroupSpacing
        case .outer:
            paragraphSpacing = cjk ? 4.2 : 8.4
        }
        return ExportParagraphLayout(
            lineHeight: lineHeight,
            paragraphSpacing: paragraphSpacing,
            firstLineIndent: cjk ? fontSize * 2 : 0,
            alignment: .left
        )
    }

    static func isCJKParagraph(_ text: String) -> Bool {
        guard let character = firstEffectiveCharacter(in: text) else { return false }
        return ParagraphBuilder.isCJK(character)
    }

    private static func firstEffectiveCharacter(in text: String) -> Character? {
        for character in text {
            guard let scalar = character.unicodeScalars.first else { continue }
            if scalar.properties.isWhitespace { continue }
            switch scalar.properties.generalCategory {
            case .decimalNumber, .letterNumber, .otherNumber,
                 .connectorPunctuation, .dashPunctuation, .openPunctuation,
                 .closePunctuation, .initialPunctuation, .finalPunctuation,
                 .otherPunctuation, .mathSymbol, .currencySymbol,
                 .modifierSymbol, .otherSymbol:
                continue
            default:
                return character
            }
        }
        return nil
    }

    static func spacingAfter(blockAt index: Int, in blocks: [ComposedBlock]) -> ExportParagraphSpacing {
        guard case let .sourceText(current) = blocks[index],
              let groupID = current.groupID,
              blocks.indices.contains(index + 1),
              case let .translatedText(next) = blocks[index + 1],
              next.groupID == groupID else {
            return .outer
        }
        return .intraGroup
    }
}
