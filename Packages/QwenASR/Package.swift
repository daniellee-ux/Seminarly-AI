// swift-tools-version: 6.1
import PackageDescription

let package = Package(
    name: "QwenASR",
    platforms: [.macOS(.v14)],
    products: [.library(name: "QwenASR", targets: ["QwenASR"])],
    dependencies: [
        .package(url: "https://github.com/ml-explore/mlx-swift", exact: "0.31.3"),
        .package(url: "https://github.com/ml-explore/mlx-swift-lm", exact: "3.31.3"),
        .package(url: "https://github.com/huggingface/swift-transformers.git", exact: "1.1.9"),
    ],
    targets: [.target(name: "QwenASR", dependencies: [
        .product(name: "MLX", package: "mlx-swift"),
        .product(name: "MLXNN", package: "mlx-swift"),
        .product(name: "MLXLMCommon", package: "mlx-swift-lm"),
        .product(name: "Tokenizers", package: "swift-transformers"),
    ])],
    swiftLanguageModes: [.v5]
)
