// swift-tools-version: 6.0
import PackageDescription

let syntheticCaptureDiagnosticsEnabled = false
let syntheticCaptureDiagnosticSettings: [SwiftSetting] = syntheticCaptureDiagnosticsEnabled
    ? [.define("IMRSE_SYNTHETIC_CAPTURE_DIAGNOSTICS")]
    : []

var products: [Product] = [
    .library(name: "ImrseCore", targets: ["ImrseCore"]),
    .library(name: "ImrseServices", targets: ["ImrseServices"])
]
var dependencies: [Package.Dependency] = [.package(path: "pill-kit/native")]
var targets: [Target] = [
    .target(name: "ImrseCore"),
    .target(name: "ImrseServices", dependencies: ["ImrseCore"]),
    .testTarget(name: "ImrseCoreTests", dependencies: ["ImrseCore"]),
    .testTarget(name: "ImrseServicesTests", dependencies: ["ImrseServices", "ImrseCore"])
]
#if os(macOS)
products.append(.library(name: "ImrseLocal", targets: ["ImrseLocal"]))
targets.append(.testTarget(name: "ImrseLocalTests", dependencies: ["ImrseLocal"]))
#if arch(arm64)
    dependencies += [
        .package(url: "https://github.com/ml-explore/mlx-swift-lm.git", exact: "3.31.4"),
        .package(url: "https://github.com/huggingface/swift-huggingface.git", exact: "0.9.0"),
        .package(url: "https://github.com/huggingface/swift-transformers.git", exact: "1.3.0")
    ]
    targets.append(.target(name: "ImrseLocal", dependencies: [
        "ImrseCore",
        .product(name: "MLXLLM", package: "mlx-swift-lm"),
        .product(name: "MLXLMCommon", package: "mlx-swift-lm"),
        .product(name: "MLXHuggingFace", package: "mlx-swift-lm"),
        .product(name: "HuggingFace", package: "swift-huggingface"),
        .product(name: "Tokenizers", package: "swift-transformers")
    ], resources: [.copy("Resources/Qwen3-APACHE-LICENSE.txt")]))
#else
    targets.append(.target(name: "ImrseLocal", dependencies: ["ImrseCore"], resources: [.copy("Resources/Qwen3-APACHE-LICENSE.txt")]))
#endif
products.append(.executable(name: "imrse", targets: ["ImrseApp"]))
targets.append(.target(name: "ImrseMac", dependencies: ["ImrseCore"], swiftSettings: syntheticCaptureDiagnosticSettings))
targets.append(.executableTarget(name: "ImrseApp", dependencies: ["ImrseCore", "ImrseServices", "ImrseMac", "ImrseLocal", .product(name: "ImrsePillUI", package: "native")], resources: [.copy("Resources/Brand")], swiftSettings: syntheticCaptureDiagnosticSettings))
targets.append(.testTarget(name: "ImrseMacTests", dependencies: ["ImrseMac", "ImrseCore"], swiftSettings: syntheticCaptureDiagnosticSettings))
targets.append(.testTarget(name: "ImrseAppTests", dependencies: ["ImrseApp", "ImrseCore", "ImrseServices", "ImrseMac", "ImrseLocal", .product(name: "ImrsePillUI", package: "native")], swiftSettings: syntheticCaptureDiagnosticSettings))
#endif

let package = Package(name: "imrse", platforms: [.macOS(.v14)], products: products, dependencies: dependencies, targets: targets)
