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
        .library(name: "DictamacVoiceMemos", targets: ["DictamacVoiceMemos"]),
        .library(name: "DictamacMCP", targets: ["DictamacMCP"]),
        .library(name: "DictamacCLI", targets: ["DictamacCLI"]),
    ],
    dependencies: [
        .package(url: "https://github.com/apple/swift-argument-parser.git", from: "1.5.0"),
    ],
    targets: [
        .executableTarget(
            name: "dictamac",
            // The executable is a one-line wrapper around
            // `Dictamac.main()` (see `Sources/dictamac/main.swift`);
            // it only imports `DictamacCLI`. Speech + Core +
            // ArgumentParser reach the binary transitively through
            // `DictamacCLI`, so the executable target itself doesn't
            // need to declare them.
            dependencies: [
                "DictamacCLI",
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
            name: "DictamacVoiceMemos",
            dependencies: ["DictamacCore"]
        ),
        .target(
            name: "DictamacMCP",
            dependencies: ["DictamacCore"]
        ),
        .target(
            name: "DictamacCLI",
            dependencies: [
                "DictamacCore",
                "DictamacSpeech",
                "DictamacVoiceMemos",
                "DictamacMCP",
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
            name: "DictamacMCPTests",
            dependencies: ["DictamacMCP", "DictamacCore"],
            resources: [
                // `__Snapshots__/tools-list.json` is the golden shape
                // for the MCP `tools/list` response. It's loaded via
                // `Bundle.module` from the snapshot drift test and is
                // the only thing that needs to ride along with the
                // test binary today.
                .copy("__Snapshots__"),
            ]
        ),
        .testTarget(
            name: "DictamacCLITests",
            dependencies: [
                "DictamacCLI",
                "DictamacCore",
                "DictamacVoiceMemos",
                .product(name: "ArgumentParser", package: "swift-argument-parser"),
            ]
        ),
        .testTarget(
            name: "DictamacVoiceMemosTests",
            dependencies: ["DictamacVoiceMemos", "DictamacCore"]
        ),
    ]
)
