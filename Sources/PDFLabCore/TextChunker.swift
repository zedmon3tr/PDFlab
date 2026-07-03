import Foundation
public enum TextChunker {
    public static func split(_ text: String, limit: Int) -> [String] {
        guard text.count > limit else { return [text] }
        var sentences: [String] = []
        var cur = ""
        for ch in text {
            cur.append(ch)
            if "。.!?!?".contains(ch) { sentences.append(cur); cur = "" }
        }
        if !cur.isEmpty { sentences.append(cur) }
        var chunks: [String] = []
        var buf = ""
        for var s in sentences {
            while s.count > limit {                       // 单句超限硬切
                if !buf.isEmpty { chunks.append(buf); buf = "" }
                chunks.append(String(s.prefix(limit)))
                s = String(s.dropFirst(limit))
            }
            if buf.count + s.count > limit { chunks.append(buf); buf = s }
            else { buf += s }
        }
        if !buf.isEmpty { chunks.append(buf) }
        return chunks
    }
}
