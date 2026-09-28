// swift-tools-version: 6.1

import PackageDescription

let package = Package(
    name: "swift-tokenizers-mlx",
    platforms: [
        .macOS(.v14),
        .iOS(.v17),
        .tvOS(.v17),
        .visionOS(.v1),
    ],
    products: [
        .library(name: "MLXLMTokenizers", targets: ["MLXLMTokenizers"]),
        .library(name: "MLXEmbeddersTokenizers", targets: ["MLXEmbeddersTokenizers"]),
    ],
    dependencies: [
        .package(url: "https://github.com/ml-explore/mlx-swift-lm.git", exact: "3.31.4"),
        .package(url: "https://github.com/DePasqualeOrg/swift-tokenizers.git", exact: "0.5.0"),
        .package(url: "https://github.com/DePasqualeOrg/swift-hf-api.git", from: "0.3.2"),
    ],
    targets: [
        .target(
            name: "MLXLMTokenizers",
            dependencies: [
                .product(name: "MLXLMCommon", package: "mlx-swift-lm"),
                .product(name: "Tokenizers", package: "swift-tokenizers"),
            ]
        ),
        .target(
            name: "MLXEmbeddersTokenizers",
            dependencies: [
                .product(name: "MLXEmbedders", package: "mlx-swift-lm"),
                .product(name: "MLXLMCommon", package: "mlx-swift-lm"),
                "MLXLMTokenizers",
            ]
        ),
        .target(
            name: "TestHelpers",
            dependencies: [
                .product(name: "MLXLMCommon", package: "mlx-swift-lm"),
                .product(name: "HFAPI", package: "swift-hf-api"),
            ],
            path: "Tests/TestHelpers"
        ),
        .testTarget(
            name: "Benchmarks",
            dependencies: [
                "MLXLMTokenizers",
                "MLXEmbeddersTokenizers",
                "TestHelpers",
                .product(name: "HFAPI", package: "swift-hf-api"),
                .product(name: "MLXEmbedders", package: "mlx-swift-lm"),
                .product(name: "BenchmarkHelpers", package: "mlx-swift-lm"),
            ]
        ),
        .testTarget(
            name: "IntegrationTests",
            dependencies: [
                "MLXLMTokenizers",
                "TestHelpers",
                .product(name: "HFAPI", package: "swift-hf-api"),
                .product(name: "IntegrationTestHelpers", package: "mlx-swift-lm"),
                .product(name: "MLXLLM", package: "mlx-swift-lm"),
            ]
        ),
    ]
)
