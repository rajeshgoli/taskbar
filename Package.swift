// swift-tools-version: 5.9

import PackageDescription

let package = Package(
    name: "DeskBar",
    platforms: [
        .macOS(.v14)
    ],
    dependencies: [
        .package(url: "https://github.com/swiftlang/swift-testing.git", exact: "6.2.4")
    ],
    targets: [
        .executableTarget(
            name: "DeskBar",
            path: "Sources/DeskBar"
        ),
        .testTarget(
            name: "DeskBarTests",
            dependencies: [
                "DeskBar",
                .product(name: "Testing", package: "swift-testing")
            ],
            path: "Tests/DeskBarTests"
        )
    ]
)
