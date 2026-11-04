// swift-tools-version: 6.2
import PackageDescription

// NoteSearch is plain Swift and Foundation, so it builds and tests on Linux too. The rest of the kit
// needs Apple frameworks (Security, CryptoKit, Compression, Network), so off Apple platforms only
// NoteSearch is declared, with no dependencies to fetch, and `swift test` runs its tests alone.
var products: [Product] = [.library(name: "NoteSearch", targets: ["NoteSearch"])]
var dependencies: [Package.Dependency] = []
var targets: [Target] = [
    .target(name: "NoteSearch"),
    .testTarget(name: "NoteSearchTests", dependencies: ["NoteSearch"]),
]
#if canImport(Darwin)
products.insert(.library(name: "BrainNotesKit", targets: ["BrainNotesKit"]), at: 0)
dependencies = [
    .package(path: "../.."),
    .package(url: "https://github.com/groue/GRDB.swift.git", exact: "7.12.0"),
]
targets.insert(contentsOf: [
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
], at: 0)
#endif

let package = Package(
    name: "BrainNotesKit",
    platforms: [.macOS(.v26), .iOS(.v26)],
    products: products,
    dependencies: dependencies,
    targets: targets
)
