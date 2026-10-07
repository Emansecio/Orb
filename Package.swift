// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "OpenBotMac",
    platforms: [.macOS(.v14)],
    targets: [
        .executableTarget(
            name: "OpenBotMac",
            path: "Sources/OpenBotMac",
            exclude: ["Resources"]
        ),
        .testTarget(
            name: "OpenBotMacTests",
            dependencies: ["OpenBotMac"],
            path: "Tests/OpenBotMacTests"
        )
    ]
)
