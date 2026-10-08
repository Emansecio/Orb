// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "Orb",
    platforms: [.macOS(.v14)],
    targets: [
        .executableTarget(
            name: "Orb",
            path: "Sources/Orb",
            exclude: ["Resources"]
        ),
        .testTarget(
            name: "OrbAppTests",
            dependencies: ["Orb"],
            path: "Tests/OrbAppTests"
        )
    ]
)
