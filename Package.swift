// swift-tools-version: 6.2
// 6.2 is the first 6.x tools version with the `.v26` platform constants.
import PackageDescription

let package = Package(
    name: "BrainMerge",
    platforms: [.macOS(.v26), .iOS(.v26)],
    products: [
        .library(name: "BrainMerge", targets: ["BrainMerge"]),
        .executable(name: "bench", targets: ["bench"]),
    ],
    targets: [
        .target(name: "BrainMerge"),
        .executableTarget(name: "bench", dependencies: ["BrainMerge"]),
        .testTarget(
            name: "BrainMergeTests",
            dependencies: ["BrainMerge"],
            resources: [
                // Byte-for-byte copies of spec/merge/*.json (a test checks they still match).
                .copy("Resources/vectors.json"),
                .copy("Resources/plan-vectors.json"),
                // Generated from the TypeScript reference by Tools/differential/gen.ts.
                .copy("Resources/differential.json"),
            ]
        ),
    ]
)
