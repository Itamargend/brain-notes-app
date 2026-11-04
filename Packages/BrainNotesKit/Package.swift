// swift-tools-version: 6.2
import PackageDescription

// `BrainNotesTables` is plain Swift: no Foundation, no Apple frameworks, no dependencies. It builds and tests on
// Linux too. The rest of the kit needs Apple's frameworks (Security, CryptoKit, Network, Compression), so on any
// host but a Mac the package declares only the tables. The dependencies stay declared everywhere, so
// Package.resolved reads the same on every host.
let tableTargets: [Target] = [
    .target(name: "BrainNotesTables"),
    .testTarget(
        name: "BrainNotesTablesTests",
        dependencies: ["BrainNotesTables"],
        resources: [.copy("Fixtures")]
    ),
]

let dependencies: [Package.Dependency] = [
    .package(path: "../.."),
    .package(url: "https://github.com/groue/GRDB.swift.git", exact: "7.12.0"),
]

#if os(macOS)
let package = Package(
    name: "BrainNotesKit",
    platforms: [.macOS(.v26), .iOS(.v26)],
    products: [
        .library(name: "BrainNotesKit", targets: ["BrainNotesKit"]),
        .library(name: "BrainNotesTables", targets: ["BrainNotesTables"]),
    ],
    dependencies: dependencies,
    targets: [
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
    ] + tableTargets
)
#else
let package = Package(
    name: "BrainNotesKit",
    products: [.library(name: "BrainNotesTables", targets: ["BrainNotesTables"])],
    dependencies: dependencies,
    targets: tableTargets
)
#endif
