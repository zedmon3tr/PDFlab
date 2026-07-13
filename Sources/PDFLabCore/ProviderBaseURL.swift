import Foundation

public enum ProviderBaseURL {
    /// Validates a provider base URL and returns a canonical value without trailing slashes.
    public static func normalize(_ raw: String) throws -> String {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard var components = URLComponents(string: trimmed),
              components.scheme?.lowercased() == "https",
              let host = components.host, !host.isEmpty,
              components.user == nil, components.password == nil,
              components.query == nil, components.fragment == nil else {
            throw PDFLabError.engineInvalidRequest
        }
        components.scheme = "https"
        var path = components.percentEncodedPath
        while path.count > 1 && path.hasSuffix("/") { path.removeLast() }
        components.percentEncodedPath = path == "/" ? "" : path
        guard let normalized = components.url?.absoluteString else { throw PDFLabError.engineInvalidRequest }
        return normalized
    }

    public static func endpoint(baseURL: String, path: String) throws -> URL {
        let base = try normalize(baseURL)
        let suffix = path.hasPrefix("/") ? path : "/\(path)"
        if base.hasSuffix(suffix) { guard let url = URL(string: base) else { throw PDFLabError.engineInvalidRequest }; return url }
        guard let url = URL(string: base + suffix) else { throw PDFLabError.engineInvalidRequest }
        return url
    }
}
