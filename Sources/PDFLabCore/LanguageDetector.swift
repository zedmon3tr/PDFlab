import NaturalLanguage

/// 语言检测与翻译方向判定。取样本前 4000 字符经 NLLanguageRecognizer 检测。
public enum LanguageDetector {
    private static let sampleLimit = 4000
    private static let englishMarkers: Set<String> = [
        "a", "about", "across", "after", "and", "assignment", "before", "class", "customer",
        "deliverables", "document", "english", "for", "from", "grading", "in", "is", "journey",
        "language", "of", "on", "please", "purpose", "schedule", "service", "source", "that",
        "the", "this", "to", "what", "with", "your"
    ]

    private static func dominantLanguage(sample: String) -> NLLanguage? {
        let clipped = String(sample.prefix(sampleLimit))
        guard !clipped.isEmpty else { return nil }
        let recognizer = NLLanguageRecognizer()
        recognizer.processString(clipped)
        return recognizer.dominantLanguage
    }

    /// zh(简体或繁体)→ .zhToEn,en → .enToZh,其余(含无法判定)→ nil。
    public static func detectDirection(sample: String) -> TranslationDirection? {
        switch detectOCRLanguage(sample: sample) {
        case .simplifiedChinese, .traditionalChinese:
            return .zhToEn
        case .english:
            return .enToZh
        default:
            return nil
        }
    }

    public static func detectOCRLanguage(sample: String) -> OCRLanguage? {
        switch dominantLanguage(sample: sample) {
        case .simplifiedChinese, .traditionalChinese:
            return .simplifiedChinese
        case .english:
            return .english
        case .japanese:
            return .japanese
        case .korean:
            return .korean
        default:
            return heuristicLanguage(sample: sample).language
        }
    }

    /// 供错误提示显示的语言代码,如 "ja"。空串或无法判定返回 "unknown"。
    public static func detectedLanguageName(sample: String) -> String {
        switch dominantLanguage(sample: sample) {
        case .simplifiedChinese, .traditionalChinese:
            return "zh"
        case .english:
            return "en"
        default:
            if let fallback = heuristicLanguage(sample: sample).languageCode {
                return fallback
            }
            return dominantLanguage(sample: sample)?.rawValue ?? "unknown"
        }
    }

    private static func heuristicLanguage(sample: String) -> (language: OCRLanguage?, languageCode: String?) {
        let clipped = String(sample.prefix(sampleLimit))
        guard !clipped.isEmpty else { return (nil, nil) }

        var hanCount = 0
        var kanaCount = 0
        var latinLetterCount = 0
        for scalar in clipped.unicodeScalars {
            switch scalar.value {
            case 0x4E00...0x9FFF:
                hanCount += 1
            case 0x3040...0x30FF:
                kanaCount += 1
            case 0x0041...0x005A, 0x0061...0x007A:
                latinLetterCount += 1
            default:
                break
            }
        }

        if kanaCount == 0, hanCount >= 8, hanCount > latinLetterCount {
            return (.simplifiedChinese, "zh")
        }

        let englishWordHits = clipped
            .lowercased()
            .split { !$0.isLetter }
            .reduce(into: 0) { count, word in
                if englishMarkers.contains(String(word)) {
                    count += 1
                }
        }
        if kanaCount == 0, latinLetterCount >= 40, englishWordHits >= 4 {
            return (.english, "en")
        }

        return (nil, nil)
    }
}
