// swift-tools-version: 6.2
import PackageDescription
let package = Package(name: "TableDiff",
  dependencies: [.package(path: "../../../Packages/BrainNotesKit")],
  targets: [
    .executableTarget(name: "dump", dependencies: [.product(name: "BrainNotesTables", package: "BrainNotesKit")]),
    .executableTarget(name: "edit", dependencies: [.product(name: "BrainNotesTables", package: "BrainNotesKit")]),
  ])
