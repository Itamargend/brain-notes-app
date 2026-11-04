// swift-tools-version: 6.2
import PackageDescription

// NoteSearch is plain Swift and Foundation, so it builds and tests everywhere. The sync engine in BrainNotesKit
// needs Apple frameworks (CryptoKit, Security, Network, Compression, os), so off Apple platforms (Linux) only the
// part of BrainNotesKit that uses the standard library alone is declared: `Links/` (wiki links, backlinks, renames)
// and its tests. Same module names on both, so the tests read the same everywhere, and Linux fetches no dependency.
var products: [Product] = [
    .library(name: "BrainNotesKit", targets: ["BrainNotesKit"]),
    .library(name: "NoteSearch", targets: ["NoteSearch"]),
]
var dependencies: [Package.Dependency] = []
var targets: [Target] = [
    .target(name: "NoteSearch"),
    .testTarget(name: "NoteSearchTests", dependencies: ["NoteSearch"]),
]
#if canImport(CryptoKit) && canImport(Security) && canImport(Network) && canImport(Compression)
dependencies = [
    .package(path: "../.."),
    .package(url: "https://github.com/groue/GRDB.swift.git", exact: "7.12.0"),
]
targets += [
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
#else
targets += [
    .target(name: "BrainNotesKit", path: "Sources/BrainNotesKit", sources: ["Links"]),
    .testTarget(
        name: "BrainNotesKitTests", dependencies: ["BrainNotesKit"],
        path: "Tests/BrainNotesKitTests", sources: ["Links"]
    ),
]
#endif

let package = Package(
    name: "BrainNotesKit",
    platforms: [.macOS(.v26), .iOS(.v26)],
    products: products,
    dependencies: dependencies,
    targets: targets
)
