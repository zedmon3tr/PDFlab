import AppKit

/// 开发运行(`swift run` / `make run`,无 .app 外壳)时,
/// `NSApp.applicationIconImage` 是系统通用可执行文件图标(看起来像文件夹),
/// 标题栏 logo 和 Dock 图标都不对。这里从真实图标资产加载并注入。
///
/// 查找顺序:
/// 1. 打包运行:`bundle_app.sh` 放进 `Contents/Resources/AppIcon.icns`(Bundle.main 直接命中)。
/// 2. 开发/测试:SPM 资源 bundle `PDFlab_PDFLabApp.bundle`(与可执行文件同目录)。
///    不用自动生成的 `Bundle.module`——它在找不到 bundle 时直接 fatalError,
///    打包产物里没有 SPM 资源 bundle,会把 .app 崩掉;这里查不到就安静返回 nil。
enum AppIconResource {
    static func locateIconURL() -> URL? {
        if let bundled = Bundle.main.url(forResource: "AppIcon", withExtension: "icns") {
            return bundled
        }

        let resourceBundleName = "PDFlab_PDFLabApp.bundle"
        let candidates: [URL?] = [
            Bundle.main.resourceURL,
            Bundle(for: BundleFinder.self).resourceURL,
            Bundle.main.bundleURL,
            // swift test:xctest bundle 位于 .build/debug/…xctest,资源 bundle 在其上层目录。
            Bundle(for: BundleFinder.self).bundleURL.deletingLastPathComponent(),
        ]
        for candidate in candidates {
            guard let candidate else { continue }
            let resourceBundleURL = candidate.appendingPathComponent(resourceBundleName)
            if let bundle = Bundle(url: resourceBundleURL),
               let url = bundle.url(forResource: "AppIcon", withExtension: "icns") {
                return url
            }
        }
        return nil
    }

    static func load() -> NSImage? {
        guard let url = locateIconURL() else { return nil }
        return NSImage(contentsOf: url)
    }

    /// App 启动时调用:让开发运行的 Dock 图标与标题栏 logo 都显示真实 logo。
    /// 打包运行时 Bundle.main 命中同一份 icns,重复赋值无副作用。
    static func install() {
        guard let icon = load() else { return }
        NSApplication.shared.applicationIconImage = icon
    }
}

private final class BundleFinder {}
