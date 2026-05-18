// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "dictamac",
    platforms: [
        .macOS("26.0")
    ],
    products: [
        .executable(name: "dictamac", targets: ["dictamac"]),
        .library(name: "DictamacCore", targets: ["DictamacCore"]),
        .library(name: "DictamacSpeech", targets: ["DictamacSpeech"]),
        .library(name: "DictamacCLI", targets: ["DictamacCLI"]),
    ],
    dependencies: [
        .package(url: "https://github.com/apple/swift-argument-parser.git", from: "1.5.0"),
    ],
    targets: [
        .executableTarget(
            name: "dictamac",
            dependencies: [
                "DictamacCLI",
                "DictamacCore",
                "DictamacSpeech",
                .product(name: "ArgumentParser", package: "swift-argument-parser"),
            ]
        ),
        .target(
            name: "DictamacCore"
        ),
        .target(
            name: "DictamacSpeech",
            dependencies: ["DictamacCore"]
        ),
        .target(
            name: "DictamacCLI",
            dependencies: [
                "DictamacCore",
                "DictamacSpeech",
                .product(name: "ArgumentParser", package: "swift-argument-parser"),
            ]
        ),
        .testTarget(
            name: "DictamacCoreTests",
            dependencies: ["DictamacCore"]
        ),
        .testTarget(
            name: "DictamacSpeechTests",
            dependencies: ["DictamacSpeech", "DictamacCore"],
            resources: [
                .copy("Fixtures"),
            ]
        ),
        .testTarget(
            name: "DictamacCLITests",
            dependencies: [
                "DictamacCLI",
                "DictamacCore",
                .product(name: "ArgumentParser", package: "swift-argument-parser"),
            ]
        ),
    ]
)
