import AppKit
import SwiftUI
import PDFLabCore

/// 富更新窗口的展示辅助(纯函数,便于测试):标题、版本行与 Release Notes 渲染。
enum UpdateSheetPresentation {
    /// 固定尺寸 sheet(明显小于设置 760×560 / 翻译 900×620 的量级)。
    static let width: CGFloat = 520
    static let height: CGFloat = 420

    static func title(version: String) -> String {
        String(format: L10n.t("update.sheet.title"), version)
    }

    static func versionLine(current: String, new: String) -> String {
        String(format: L10n.t("update.sheet.versions"), current, new)
    }

    /// GitHub Release body → 可显示的富文本:
    /// 空 body 返回 nil(整个区域隐藏);markdown 解析失败降级为纯文本,不报错。
    static func notes(from body: String) -> AttributedString? {
        let trimmed = body.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        if let parsed = try? AttributedString(
            markdown: trimmed,
            options: AttributedString.MarkdownParsingOptions(
                interpretedSyntax: .inlineOnlyPreservingWhitespace
            )
        ) {
            return parsed
        }
        return AttributedString(trimmed)
    }
}

/// Sparkle 风格更新窗口(0.1.5):App 图标 + 「PDFlab X.Y.Z 可用」+ 当前 → 新版本 +
/// 可滚动 Release Notes + 跳过此版本 / 稍后提醒 / 下载更新(唯一 prominent)。
/// 启动检测时挂主窗口 sheet;设置关于页手动检测时以 sheet-on-sheet 复用同一视图。
/// 下载进度/完成/失败复用共享 `UpdateController.phase`,与关于页展示保持一致。
struct UpdateSheetView: View {
    @ObservedObject var updater: UpdateController
    let info: UpdateInfo
    /// 稍后提醒 / 下载完成后的关闭动作(由呈现方负责收起 sheet)。
    let dismiss: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            header
            notesArea
            statusArea
            buttons
        }
        .padding(24)
        .frame(width: UpdateSheetPresentation.width, height: UpdateSheetPresentation.height)
    }

    // MARK: - 头部(图标 + 标题 + 版本对比)

    private var header: some View {
        HStack(alignment: .top, spacing: 16) {
            appIcon
            VStack(alignment: .leading, spacing: 6) {
                Text(UpdateSheetPresentation.title(version: info.version))
                    .font(.title3.weight(.semibold))
                Text(UpdateSheetPresentation.versionLine(
                    current: PDFLabCoreInfo.version, new: info.version
                ))
                .font(.callout)
                .foregroundStyle(.secondary)
                .monospacedDigit()
            }
            Spacer(minLength: 0)
        }
    }

    @ViewBuilder
    private var appIcon: some View {
        if let icon = NSApp.applicationIconImage, AboutLogoPresentation.usesApplicationIcon(icon) {
            Image(nsImage: icon)
                .resizable()
                .scaledToFit()
                .frame(width: 56, height: 56)
                .accessibilityHidden(true)
        } else {
            Image(systemName: AboutLogoPresentation.fallbackSystemImage)
                .font(.system(size: 36, weight: .medium))
                .foregroundStyle(.tint)
                .frame(width: 56, height: 56)
                .accessibilityHidden(true)
        }
    }

    // MARK: - Release Notes(body 空则整个区域隐藏)

    @ViewBuilder
    private var notesArea: some View {
        if let notes = UpdateSheetPresentation.notes(from: info.releaseNotes) {
            ScrollView {
                Text(notes)
                    .font(.callout)
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(10)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .background(.quaternary.opacity(0.5), in: RoundedRectangle(cornerRadius: 6))
        } else {
            Spacer(minLength: 0)
        }
    }

    // MARK: - 下载状态(共享 phase:进行中 / 已打开安装包 / 失败原因)

    @ViewBuilder
    private var statusArea: some View {
        switch updater.phase {
        case .downloading(let fraction):
            VStack(alignment: .leading, spacing: 6) {
                Text(L10n.t("update.downloading"))
                    .font(.callout)
                    .foregroundStyle(.secondary)
                if let fraction {
                    ProgressView(value: fraction)
                } else {
                    ProgressView()
                        .progressViewStyle(.linear)
                }
            }
        case .downloaded:
            Label(L10n.t("update.downloaded"), systemImage: "checkmark.circle.fill")
                .font(.callout)
                .foregroundStyle(.green)
        case .failed(let message):
            Label(message, systemImage: "xmark.circle.fill")
                .font(.callout)
                .foregroundStyle(.red)
                .lineLimit(2)
        default:
            EmptyView()
        }
    }

    // MARK: - 按钮行(下载更新为唯一 prominent)

    private var isDownloading: Bool {
        if case .downloading = updater.phase { return true }
        return false
    }

    private var isDownloaded: Bool {
        if case .downloaded = updater.phase { return true }
        return false
    }

    private var isFailed: Bool {
        if case .failed = updater.phase { return true }
        return false
    }

    private var buttons: some View {
        HStack(spacing: 8) {
            Button(L10n.t("update.skip")) {
                updater.skip(info)
                dismiss()
            }
            .disabled(isDownloading || isDownloaded)

            Spacer()

            if isDownloaded {
                Button(L10n.t("common.done")) { dismiss() }
                    .buttonStyle(.borderedProminent)
                    .keyboardShortcut(.defaultAction)
            } else {
                Button(L10n.t("update.later")) { dismiss() }
                    .keyboardShortcut(.cancelAction)
                    .disabled(isDownloading)
                Button(L10n.t(isFailed ? "update.retry" : "update.download")) {
                    updater.download(info)
                }
                .buttonStyle(.borderedProminent)
                .keyboardShortcut(.defaultAction)
                .disabled(isDownloading)
            }
        }
    }
}
