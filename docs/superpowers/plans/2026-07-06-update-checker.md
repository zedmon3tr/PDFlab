# 检查更新功能实现计划

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** 按 [2026-07-06-update-checker-design.md](../specs/2026-07-06-update-checker-design.md) 实现检查更新:设置→关于页手动检测 + 启动自动检测(默认关),GitHub Releases 数据源,半自动安装(下载 dmg 并打开)。

**Architecture:** Core 层新增 `UpdateChecker`(GitHub API 查询 + 语义版本比较,经既有 `HTTPClient` 协议可测);App 层新增 `UpdateController` 单例状态机(手动/启动检测 + dmg 下载),关于页追加更新区块,MainView 挂启动检测 alert。发布侧:版本号以 `PDFLabCoreInfo.version` 为唯一事实源,bundle 脚本从中提取,新增 `make dmg`。

**Tech Stack:** Swift 6.2(v5 语言模式)、SwiftUI、URLSession、Swift Testing。零第三方依赖。

## Global Constraints

- 构建/测试一律 `make build` / `make test`,不直接调 `swift`(Makefile 已封装 `DEVELOPER_DIR` 与 Swift Testing 框架路径两个坑)
- **测试文件禁止直接 `import Foundation`**(Foundation 经 `@testable import PDFLabCore` 传递获得)
- 界面文案全部经 `L10n.t(_:)`,中英双语,禁止硬编码用户可见字符串
- macOS 15 最低部署目标;本功能不用任何 macOS 26 专属 API
- 零第三方依赖;TDD(先写失败测试);conventional commits
- 错误沿用既有 `PDFLabError` case,不新增:网络失败 → `.networkError(描述)`,非 2xx / JSON 解析失败 → `.engineUnavailable(engineID: "update")`
- GitHub 仓库坐标是占位值 `REPLACE_ME/PDFlab`(仓库尚未创建,发布前由用户替换 owner)

## 模型路由(按 CLAUDE.md 派发规则)

- Task 1(Core,计划已给完整代码)→ sonnet
- Task 2(脚本改造,纯转录)→ sonnet
- Task 3(App 层状态机 + UI,多文件集成)→ **fable 5**
- Task 4(启动检测接线,计划已给完整代码)→ sonnet

---

### Task 1: Core 层 `UpdateChecker`

**Files:**
- Create: `Sources/PDFLabCore/UpdateChecker.swift`
- Test: `Tests/PDFLabCoreTests/UpdateCheckerTests.swift`

**Interfaces:**
- Consumes: `HTTPClient` 协议(`TranslationEngine.swift` 中已有,`extension URLSession: HTTPClient`)、`PDFLabError`
- Produces(Task 3 依赖,签名一字不差):

```swift
public struct UpdateInfo: Equatable, Sendable {
    public var version: String        // 去掉 v 前缀,如 "0.2.0"
    public var releaseNotes: String   // release 正文 markdown 原文
    public var assetURL: URL
    public var assetName: String
    public init(version: String, releaseNotes: String, assetURL: URL, assetName: String)
}

public struct UpdateChecker: Sendable {
    public init(owner: String, repo: String, client: HTTPClient = URLSession.shared)
    /// GET https://api.github.com/repos/{owner}/{repo}/releases/latest(免认证)。
    /// 返回新于 currentVersion 的 UpdateInfo;已是最新或 release 无 dmg 资产时返回 nil。
    public func check(currentVersion: String) async throws -> UpdateInfo?
    /// 数值化语义版本比较:按 . 分段比整数,段数不齐补 0。
    public static func isNewer(_ candidate: String, than current: String) -> Bool
}
```

- [ ] **Step 1: 写失败测试**(`Tests/PDFLabCoreTests/UpdateCheckerTests.swift`;复用同目录既有 `MockHTTPClient`,注意不 import Foundation)

