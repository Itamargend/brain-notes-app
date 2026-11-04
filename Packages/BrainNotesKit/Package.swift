// swift-tools-version: 6.2
import PackageDescription

// `BrainNotesTables` (plain Swift, no Foundation) and `NoteSearch` (Swift and Foundation) build and test on Linux
// too. The rest of the kit needs Apple's frameworks (Security, CryptoKit, Network, Compression), so on any host but a
// Mac BrainNotesKit is declared with `Links/` alone (wiki links, backlinks, renames: the standard library only), under
// the same module name so its tests read the same on both. The dependencies stay declared everywhere, so
// Package.resolved reads the same on every host.
let dependencies: [Package.Dependency] = [
    .package(path: "../.."),
    .package(url: "https://github.com/groue/GRDB.swift.git", exact: "7.12.0"),
]

let portableTargets: [Target] = [
    .target(name: "BrainNotesTables"),
    .testTarget(
        name: "BrainNotesTablesTests",
        dependencies: ["BrainNotesTables"],
        resources: [.copy("Fixtures")]
    ),
    .target(name: "NoteSearch"),
    .testTarget(name: "NoteSearchTests", dependencies: ["NoteSearch"]),
]

let products: [Product] = [
    .library(name: "BrainNotesKit", targets: ["BrainNotesKit"]),
    .library(name: "BrainNotesTables", targets: ["BrainNotesTables"]),
    .library(name: "NoteSearch", targets: ["NoteSearch"]),
]

#if os(macOS)
let kitTargets: [Target] = [
    .target(
        name: "BrainNotesKit",
        dependencies: [
            "BrainNotesTables",
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
let kitTargets: [Target] = [
    .target(name: "BrainNotesKit", path: "Sources/BrainNotesKit", sources: ["Links"]),
    .testTarget(name: "BrainNotesKitTests", dependencies: ["BrainNotesKit"], path: "Tests/BrainNotesKitTests", sources: ["Links"]),
]
#endif

let package = Package(
    name: "BrainNotesKit",
    platforms: [.macOS(.v26), .iOS(.v26)],
    products: products,
    dependencies: dependencies,
    targets: kitTargets + portableTargets
)
