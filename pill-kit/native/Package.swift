// swift-tools-version: 5.9
import PackageDescription
var dependencies: [Package.Dependency] = []
var products: [Product] = [.library(name: "ImrsePillCore", targets: ["ImrsePillCore"])]
var targets: [Target] = [
    .target(name: "ImrsePillCore"),
    .testTarget(name: "ImrsePillCoreTests", dependencies: ["ImrsePillCore"])
]
#if os(macOS)
dependencies.append(.package(url: "https://github.com/airbnb/lottie-ios.git", from: "4.5.1"))
products.append(.library(name: "ImrsePillUI", targets: ["ImrsePillUI"]))
targets.append(.target(name: "ImrsePillUI", dependencies: ["ImrsePillCore", .product(name: "Lottie", package: "lottie-ios")], resources: [.process("Resources")]))
#endif
let package = Package(name: "ImrsePillKit", platforms: [.macOS(.v13)], products: products, dependencies: dependencies, targets: targets)
