// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "ImrseSettingsKit",
    platforms: [.macOS(.v14)],
    products: [
        .library(name: "ImrseSettingsKit", targets: ["ImrseSettingsKit"])
    ],
    targets: [
        .target(name: "ImrseSettingsKit"),
        .testTarget(name: "ImrseSettingsCoreTests", dependencies: ["ImrseSettingsKit"])
    ]
)
