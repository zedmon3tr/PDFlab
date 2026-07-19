import CoreGraphics
import CryptoKit
import PDFKit

/// 将页组映射写入 PDF 的 XMP Metadata stream，并从 PDFKit 文档中安全读回。
/// 自有 payload 使用 base64 JSON，避免 XML 转义与本地化文本影响解析。
public enum PDFPageGroupMetadata {
    private static let payloadElement = "pdflab:PageGroupMap"
    private static let maximumMetadataBytes = 1_048_576

    static func xmpData(for map: PageGroupMap) throws -> Data {
        let json = try JSONEncoder().encode(map)
        let payload = json.base64EncodedString()
        let xml = """
        <?xpacket begin="\u{FEFF}" id="W5M0MpCehiHzreSzNTczkc9d"?>
        <x:xmpmeta xmlns:x="adobe:ns:meta/">
          <rdf:RDF xmlns:rdf="http://www.w3.org/1999/02/22-rdf-syntax-ns#">
            <rdf:Description rdf:about="" xmlns:pdflab="https://pdflab.app/ns/1.0/">
              <\(payloadElement)>\(payload)</\(payloadElement)>
            </rdf:Description>
          </rdf:RDF>
        </x:xmpmeta>
        <?xpacket end="w"?>
        """
        guard let data = xml.data(using: .utf8) else {
            throw PDFLabError.exportWriteFailed("Unable to encode PDF page-group metadata")
        }
        return data
    }

    static func add(_ map: PageGroupMap, to context: CGContext) throws {
        context.addDocumentMetadata(try xmpData(for: map) as CFData)
    }

    /// 内容指纹用于证明译文页组属于当前左侧源 PDF，而不是另一份恰好页数相同的文件。
    public static func sourceFingerprint(for url: URL) -> String? {
        guard let data = try? Data(contentsOf: url, options: .mappedIfSafe) else { return nil }
        return SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }

    public static func read(from document: PDFDocument) -> PageGroupMap? {
        guard let documentRef = document.documentRef,
              let catalog = documentRef.catalog
        else { return nil }

        var stream: CGPDFStreamRef?
        guard CGPDFDictionaryGetStream(catalog, "Metadata", &stream),
              let stream
        else { return nil }

        if let dictionary = CGPDFStreamGetDictionary(stream) {
            var encodedLength: CGPDFInteger = 0
            if CGPDFDictionaryGetInteger(dictionary, "Length", &encodedLength),
               (encodedLength < 0 || encodedLength > maximumMetadataBytes) {
                return nil
            }
        }

        var format = CGPDFDataFormat.raw
        guard let copied = CGPDFStreamCopyData(stream, &format) else { return nil }
        let data = copied as Data
        guard data.count <= maximumMetadataBytes,
              let xml = String(data: data, encoding: .utf8)
        else { return nil }

        let opening = "<\(payloadElement)>"
        let closing = "</\(payloadElement)>"
        guard let start = xml.range(of: opening)?.upperBound,
              let end = xml.range(of: closing, range: start..<xml.endIndex)?.lowerBound,
              start < end
        else { return nil }

        let payload = String(xml[start..<end]).trimmingCharacters(in: .whitespacesAndNewlines)
        guard let json = Data(base64Encoded: payload), json.count <= maximumMetadataBytes else { return nil }
        return try? JSONDecoder().decode(PageGroupMap.self, from: json)
    }
}
