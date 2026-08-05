// swift-tools-version: 6.0

import PackageDescription

let package = Package(
  name: "Evie",
  platforms: [
    .macOS(.v15)
  ],
  products: [
    .library(name: "EvieCore", targets: ["EvieCore"]),
    .executable(name: "evie-shell", targets: ["EvieShell"]),
  ],
  targets: [
    .target(name: "EvieCore"),
    .executableTarget(
      name: "EvieShell",
      dependencies: ["EvieCore"]
    ),
    .testTarget(
      name: "EvieCoreTests",
      dependencies: ["EvieCore"]
    ),
  ]
)
