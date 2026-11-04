// swift-tools-version: 6.2
import PackageDescription

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
            dependencies: [
                "BrainNotesKit",
                .product(name: "BrainMerge", package: "brain-notes-app"),
                // Already pinned for the library; tests read the index's tables directly.
                .product(name: "GRDB", package: "GRDB.swift"),
            ]
        ),
    ]
)
