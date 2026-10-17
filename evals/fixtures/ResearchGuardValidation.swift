import EvieCore

/// Classification and typing-route checks only. No UI, events or pasteboard.
@main
@MainActor
struct ResearchGuardValidation {
  private struct Failure: Error, CustomStringConvertible {
    let description: String
  }

  private static func require(_ condition: Bool, _ description: String) throws {
    guard condition else { throw Failure(description: description) }
  }

  static func main() throws {
    try require(
      ResearchValidation.isolatedClipboardRefusal(for: .paste)?.outcome == .failed,
      "Direct paste must fail before delegation.")
    var chordsChecked = 0
    for bits in 0..<16 {
      let modifiers = Set(
        KeyModifier.allCases.enumerated().compactMap { index, modifier in
          bits & (1 << index) == 0 ? nil : modifier
        })
      for key in ["v", "V", "a", "tab"] {
        guard let chord = KeyChord(key: key, modifiers: modifiers) else {
          throw Failure(description: "Fixture chord failed to parse: \(key), \(modifiers)")
        }
        let result = ResearchValidation.isolatedClipboardRefusal(for: .pressKeys(chord))
        let shouldRefuse = key.lowercased() == "v" && modifiers.contains(.command)
        try require(
          (result?.outcome == .failed) == shouldRefuse,
          "Incorrect clipboard classification for \(chord.symbol).")
        if shouldRefuse {
          try require(
            result?.detail.contains("type") == true,
            "The refusal must explain how the model can recover using type.")
        }
        chordsChecked += 1
      }
    }
    for spelling in ["cmd+v", "super+V", "meta+shift+v", "command+option+control+v"] {
      guard let chord = KeyChord(parsing: spelling) else {
        throw Failure(description: "Fixture alias failed to parse: \(spelling)")
      }
      try require(
        ResearchValidation.isolatedClipboardRefusal(for: .pressKeys(chord))?.outcome == .failed,
        "Command alias must not bypass the refusal: \(spelling)")
      chordsChecked += 1
    }
    try require(
      ResearchValidation.isolatedClipboardRefusal(for: .typeText("synthetic")) == nil,
      "The guard must leave AX text entry available.")
    try require(
      ResearchValidation.isolatedClipboardRefusal(for: .writeClipboard("synthetic")) == nil,
      "The guard must leave named-pasteboard writes available.")
    try require(
      ComputerTyping.route(for: "synthetic", mode: .accessibility, accessibilityAllowed: true)
        == .accessibility(fallback: nil),
      "Forced AX typing must fail instead of falling back to an OS paste.")
    print(
      "PASS: paste, \(chordsChecked) chord cases, type/write allowed and AX without fallback; no OS clipboard accessed."
    )
  }
}
