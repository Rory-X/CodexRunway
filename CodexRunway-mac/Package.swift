// swift-tools-version: 6.0

import PackageDescription

let package = Package(
    name: "CodexRunway",
    defaultLocalization: "en",
    platforms: [
        .macOS(.v12),
    ],
    products: [
        .executable(name: "CodexRunway", targets: ["CodexRunway"]),
        .executable(name: "CodexRunwayCostBenchmark", targets: ["CodexRunwayCostBenchmark"]),
        .library(name: "CodexRunwayCore", targets: ["CodexRunwayCore"]),
    ],
    targets: [
        .target(
            name: "CodexRunwayCore",
            linkerSettings: [
                .linkedLibrary("sqlite3"),
            ]),
        .target(
            name: "CodexRunwayWidget",
            dependencies: ["CodexRunwayCore"],
            resources: [.process("Resources")]),
        .executableTarget(
            name: "CodexRunway",
            dependencies: ["CodexRunwayCore"]),
        .executableTarget(
            name: "CodexRunwayCostBenchmark",
            dependencies: ["CodexRunwayCore"]),
        .testTarget(
            name: "CodexRunwayCoreTests",
            dependencies: ["CodexRunwayCore"]),
        .testTarget(
            name: "CodexRunwayTests",
            dependencies: ["CodexRunway", "CodexRunwayCore"]),
    ])
