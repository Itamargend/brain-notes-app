// swift-tools-version: 6.2
import PackageDescription

// One declaration on every host. `BrainNotesTables` is plain Swift (no Foundation) and `NoteSearch` is Swift and
// Foundation. BrainNotesKit keeps its Apple-only pieces (Keychain, NWPathMonitor, os.Logger, Compression, CryptoKit)
// behind `#if canImport(...)` with portable stand-ins, so the whole kit and its tests also build on Linux.
let package = Package(
    name: "BrainNotesKit",
    platforms: [.macOS(.v26), .iOS(.v26)],
    products: [
        .library(name: "BrainNotesKit", targets: ["BrainNotesKit"]),
        .library(name: "BrainNotesTables", targets: ["BrainNotesTables"]),
        .library(name: "NoteSearch", targets: ["NoteSearch"]),
    ],
    dependencies: [
        .package(path: "../.."),
        .package(url: "https://github.com/groue/GRDB.swift.git", exact: "7.12.0"),
    ],
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
            dependencies: [
                "BrainNotesKit",
                .product(name: "BrainMerge", package: "brain-notes-app"),
                // Already pinned for the library; tests read the index's tables directly.
                .product(name: "GRDB", package: "GRDB.swift"),
            ]
        ),
        .target(name: "BrainNotesTables"),
        .testTarget(
            name: "BrainNotesTablesTests",
            dependencies: ["BrainNotesTables"],
            resources: [.copy("Fixtures")]
        ),
        .target(name: "NoteSearch"),
        .testTarget(name: "NoteSearchTests", dependencies: ["NoteSearch"]),
    ]
)
