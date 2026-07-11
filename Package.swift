// swift-tools-version:6.0
import PackageDescription

let package = Package(
    name: "PDFlab",
    defaultLocalization: "zh-Hans",
    platforms: [.macOS(.v14)],
    targets: [
        .target(name: "PDFLabCore",
                swiftSettings: [.swiftLanguageMode(.v5)]),
        .executableTarget(name: "PDFLabApp",
                dependencies: ["PDFLabCore"],
                // App logo:开发运行(swift run,无 .app 外壳)时从 SPM 资源加载,
                // 打包运行仍用 bundle_app.sh 放进 Contents/Resources 的同名 icns。
                resources: [.copy("Resources/AppIcon.icns")],
                swiftSettings: [.swiftLanguageMode(.v5)]),
        .testTarget(name: "PDFLabCoreTests",
                dependencies: ["PDFLabCore"],
                swiftSettings: [.swiftLanguageMode(.v5)]),
        .testTarget(name: "PDFLabAppTests",
                dependencies: ["PDFLabApp", "PDFLabCore"],
                swiftSettings: [.swiftLanguageMode(.v5)]),
    ]
)