```swift
import Testing
@testable import PDFLabCore

private func httpResponse(_ status: Int) -> HTTPURLResponse {
    HTTPURLResponse(url: URL(string: "https://api.github.com")!,
                    statusCode: status, httpVersion: nil, headerFields: nil)!
}

private let releaseJSON = """
{
  "tag_name": "v0.2.0",
  "body": "- 新增检查更新\\n- 修复若干问题",
  "assets": [
    {"name": "PDFlab-0.2.0.dmg",
     "browser_download_url": "https://github.com/o/r/releases/download/v0.2.0/PDFlab-0.2.0.dmg"}
  ]
}
""".data(using: .utf8)!

/// 抛错的 HTTPClient,模拟断网。
private struct FailingHTTPClient: HTTPClient {
    func data(for request: URLRequest) async throws -> (Data, URLResponse) {
        throw URLError(.notConnectedToInternet)
    }
}

@Test func isNewerComparesNumerically() {
    #expect(UpdateChecker.isNewer("0.10.0", than: "0.9.0"))
    #expect(!UpdateChecker.isNewer("0.9.0", than: "0.10.0"))
    #expect(!UpdateChecker.isNewer("1.0.0", than: "1.0.0"))
    #expect(UpdateChecker.isNewer("1.0.1", than: "1.0"))
    #expect(!UpdateChecker.isNewer("1.0", than: "1.0.0"))
}

@Test func parsesLatestReleaseAndStripsVPrefix() async throws {
    let mock = MockHTTPClient(scriptedResults: [(releaseJSON, httpResponse(200))])
    let checker = UpdateChecker(owner: "o", repo: "r", client: mock)
    let info = try await checker.check(currentVersion: "0.1.0")
    #expect(info?.version == "0.2.0")
    #expect(info?.releaseNotes.contains("检查更新") == true)
    #expect(info?.assetName == "PDFlab-0.2.0.dmg")
    #expect(mock.recordedRequests.first?.url?.absoluteString
            == "https://api.github.com/repos/o/r/releases/latest")
}

@Test func upToDateReturnsNil() async throws {
    let mock = MockHTTPClient(scriptedResults: [(releaseJSON, httpResponse(200))])
    let info = try await UpdateChecker(owner: "o", repo: "r", client: mock)
        .check(currentVersion: "0.2.0")
    #expect(info == nil)
}

@Test func missingDmgAssetReturnsNil() async throws {
    let json = #"{"tag_name": "v9.9.9", "body": "", "assets": []}"#.data(using: .utf8)!
    let mock = MockHTTPClient(scriptedResults: [(json, httpResponse(200))])
    let info = try await UpdateChecker(owner: "o", repo: "r", client: mock)
        .check(currentVersion: "0.1.0")
    #expect(info == nil)
}

@Test func non2xxThrowsUnavailable() async {
    let mock = MockHTTPClient(scriptedResults: [(Data(), httpResponse(404))])
    await #expect(throws: PDFLabError.engineUnavailable(engineID: "update")) {
        _ = try await UpdateChecker(owner: "o", repo: "r", client: mock)
            .check(currentVersion: "0.1.0")
    }
}

@Test func networkFailureThrowsNetworkError() async {
    let checker = UpdateChecker(owner: "o", repo: "r", client: FailingHTTPClient())
    do {
        _ = try await checker.check(currentVersion: "0.1.0")
        Issue.record("expected throw")
    } catch let error as PDFLabError {
        guard case .networkError = error else {
            Issue.record("expected networkError, got \(error)")
            return
        }
    } catch {
        Issue.record("unexpected error type \(error)")
    }
}
```

- [ ] **Step 2: 跑测试确认失败**

Run: `make test`
Expected: 编译错误 `cannot find 'UpdateChecker'`(类型不存在即为失败)。

- [ ] **Step 3: 实现 `Sources/PDFLabCore/UpdateChecker.swift`**

```swift
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
```

- [ ] **Step 4: `make test` 全绿**(122 + 6 = 128 测试)

- [ ] **Step 5: Commit**

```bash
git add Sources/PDFLabCore/UpdateChecker.swift Tests/PDFLabCoreTests/UpdateCheckerTests.swift
git commit -m "feat: GitHub release update checker with semver compare"
```

---

### Task 2: 版本号单一来源 + `make dmg`

**Files:**
- Create: `scripts/app_version.sh`, `scripts/make_dmg.sh`
- Modify: `scripts/bundle_app.sh`(版本号提取)、`Makefile`(dmg 目标)

