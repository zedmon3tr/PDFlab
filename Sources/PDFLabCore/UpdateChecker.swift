import Foundation

/// GitHub Release 最新版本信息(已确认新于当前版本)。
public struct UpdateInfo: Equatable, Sendable {
    public var version: String
    public var releaseNotes: String
    public var assetURL: URL
    public var assetName: String
    public init(version: String, releaseNotes: String, assetURL: URL, assetName: String) {
        self.version = version
        self.releaseNotes = releaseNotes
        self.assetURL = assetURL
        self.assetName = assetName
    }
}

/// 经 GitHub Releases API 检查更新。免认证,公开仓库,60 次/时限额足够。
public struct UpdateChecker: Sendable {
    private let owner: String
    private let repo: String
    private let client: HTTPClient

    public init(owner: String, repo: String, client: HTTPClient = URLSession.shared) {
        self.owner = owner
        self.repo = repo
        self.client = client
    }

    public func check(currentVersion: String) async throws -> UpdateInfo? {
        let url = URL(string: "https://api.github.com/repos/\(owner)/\(repo)/releases/latest")!
        var request = URLRequest(url: url)
        request.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")

        let (data, response): (Data, URLResponse)
        do {
            (data, response) = try await client.data(for: request)
        } catch {
            throw PDFLabError.networkError(error.localizedDescription)
        }
        guard let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode) else {
            throw PDFLabError.engineUnavailable(engineID: "update")
        }
        guard let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let tag = root["tag_name"] as? String else {
            throw PDFLabError.engineUnavailable(engineID: "update")
        }

        let version = tag.hasPrefix("v") ? String(tag.dropFirst()) : tag
        guard Self.isNewer(version, than: currentVersion) else { return nil }

        // 无 dmg 资产视为无更新(发布不规范不该吓到用户)。
        let assets = root["assets"] as? [[String: Any]] ?? []
        guard let dmg = assets.first(where: { ($0["name"] as? String)?.hasSuffix(".dmg") == true }),
              let name = dmg["name"] as? String,
              let urlString = dmg["browser_download_url"] as? String,
              let assetURL = URL(string: urlString) else {
            return nil
        }
        return UpdateInfo(version: version,
                          releaseNotes: root["body"] as? String ?? "",
                          assetURL: assetURL,
                          assetName: name)
    }

    public static func isNewer(_ candidate: String, than current: String) -> Bool {
        let a = candidate.split(separator: ".").map { Int($0) ?? 0 }
        let b = current.split(separator: ".").map { Int($0) ?? 0 }
        for i in 0..<max(a.count, b.count) {
            let x = i < a.count ? a[i] : 0
            let y = i < b.count ? b[i] : 0
            if x != y { return x > y }
        }
        return false
    }
}
