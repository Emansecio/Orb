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
        // A small AppKit app the Accessibility smoke tests (`AXSmokeTests`) drive; it is not part of the app.
        .executableTarget(
            name: "OrbAXFixture",
            path: "Tests/OrbAXFixture"
        ),
        .executableTarget(
            name: "OrbKeychainHelper",
            path: "Sources/OrbKeychainHelper"
        ),
        .testTarget(
            name: "OrbAppTests",
            dependencies: ["Orb", "OrbAXFixture"],
            path: "Tests/OrbAppTests"
        )
    ]
)
