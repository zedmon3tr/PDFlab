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
    nonisolated static let repoOwner = "zedmon3tr"
    nonisolated static let repoName = "PDFlab"

    @Published private(set) var phase: Phase = .idle

    /// 新装默认开启启动检测(0.1.5 起);老用户已持久化的选择由 @AppStorage 语义天然保留。
    nonisolated static let autoCheckUpdatesDefault = true

    /// 默认值语义的可测表达:有持久化值用持久化值,否则用默认值(即 @AppStorage 的行为)。
    nonisolated static func resolvedAutoCheckUpdates(persisted: Bool?) -> Bool {
        persisted ?? autoCheckUpdatesDefault
    }

    /// 启动是否弹更新窗口的纯函数决策:auto 关闭、无新版或该版本已被跳过都不弹。
    nonisolated static func shouldOfferLaunchUpdate(
        autoCheckEnabled: Bool, candidateVersion: String?, skippedVersion: String
    ) -> Bool {
        guard autoCheckEnabled, let candidate = candidateVersion else { return false }
        return candidate != skippedVersion
    }

    // @AppStorage 在 ObservableObject 内不自动触发刷新,willSet 手动补发(与 AppState 同范式)。
    @AppStorage("autoCheckUpdates") var autoCheckUpdates: Bool = UpdateController.autoCheckUpdatesDefault {
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
    /// 弹窗与否的判定收敛在 `shouldOfferLaunchUpdate`(纯函数,可测)。
    func checkAtLaunch() async -> UpdateInfo? {
        guard autoCheckUpdates else { return nil }   // auto 关闭时连网络请求都不发
        // 注意:`try?` 会把 `UpdateInfo??` 拍平成单层 Optional,一次解包即可。
        let candidate = try? await checker.check(currentVersion: PDFLabCoreInfo.version)
        guard let info = candidate,
              Self.shouldOfferLaunchUpdate(
                  autoCheckEnabled: autoCheckUpdates,
                  candidateVersion: info.version,
                  skippedVersion: skippedVersion
              ) else { return nil }
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
                let reportStep = expected > 0 ? max(1, Int(expected) / 100) : Int.max  // 每 ~1% 报一次
                for try await byte in bytes {
                    data.append(byte)
                    if expected > 0, data.count >= nextReport {
                        let fraction = Double(data.count) / Double(expected)
                        await self?.setPhase(.downloading(fraction))
                        nextReport = data.count + reportStep
                    }
                }
                let downloads = FileManager.default.urls(for: .downloadsDirectory,
                                                         in: .userDomainMask)[0]
                let dest = downloads.appendingPathComponent(info.assetName)
                try? FileManager.default.removeItem(at: dest)
                try data.write(to: dest)
                await MainActor.run {
                    _ = NSWorkspace.shared.open(dest)
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

    /// 更新专属错误文案:引擎不可用错误若来自更新检查(engineID == "update")用专属措辞,
    /// 避免渲染成"翻译引擎暂不可用 (update)"这种与更新场景错位的文案。其他 case 委托 L10n.message(for:)。
    nonisolated static func message(for error: Error) -> String {
        if let e = error as? PDFLabError {
            if case .engineUnavailable(let id) = e, id == "update" {
                return L10n.t("error.updateUnavailable")
            }
            return L10n.message(for: e)
        }
        return error.localizedDescription
    }
}
