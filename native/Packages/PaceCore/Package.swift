// swift-tools-version: 6.2
import PackageDescription

// PaceCore is the pure engine: no database, no ambient clock, no device locale.
let package = Package(
    name: "PaceCore",
    platforms: [.iOS(.v26), .macOS(.v26)],
    products: [.library(name: "PaceCore", targets: ["PaceCore"])],
    targets: [
        .target(name: "PaceCore"),
        .testTarget(name: "PaceCoreTests", dependencies: ["PaceCore"], resources: [.process("Fixtures")]),
    ]
)
