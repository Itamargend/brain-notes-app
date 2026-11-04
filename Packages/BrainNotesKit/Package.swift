// swift-tools-version: 6.2
import PackageDescription

#if canImport(CryptoKit) && canImport(Security) && canImport(Network) && canImport(Compression)
let package = Package(
    name: "BrainNotesKit",
    platforms: [.macOS(.v26), .iOS(.v26)],
    products: [.library(name: "BrainNotesKit", targets: ["BrainNotesKit"])],
    dependencies: [
        .package(path: "../.."),
        .package(url: "https://github.com/groue/GRDB.swift.git", exact: "7.12.0"),
    ],
    targets: [
        .target(
            name: "BrainNotesKit",
            dependencies: [
                .product(name: "BrainMerge", package: "brain-notes-app"),
                .product(name: "GRDB", package: "GRDB.swift"),
            ]
        ),
        .testTarget(
            name: "BrainNotesKitTests",
            dependencies: ["BrainNotesKit", .product(name: "BrainMerge", package: "brain-notes-app")]
        ),
    ]
)
#else
// Without Apple's frameworks (Linux): the sync engine needs CryptoKit, Security, Network, Compression and os, so only
// the part of the kit that uses the standard library alone builds here: `Links/` (wiki links, backlinks, renames) and
// its tests. Same module name, so the tests read the same on both.
let package = Package(
    name: "BrainNotesKit",
    platforms: [.macOS(.v26), .iOS(.v26)],
    products: [.library(name: "BrainNotesKit", targets: ["BrainNotesKit"])],
    targets: [
        .target(name: "BrainNotesKit", path: "Sources/BrainNotesKit", sources: ["Links"]),
        .testTarget(name: "BrainNotesKitTests", dependencies: ["BrainNotesKit"], path: "Tests/BrainNotesKitTests", sources: ["Links"]),
    ]
)
#endif
