// swift-tools-version: 6.0
import PackageDescription
let package = Package(
    name: "DocumentAssistant",
    platforms: [.iOS(.v18), .macOS(.v14)],
    products: [.library(name: "DocumentAssistant", targets: ["DocumentAssistant"])],
    targets: [
        .target(name: "DocumentAssistant"),
        .testTarget(name: "DocumentAssistantTests", dependencies: ["DocumentAssistant"])
    ]
)