**Interfaces:**
- Consumes: `Sources/PDFLabCore/Models.swift` 第 7 行 `public enum PDFLabCoreInfo { public static let version = "0.1.0" }`
- Produces: `make dmg` → `dist/PDFlab-<version>.dmg`;bundle 的 Info.plist `CFBundleShortVersionString` 与 `PDFLabCoreInfo.version` 一致

- [ ] **Step 1: 写 `scripts/app_version.sh`**(版本提取的唯一实现,两个脚本共用)

```bash
#!/usr/bin/env bash
# 从 PDFLabCoreInfo.version(版本号唯一事实源)提取版本字符串并输出。
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
sed -n 's/.*static let version = "\([^"]*\)".*/\1/p' "$ROOT/Sources/PDFLabCore/Models.swift" | head -n 1
```

```bash
chmod +x scripts/app_version.sh
```

- [ ] **Step 2: 改 `scripts/bundle_app.sh`**——在 `BINARY_DST=` 行后加版本提取,并替换写死的版本号:

```bash
VERSION="$(bash "$ROOT/scripts/app_version.sh")"
```

Info.plist heredoc 中 `<string>0.1.0</string>`(CFBundleShortVersionString 的值)改为 `<string>$VERSION</string>`。

- [ ] **Step 3: 写 `scripts/make_dmg.sh`**

```bash
#!/usr/bin/env bash
# 把 dist/PDFlab.app 打成 dist/PDFlab-<version>.dmg(含 Applications 快捷方式,拖入即安装)。
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
VERSION="$(bash "$ROOT/scripts/app_version.sh")"
APP="$ROOT/dist/PDFlab.app"
DMG="$ROOT/dist/PDFlab-$VERSION.dmg"

[ -d "$APP" ] || { echo "dist/PDFlab.app 不存在,先跑 make bundle" >&2; exit 1; }

STAGE="$(mktemp -d)"
trap 'rm -rf "$STAGE"' EXIT
cp -R "$APP" "$STAGE/"
ln -s /Applications "$STAGE/Applications"
rm -f "$DMG"
hdiutil create -volname "PDFlab" -srcfolder "$STAGE" -ov -format UDZO "$DMG"
echo "Built $DMG"
```

```bash
chmod +x scripts/make_dmg.sh
```

- [ ] **Step 4: Makefile 加目标**(沿用现有单行风格,`dmg` 依赖 `bundle`)

```makefile
dmg: bundle ; bash scripts/make_dmg.sh
```

- [ ] **Step 5: 验证**

Run: `bash scripts/app_version.sh`
Expected: `0.1.0`

Run: `make dmg`
Expected: 成功产出 `dist/PDFlab-0.1.0.dmg`;然后:

Run: `/usr/libexec/PlistBuddy -c "Print CFBundleShortVersionString" dist/PDFlab.app/Contents/Info.plist`
Expected: `0.1.0`

Run: `hdiutil verify dist/PDFlab-0.1.0.dmg`
Expected: `verified` 无错误。

- [ ] **Step 6: Commit**

```bash
git add scripts/app_version.sh scripts/make_dmg.sh scripts/bundle_app.sh Makefile
git commit -m "chore: single-source app version and make dmg target"
```

---

### Task 3: App 层更新状态机 + 关于页 UI

**Files:**
- Create: `Sources/PDFLabApp/UpdateController.swift`
- Modify: `Sources/PDFLabApp/SettingsView.swift`(aboutTab 追加更新区块,约 127–144 行附近)
- Modify: `Sources/PDFLabApp/L10n.swift`(新增 update.* key)

**Interfaces:**
- Consumes: Task 1 的 `UpdateChecker` / `UpdateInfo`;`PDFLabCoreInfo.version`;`L10n.t(_:)` 与 `L10n.message(for:)`
- Produces(Task 4 依赖):
  - `UpdateController.shared`(`@MainActor final class UpdateController: ObservableObject`)
  - `func checkAtLaunch() async -> UpdateInfo?`(未勾选自动检测 / 失败 / 版本已跳过时返回 nil;命中时返回 info 且 phase 置 `.updateAvailable`)
  - `@AppStorage("autoCheckUpdates") var autoCheckUpdates: Bool = false`
  - `@AppStorage("skippedVersion") var skippedVersion: String = ""`
  - L10n key `update.available`(zh "发现新版本" / en "New version available",Task 4 的 alert 正文复用)

