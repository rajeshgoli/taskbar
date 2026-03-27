// swift-tools-version: 5.9

import PackageDescription

let package = Package(
    name: "DeskBar",
    platforms: [
        .macOS(.v14)
    ],
    targets: [
        .executableTarget(
            name: "DeskBar",
            path: "Sources/DeskBar"
        ),
        .testTarget(
            name: "DeskBarTests",
            dependencies: ["DeskBar"],
            path: "Tests/DeskBarTests"
        )
    ]
)
