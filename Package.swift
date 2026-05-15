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
    ],
    dependencies: [
        .package(url: "https://github.com/apple/swift-argument-parser.git", from: "1.5.0"),
    ],
    targets: [
        .executableTarget(
            name: "dictamac",
            dependencies: [
                "DictamacCore",
                .product(name: "ArgumentParser", package: "swift-argument-parser"),
            ]
        ),
        .target(
            name: "DictamacCore"
        ),
        .testTarget(
            name: "DictamacCoreTests",
            dependencies: ["DictamacCore"]
        ),
    ]
)