- [ ] **Step 1: 实现 `Sources/PDFLabApp/UpdateController.swift`**

```swift
import SwiftUI
import AppKit
import PDFLabCore

/// 检查更新状态机(单例):设置关于页手动检测与启动自动检测共用。
/// 下载在后台 Task 进行,phase 更新回主线程。
@MainActor
final class UpdateController: ObservableObject {
    enum Phase: Equatable {
        case idle
        case checking
        case upToDate
        case updateAvailable(UpdateInfo)
        case downloading(Double?)     // 已知总大小时为 0...1,未知为 nil
        case downloaded(UpdateInfo)
        case failed(String)
    }

    static let shared = UpdateController()

    /// GitHub 仓库坐标。⚠️ 建仓后把 owner 替换为真实用户名。
    nonisolated static let repoOwner = "REPLACE_ME"
    nonisolated static let repoName = "PDFlab"

    @Published private(set) var phase: Phase = .idle

    // @AppStorage 在 ObservableObject 内不自动触发刷新,willSet 手动补发(与 AppState 同范式)。
    @AppStorage("autoCheckUpdates") var autoCheckUpdates: Bool = false {
        willSet { objectWillChange.send() }
    }
    @AppStorage("skippedVersion") var skippedVersion: String = ""

    private var checker: UpdateChecker {
        UpdateChecker(owner: Self.repoOwner, repo: Self.repoName)
    }

    /// 手动检测(关于页按钮):结果如实反映到 phase,不理会 skippedVersion。
    func checkManually() async {
        phase = .checking
        do {
            if let info = try await checker.check(currentVersion: PDFLabCoreInfo.version) {
                phase = .updateAvailable(info)
            } else {
                phase = .upToDate
            }
        } catch {
            phase = .failed(Self.message(for: error))
        }
    }

    /// 启动静默检测:未勾选 / 失败 / 版本已被跳过一律返回 nil 且不置失败态。
    func checkAtLaunch() async -> UpdateInfo? {
        guard autoCheckUpdates else { return nil }
        guard let result = try? await checker.check(currentVersion: PDFLabCoreInfo.version),
              let info = result,
              info.version != skippedVersion else { return nil }
        phase = .updateAvailable(info)   // 关于页同步显示
        return info
    }

    func skip(_ info: UpdateInfo) {
        skippedVersion = info.version
        phase = .idle
    }

    /// 下载 dmg 到 ~/Downloads 并自动打开(半自动安装:用户拖入 Applications 覆盖)。
    func download(_ info: UpdateInfo) {
        phase = .downloading(nil)
        Task.detached { [weak self] in
            do {
                let (bytes, response) = try await URLSession.shared.bytes(from: info.assetURL)
                guard let http = response as? HTTPURLResponse,
                      (200..<300).contains(http.statusCode) else {
                    throw PDFLabError.engineUnavailable(engineID: "update")
                }
                let expected = response.expectedContentLength   // 未知时为 -1
                var data = Data()
                if expected > 0 { data.reserveCapacity(Int(expected)) }
                var nextReport = 0
                for try await byte in bytes {
                    data.append(byte)
                    if expected > 0, data.count >= nextReport {
                        let fraction = Double(data.count) / Double(expected)
                        await self?.setPhase(.downloading(fraction))
                        nextReport = data.count + Int(expected) / 100   // 每 ~1% 报一次
                    }
                }
                let downloads = FileManager.default.urls(for: .downloadsDirectory,
                                                         in: .userDomainMask)[0]
                let dest = downloads.appendingPathComponent(info.assetName)
                try? FileManager.default.removeItem(at: dest)
                try data.write(to: dest)
                await MainActor.run {
                    NSWorkspace.shared.open(dest)
                }
                await self?.setPhase(.downloaded(info))
            } catch {
                await self?.setPhase(.failed(Self.message(for: error)))
            }
        }
    }

    private func setPhase(_ new: Phase) {
        phase = new
    }

    private nonisolated static func message(for error: Error) -> String {
        if let e = error as? PDFLabError { return L10n.message(for: e) }
        return error.localizedDescription
    }
}
```

- [ ] **Step 2: L10n.swift 新增 key**(加入 `strings` 字典,与既有条目同格式)

