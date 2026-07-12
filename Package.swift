// swift-tools-version:6.0
import PackageDescription
import Foundation

// 测试文件不随公开仓分发。测试 target 仅在 Tests/ 存在时声明,
// 这样公开仓(无 Tests/)可正常 `swift build`,本地(含 Tests/)`swift test` 照常。
var targets: [Target] = [
    .target(name: "PDFLabCore",
            swiftSettings: [.swiftLanguageMode(.v5)]),
    .executableTarget(name: "PDFLabApp",
            dependencies: ["PDFLabCore"],
            // App logo:开发运行(swift run,无 .app 外壳)时从 SPM 资源加载,
            // 打包运行仍用 bundle_app.sh 放进 Contents/Resources 的同名 icns。
            resources: [.copy("Resources/AppIcon.icns")],
            swiftSettings: [.swiftLanguageMode(.v5)]),
]

if FileManager.default.fileExists(atPath: "Tests/PDFLabCoreTests") {
    targets.append(.testTarget(name: "PDFLabCoreTests",
            dependencies: ["PDFLabCore"],
            swiftSettings: [.swiftLanguageMode(.v5)]))
}
if FileManager.default.fileExists(atPath: "Tests/PDFLabAppTests") {
    targets.append(.testTarget(name: "PDFLabAppTests",
            dependencies: ["PDFLabApp", "PDFLabCore"],
            swiftSettings: [.swiftLanguageMode(.v5)]))
}

let package = Package(
    name: "PDFlab",
    defaultLocalization: "zh-Hans",
    platforms: [.macOS(.v14)],
    targets: targets
)
