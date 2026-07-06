# 检查更新功能设计(GitHub Releases,半自动安装)

> 日期:2026-07-06。状态:用户已确认设计,待实现。
> 决策来源:用户需求(设置→关于页内检测更新 + 启动自动检测 checkbox)+ 三次拍板:半自动安装 / 公开仓库 / 启动发现新版弹 Alert。

## 目标

在设置→关于页提供"检测更新"能力:检查 GitHub Releases 上是否有新版本,有则展示版本号与更新内容,用户可下载更新(半自动:下载 dmg 并打开,用户手动拖入 Applications 覆盖)或跳过该版本。另提供"启动时自动检测更新"checkbox(默认不勾选)。

**非目标**(明确不做):原地替换自动安装(Sparkle 式)、"稍后提醒"按钮、Apple Developer 签名/公证、私有仓库 token 认证。

## 一、发布侧约定(GitHub)

- **公开仓库**。owner/repo 以常量形式写在代码中;仓库尚未创建,实现时先用占位值,发布前由用户建仓后替换(或用 `gh` 代建)。
- 每次发版流程:
  1. 更新 `PDFLabCoreInfo.version`(**版本号唯一事实源**);
  2. 打 tag `vX.Y.Z`(与 version 一致);
  3. 建 GitHub Release,**正文即更新说明**(界面"更新内容"的数据来源);
  4. 上传资产 `PDFlab-X.Y.Z.dmg`。
- 打包配套改造:
  - `scripts/bundle_app.sh` 中 `CFBundleShortVersionString` 不再写死 `0.1.0`,改为从 `PDFLabCoreInfo.version`(Models.swift)提取;
  - 新增 `make dmg` 目标:`make bundle` 后用 `hdiutil` 把 `dist/PDFlab.app` 打成 `dist/PDFlab-X.Y.Z.dmg`。

## 二、Core 层:`UpdateChecker`(纯逻辑,可测,零第三方依赖)

新增 `Sources/PDFLabCore/UpdateChecker.swift`:

```swift
public struct UpdateInfo: Equatable, Sendable {
    public var version: String        // 去掉 v 前缀,如 "0.2.0"
    public var releaseNotes: String   // release 正文(markdown 原文)
    public var assetURL: URL          // dmg 资产下载直链(browser_download_url)
    public var assetName: String
}

public struct UpdateChecker: Sendable {
    public init(owner: String, repo: String, client: HTTPClient = URLSession.shared)
    /// GET https://api.github.com/repos/{owner}/{repo}/releases/latest(免认证)。
    /// 有新于 currentVersion 的版本返回 UpdateInfo,否则返回 nil(已是最新)。
    public func check(currentVersion: String) async throws -> UpdateInfo?
    /// 数值化语义版本比较:按 . 分段比整数,段数不齐补 0。"0.10.0" > "0.9.0"。
    public static func isNewer(_ candidate: String, than current: String) -> Bool
}
```

- 复用现有 `HTTPClient` 协议,测试经 `MockHTTPClient` 注入(沿用翻译引擎的既有范式)。
- tag 解析:`tag_name` 去掉可选的 `v` 前缀后作为版本号。
- 资产选择:优先取名称以 `.dmg` 结尾的 asset;**release 无 dmg 资产时视为无更新**(返回 nil,不报错——发布不规范不该吓到用户)。
- 错误映射沿用 `PDFLabError`,不新增 case:网络失败 → `networkError(描述)`;非 2xx / JSON 解析失败 → `engineUnavailable(engineID: "update")`。
- 测试覆盖:release JSON 解析、`isNewer` 边界(相等 / 多段 / 0.10 vs 0.9 / 带 v 前缀)、无 dmg 资产返回 nil、404 与网络失败抛错。

## 三、App 层:关于页 UI 状态机

现有 `SettingsView.aboutTab`(图标 + 名称 + 版本 + 简介)下方追加更新区块:

| 状态 | 呈现 |
|---|---|
| idle | [检测更新] 按钮 + "启动时自动检测更新" checkbox |
| checking | 按钮内转圈,禁点 |
| upToDate | 次要色文字"当前已是最新版本" |
| updateAvailable | "发现新版本 x.y.z" + 更新说明(release 正文,限高滚动区)+ [下载更新] + [跳过此版本] |
| downloading | 下载进度条(URLSession 下载到 ~/Downloads/PDFlab-X.Y.Z.dmg) |
| downloaded | 自动 `NSWorkspace.shared.open(dmg)`,用户拖入 Applications 覆盖即完成更新 |
| failed | 红色错误文案 + 可重新检测 |

- **跳过语义**:`skippedVersion` 存 `@AppStorage`;仅对**启动自动检测**生效——手动点"检测更新"永远如实显示(与 Sparkle 惯例一致)。点"跳过此版本"后回到 idle。
- checkbox 存 `@AppStorage("autoCheckUpdates")`,默认 `false`。
- 全部文案经 `L10n.t(_:)` 中英双语,新增 `update.*` key 族。
- 应用内 URLSession 下载不带 quarantine 标记,更新后的 app 不触发门禁提示(自用机器全程无摩擦;浏览器首装是唯一有门禁的场景,接受)。

## 四、启动自动检测

- 主窗口出现后,若 `autoCheckUpdates == true`,静默调 `check()` 一次。
- 发现新版本且 `version != skippedVersion` → 弹 alert"发现新版本 x.y.z":[前往查看](经 SwiftUI `openSettings` 打开设置并定位关于 Tab)/ [关闭]。
- 启动检测**失败静默吞掉**(不为更新检查失败打扰启动)。

## 五、错误处理汇总

| 情况 | 行为 |
|---|---|
| 手动检测网络失败 | failed 态显示原因,可重试 |
| 启动自动检测失败 | 静默忽略 |
| release 无 dmg 资产 | 视为无更新(upToDate) |
| 下载中断/失败 | failed 态,可重新检测再下载 |
| API 限流(60 次/时,理论上碰不到) | 按网络错误处理 |

## 六、测试策略

- Core:`UpdateCheckerTests`(Mock 注入,见第二节清单),TDD 先测后实现。
- App 层状态机与 alert:`make run` 人工验收(与项目既有 App 层惯例一致);可造一个高版本号的假 release JSON 走通"发现更新→下载→打开 dmg"全流程。
