// swift-tools-version: 6.2
import PackageDescription
let package = Package(name: "ListScratch",
  dependencies: [.package(path: "/home/user/brain-notes-app")],
  targets: [
    .target(name: "BrainNotesKit", dependencies: [.product(name: "BrainMerge", package: "brain-notes-app")]),
    .testTarget(name: "BrainNotesKitTests", dependencies: ["BrainNotesKit"]),
  ])