```swift
"update.check": ("检测更新", "Check for Updates"),
"update.checking": ("正在检测…", "Checking…"),
"update.autoCheck": ("启动时自动检测更新", "Automatically check for updates at launch"),
"update.upToDate": ("当前已是最新版本", "You're up to date"),
"update.available": ("发现新版本", "New version available:"),
"update.download": ("下载更新", "Download Update"),
"update.skip": ("跳过此版本", "Skip This Version"),
"update.downloading": ("正在下载更新…", "Downloading update…"),
"update.downloaded": ("安装包已打开,请将 PDFlab 拖入 Applications 完成更新",
                      "Installer opened — drag PDFlab into Applications to finish updating"),
```

- [ ] **Step 3: SettingsView.aboutTab 追加更新区块**

SettingsView 加成员:

```swift
@ObservedObject private var updater = UpdateController.shared
```

`aboutTab` 的 VStack 末尾(blurb Text 之后)追加 `updateSection`,并在文件内新增:

```swift
// MARK: - 检查更新

@ViewBuilder
private var updateSection: some View {
    VStack(spacing: 10) {
        switch updater.phase {
        case .idle:
            checkUpdateButton
        case .checking:
            checkUpdateButton
        case .upToDate:
            checkUpdateButton
            Text(L10n.t("update.upToDate"))
                .font(.callout)
                .foregroundStyle(.secondary)
        case .updateAvailable(let info):
            updateAvailableView(info)
        case .downloading(let fraction):
            if let fraction {
                ProgressView(value: fraction) { Text(L10n.t("update.downloading")) }
                    .frame(width: 260)
            } else {
                ProgressView(L10n.t("update.downloading"))
                    .controlSize(.small)
            }
        case .downloaded:
            Text(L10n.t("update.downloaded"))
                .font(.callout)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .padding(.horizontal, 40)
        case .failed(let message):
            checkUpdateButton
            Text(message)
                .font(.callout)
                .foregroundStyle(.red)
                .multilineTextAlignment(.center)
                .padding(.horizontal, 40)
        }

        Toggle(L10n.t("update.autoCheck"), isOn: $updater.autoCheckUpdates)
            .toggleStyle(.checkbox)
            .font(.callout)
    }
    .padding(.top, 8)
}

private var checkUpdateButton: some View {
    Button {
        Task { await updater.checkManually() }
    } label: {
        if updater.phase == .checking {
            HStack(spacing: 6) {
                ProgressView().controlSize(.small)
                Text(L10n.t("update.checking"))
            }
        } else {
            Text(L10n.t("update.check"))
        }
    }
    .disabled(updater.phase == .checking)
}

private func updateAvailableView(_ info: UpdateInfo) -> some View {
    VStack(spacing: 8) {
        Text("\(L10n.t("update.available")) \(info.version)")
            .font(.callout.weight(.semibold))
        if !info.releaseNotes.isEmpty {
            ScrollView {
                Text(info.releaseNotes)
                    .font(.callout)
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            .frame(maxHeight: 120)
            .padding(8)
            .background(.quaternary.opacity(0.5), in: RoundedRectangle(cornerRadius: 6))
            .padding(.horizontal, 40)
        }
        HStack {
            Button(L10n.t("update.download")) { updater.download(info) }
                .buttonStyle(.borderedProminent)
            Button(L10n.t("update.skip")) { updater.skip(info) }
        }
    }
}
```

- [ ] **Step 4: `make build` 通过、`make test` 全绿(App 层无新测试,不能破坏既有 128 个)**

- [ ] **Step 5: Commit**

```bash
git add Sources/PDFLabApp/UpdateController.swift Sources/PDFLabApp/SettingsView.swift Sources/PDFLabApp/L10n.swift
git commit -m "feat: update state machine and About-tab update UI"
```

---

### Task 4: 启动自动检测 + Alert + 定位关于 Tab

**Files:**
- Modify: `Sources/PDFLabApp/AppState.swift`(新增 settingsTab)
- Modify: `Sources/PDFLabApp/SettingsView.swift`(TabView 加 selection + tag)
- Modify: `Sources/PDFLabApp/MainView.swift`(启动检测 + alert)
- Modify: `Sources/PDFLabApp/L10n.swift`(alert 文案 3 个 key)

