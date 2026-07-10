// swift-tools-version: 5.9

import PackageDescription

let package = Package(
    name: "BreakGuard",
    platforms: [.macOS(.v13)],
    products: [
        .executable(name: "BreakGuard", targets: ["BreakGuard"])
    ],
    targets: [
        .executableTarget(
            name: "BreakGuard",
            path: "Sources/BreakGuard",
            resources: [.copy("Resources")],
            swiftSettings: [.define("APP_BUILD")]
        ),
        .testTarget(
            name: "BreakGuardTests",
            dependencies: ["BreakGuard"],
            path: "Tests/BreakGuardTests"
        )
    ],
    swiftLanguageVersions: [.v5]
)
