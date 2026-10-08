// swift-tools-version: 6.0
import PackageDescription

// Procedural art for the Orb layers (body shading and hair), rendered on the CPU:
// `swift run -c release --package-path art/orbgen orbgen all`. See art/README.md.
let package = Package(
    name: "orbgen",
    platforms: [.macOS(.v14)],
    targets: [
        .executableTarget(name: "orbgen", path: "Sources/orbgen")
    ]
)
