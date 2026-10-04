// swift-tools-version: 6.2
import PackageDescription

// PaceStore: the GRDB/SQLite ledger. `LedgerExecutor` is the only write path.
let package = Package(
    name: "PaceStore",
    platforms: [.iOS(.v26), .macOS(.v26)],
    products: [.library(name: "PaceStore", targets: ["PaceStore"])],
    dependencies: [
        .package(path: "../PaceCore"),
        .package(url: "https://github.com/groue/GRDB.swift.git", from: "7.11.1"),
    ],
    targets: [
        .target(name: "PaceStore", dependencies: ["PaceCore", .product(name: "GRDB", package: "GRDB.swift")]),
        .testTarget(name: "PaceStoreTests", dependencies: ["PaceStore"]),
    ]
)
