// swift-tools-version:6.0
import PackageDescription

let package = Package(
    name: "PDFlab",
    defaultLocalization: "zh-Hans",
    platforms: [.macOS(.v15)],
    targets: [
        .target(name: "PDFLabCore",
                swiftSettings: [.swiftLanguageMode(.v5)]),
        .executableTarget(name: "PDFLabApp",
                dependencies: ["PDFLabCore"],
                swiftSettings: [.swiftLanguageMode(.v5)]),
        .testTarget(name: "PDFLabCoreTests",
                dependencies: ["PDFLabCore"],
                swiftSettings: [.swiftLanguageMode(.v5)]),
        .testTarget(name: "PDFLabAppTests",
                dependencies: ["PDFLabApp", "PDFLabCore"],
                swiftSettings: [.swiftLanguageMode(.v5)]),
    ]
)
