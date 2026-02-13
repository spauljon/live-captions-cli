// swift-tools-version: 6.2
// The swift-tools-version declares the minimum version of Swift required to build this package.

import PackageDescription

let package = Package(
    name: "live-captions-cli",
    platforms: [
        .macOS(.v14)
    ],
    products: [
        .executable(name: "live-captions-cli", targets: ["live-captions-cli"]),
    ],
    targets: [
        .executableTarget(
            name: "live-captions-cli"
        ),
        .testTarget(
            name: "live-captions-cliTests",
            dependencies: ["live-captions-cli"]
        )
    ]
)
