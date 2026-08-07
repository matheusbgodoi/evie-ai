// swift-tools-version: 6.0

import PackageDescription

let package = Package(
  name: "Evie",
  platforms: [
    // 26, not 15. `EvieSpeechTranscription` uses `SpeechAnalyzer` and
    // `EvieVisionDescriber` uses `FoundationModels`, neither of which exists
    // before macOS 26, and neither is behind an availability guard. The
    // manifest said 15 until CI tried a macos-15 runner and could not find the
    // types — the README had said 26 all along, so this is the manifest being
    // brought in line with the documentation and with what the code does.
    .macOS("26.0")
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
