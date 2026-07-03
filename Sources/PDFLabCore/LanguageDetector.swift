import NaturalLanguage

/// 语言检测与翻译方向判定。取样本前 4000 字符经 NLLanguageRecognizer 检测。
public enum LanguageDetector {
    private static let sampleLimit = 4000

    private static func dominantLanguage(sample: String) -> NLLanguage? {
        let clipped = String(sample.prefix(sampleLimit))
        guard !clipped.isEmpty else { return nil }
        let recognizer = NLLanguageRecognizer()
        recognizer.processString(clipped)
        return recognizer.dominantLanguage
    }

    /// zh(简体或繁体)→ .zhToEn,en → .enToZh,其余(含无法判定)→ nil。
    public static func detectDirection(sample: String) -> TranslationDirection? {
        switch dominantLanguage(sample: sample) {
        case .simplifiedChinese, .traditionalChinese:
            return .zhToEn
        case .english:
            return .enToZh
        default:
            return nil
        }
    }

    /// 供错误提示显示的语言代码,如 "ja"。空串或无法判定返回 "unknown"。
    public static func detectedLanguageName(sample: String) -> String {
        dominantLanguage(sample: sample)?.rawValue ?? "unknown"
    }
}
