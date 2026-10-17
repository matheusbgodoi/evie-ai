import Foundation
import Testing

@testable import EvieCore

@Suite("Computer typing")
struct ComputerTypingTests {
  @Test("a chunk never splits a surrogate pair, at any boundary")
  func chunksKeepSurrogatePairs() {
    // 19 ASCII letters put the emoji's two UTF-16 units across the 20 limit.
    let texts = [
      String(repeating: "a", count: 19) + "😀" + "b",
      String(repeating: "😀", count: 15),
      "a😀" + String(repeating: "x", count: 18) + "🇧🇷c",
    ]
    for text in texts {
      let chunks = ComputerTyping.unicodeChunks(text)
      #expect(chunks.joined() == text)
      for chunk in chunks {
        #expect(chunk.utf16.count <= ComputerTyping.maximumUnicodeChunk)
        #expect(!chunk.isEmpty)
        let units = Array(chunk.utf16)
        #expect(!UTF16.isTrailSurrogate(units[0]))
        #expect(!UTF16.isLeadSurrogate(units[units.count - 1]))
      }
    }
  }

  @Test("a long text goes in chunks of at most 20 units, in order")
  func chunksInOrder() {
    let text = String(repeating: "0123456789", count: 5)

    let chunks = ComputerTyping.unicodeChunks(text)

    #expect(chunks.map(\.utf16.count) == [20, 20, 10])
    #expect(chunks.joined() == text)
  }

  @Test("a character longer than one chunk is cut between its scalars, never inside one")
  func oversizedCharacter() {
    // One Character of 26 UTF-16 units: a letter, 18 combining accents, a
    // combining mark outside the BMP (two units, at units 19 and 20, across
    // the limit), and 5 more accents.
    let stacked =
      "e" + String(repeating: "\u{0301}", count: 18) + "\u{1D167}"
      + String(repeating: "\u{0301}", count: 5)
    #expect(stacked.count == 1)
    #expect(stacked.utf16.count > ComputerTyping.maximumUnicodeChunk)

    let chunks = ComputerTyping.unicodeChunks(stacked)

    #expect(chunks.map(\.utf16.count) == [19, 7])
    #expect(chunks.joined() == stacked)
    for chunk in chunks {
      #expect(chunk.utf16.count <= ComputerTyping.maximumUnicodeChunk)
      let units = Array(chunk.utf16)
      #expect(!UTF16.isTrailSurrogate(units[0]))
      #expect(!UTF16.isLeadSurrogate(units[units.count - 1]))
    }
  }

  @Test("pt-BR accents go by paste")
  func accentsPaste() {
    for text in ["ação", "é", "Teste de pesquisa — ação ✓", "coração", "ñ"] {
      #expect(ComputerTyping.route(for: text, mode: .auto, accessibilityAllowed: false) == .paste)
    }
  }

  @Test("short ASCII goes as key events; past 20 characters, by paste")
  func lengthRule() {
    let twenty = String(repeating: "a", count: 20)
    #expect(
      ComputerTyping.route(for: twenty, mode: .auto, accessibilityAllowed: false)
        == .keys([twenty]))
    #expect(
      ComputerTyping.route(for: twenty + "b", mode: .auto, accessibilityAllowed: false) == .paste)
    #expect(
      ComputerTyping.route(for: "ok", mode: .auto, accessibilityAllowed: false) == .keys(["ok"]))
  }

  @Test("auto tries the field's own value first when the app allows it")
  func accessibilityFirst() {
    #expect(
      ComputerTyping.route(for: "ação", mode: .auto, accessibilityAllowed: true)
        == .accessibility(fallback: .paste))
    #expect(
      ComputerTyping.route(for: "ok", mode: .auto, accessibilityAllowed: true)
        == .accessibility(fallback: .keys(["ok"])))
  }

  @Test("a chosen mode is kept, and the field's value has no fallback")
  func explicitModes() {
    #expect(
      ComputerTyping.route(for: "ação", mode: .keys, accessibilityAllowed: true)
        == .keys(["ação"]))
    #expect(ComputerTyping.route(for: "ok", mode: .paste, accessibilityAllowed: true) == .paste)
    #expect(
      ComputerTyping.route(for: "ok", mode: .accessibility, accessibilityAllowed: true)
        == .accessibility(fallback: nil))
    #expect(
      ComputerTyping.route(for: "ok", mode: .accessibility, accessibilityAllowed: false)
        == .accessibility(fallback: nil))
  }
}

@Suite("Computer key codes")
struct ComputerKeyCodesTests {
  @Test("named keys map to their virtual key codes")
  func namedKeys() {
    #expect(ComputerKeyCodes.code(for: "return") == 36)
    #expect(ComputerKeyCodes.code(for: "escape") == 53)
    #expect(ComputerKeyCodes.code(for: "tab") == 48)
    #expect(ComputerKeyCodes.code(for: "space") == 49)
    #expect(ComputerKeyCodes.code(for: "delete") == 51)
    #expect(ComputerKeyCodes.code(for: "forwarddelete") == 117)
    #expect(ComputerKeyCodes.code(for: "left") == 123)
    #expect(ComputerKeyCodes.code(for: "up") == 126)
    #expect(ComputerKeyCodes.code(for: "f1") == 122)
    #expect(ComputerKeyCodes.code(for: "f20") == 90)
  }

  @Test("letters and digits use the ANSI positions, which ABNT2 shares")
  func letters() {
    #expect(ComputerKeyCodes.code(for: "a") == 0)
    #expect(ComputerKeyCodes.code(for: "n") == 45)
    #expect(ComputerKeyCodes.code(for: "v") == 9)
    #expect(ComputerKeyCodes.code(for: "w") == 13)
    #expect(ComputerKeyCodes.code(for: "1") == 18)
    #expect(ComputerKeyCodes.code(for: "0") == 29)
  }

  @Test("every key a chord can name has a code")
  func everyChordKey() {
    let keys =
      ["return", "escape", "tab", "space", "delete", "forwarddelete", "up", "down", "left",
       "right", "home", "end", "pageup", "pagedown"]
      + (1...20).map { "f\($0)" }
      + (0x21...0x7E).map { String(UnicodeScalar(UInt8($0))).lowercased() }
    for key in keys {
      #expect(ComputerKeyCodes.key(for: key) != nil, "\(key)")
    }
  }

  @Test("a symbol that sits on a shifted key carries the shift")
  func shiftedSymbols() {
    #expect(ComputerKeyCodes.key(for: "!") == ComputerKeyCodes.Key(code: 18, shift: true))
    #expect(ComputerKeyCodes.key(for: "+") == ComputerKeyCodes.Key(code: 24, shift: true))
    #expect(ComputerKeyCodes.key(for: "=") == ComputerKeyCodes.Key(code: 24, shift: false))
  }
}
