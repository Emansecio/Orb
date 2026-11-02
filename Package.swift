// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "Orb",
    platforms: [.macOS(.v14)],
    products: [
        // The app's executable keeps the name Orb (`.build/<config>/Orb`, what scripts/bundle.sh copies).
        .executable(name: "Orb", targets: ["OrbMain"])
    ],
    targets: [
        // The whole app is a library, so a change to it is compiled once: an executable target that tests import is
        // compiled twice, once for the product and once as the "testable" module (measured: a touched file of the app
        // rebuilt in 35 s instead of 67 s, a clean build with tests in 176 s instead of 231 s).
        .target(
            name: "Orb",
            path: "Sources/Orb",
            exclude: ["Resources"]
        ),
        .executableTarget(
            name: "OrbMain",
            dependencies: ["Orb"],
            path: "Sources/OrbMain"
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