**Interfaces:**
- Consumes: Task 3 的 `UpdateController.shared.checkAtLaunch()`、L10n key `update.available`
- Produces: `AppState.settingsTab: String`(`@Published`,"general"/"services"/"about")

- [ ] **Step 1: AppState 加 tab 选择状态**(放在 `historyRevision` 声明附近)

```swift
/// 设置窗口当前 Tab("general"/"services"/"about");启动更新 alert 经它把设置定位到关于页。
@Published var settingsTab: String = "general"
```

- [ ] **Step 2: SettingsView 的 TabView 接上 selection**

`TabView {` 改为 `TabView(selection: $app.settingsTab) {`,三个 tab 的 `.tabItem { ... }` 后分别追加 `.tag("general")`、`.tag("services")`、`.tag("about")`。

- [ ] **Step 3: L10n.swift 新增 alert key**

```swift
"update.alert.title": ("发现新版本", "New Version Available"),
"update.alert.view": ("前往查看", "View Details"),
"update.alert.close": ("关闭", "Close"),
```

- [ ] **Step 4: MainView 挂启动检测与 alert**

MainView 加成员(`@EnvironmentObject private var app: AppState` 已有,沿用):

```swift
@State private var launchUpdate: UpdateInfo?
@Environment(\.openSettings) private var openSettings
```

body 最外层视图追加修饰符:

```swift
.task {
    launchUpdate = await UpdateController.shared.checkAtLaunch()
}
.alert(
    L10n.t("update.alert.title"),
    isPresented: Binding(
        get: { launchUpdate != nil },
        set: { if !$0 { launchUpdate = nil } }
    )
) {
    Button(L10n.t("update.alert.view")) {
        app.settingsTab = "about"
        openSettings()
        launchUpdate = nil
    }
    Button(L10n.t("update.alert.close"), role: .cancel) {
        launchUpdate = nil
    }
} message: {
    Text("\(L10n.t("update.available")) \(launchUpdate?.version ?? "")")
}
```

(注:`openSettings` 是 macOS 14+ API,最低部署 15,无需 `#available` 分支。`UpdateInfo` 需 `import PDFLabCore`,MainView 已有。)

- [ ] **Step 5: `make build` 通过、`make test` 全绿**

- [ ] **Step 6: Commit**

```bash
git add Sources/PDFLabApp/AppState.swift Sources/PDFLabApp/SettingsView.swift Sources/PDFLabApp/MainView.swift Sources/PDFLabApp/L10n.swift
git commit -m "feat: launch auto-check with alert routing to About settings tab"
```

---

## 人工验收(全部任务完成后,用户 `make run`)

1. 设置→关于:点"检测更新"→(仓库还是占位值)应显示失败文案,可重试——这验证失败态;
2. 临时把 `UpdateController.repoOwner/repoName` 指到任一有 dmg 资产的公开仓库(或建好真实仓库发一个 v9.9.9 测试 release),验证:发现更新 → 更新说明滚动区 → 下载进度 → 自动打开 dmg;"跳过此版本"后重启,勾选自动检测不再弹,但手动检测仍显示;
3. 勾选"启动时自动检测",重启 app,弹 alert,[前往查看] 打开设置且落在关于 Tab;
4. 中英文界面各过一遍文案。

## Self-Review 记录

- **Spec 覆盖**:spec 一(发布约定/版本单源/make dmg)→ Task 2;二(UpdateChecker)→ Task 1;三(关于页状态机/跳过语义/checkbox)→ Task 3;四(启动检测/alert/openSettings)→ Task 4;五(错误表)→ Task 1 错误映射 + Task 3 failed 态 + checkAtLaunch 静默;六(测试策略)→ Task 1 TDD + 人工验收节。无缺口。
- **类型一致性**:`UpdateInfo`/`UpdateChecker.check`/`checkAtLaunch`/`autoCheckUpdates`/`skippedVersion`/`settingsTab` 在 Interfaces 与代码块中签名一致;L10n key `update.available` 由 Task 3 定义、Task 4 复用。
- **占位符检查**:无 TBD/TODO;`REPLACE_ME` 是规格明确要求的仓库占位值,非计划缺口。
