import Foundation

/// The modifier keys Evie accepts for a global shortcut.
///
/// The raw value deliberately does not reuse Carbon or AppKit bit masks so the
/// persisted file stays readable and independent of any framework constant.
public struct EvieModifierFlags: OptionSet, Hashable, Sendable {
  public let rawValue: UInt8

  public init(rawValue: UInt8) {
    self.rawValue = rawValue
  }

  public static let control = EvieModifierFlags(rawValue: 1 << 0)
  public static let option = EvieModifierFlags(rawValue: 1 << 1)
  public static let shift = EvieModifierFlags(rawValue: 1 << 2)
  public static let command = EvieModifierFlags(rawValue: 1 << 3)

  /// Modifiers that make a key combination unlikely to be typed by accident.
  /// Shift alone only changes a character, so it never qualifies on its own.
  public static let qualifying: EvieModifierFlags = [.control, .option, .command]

  /// The `RegisterEventHotKey` mask for this combination.
  ///
  /// Carbon's values are stable public constants; mapping them here keeps the
  /// Carbon import inside the shell that actually registers the hot key.
  public var carbonFlags: UInt32 {
    var flags: UInt32 = 0
    if contains(.command) { flags |= 0x0100 }
    if contains(.shift) { flags |= 0x0200 }
    if contains(.option) { flags |= 0x0800 }
    if contains(.control) { flags |= 0x1000 }
    return flags
  }

  /// Symbols in the order macOS uses when it prints a menu equivalent.
  public var displayString: String {
    var symbols = ""
    if contains(.control) { symbols += "⌃" }
    if contains(.option) { symbols += "⌥" }
    if contains(.shift) { symbols += "⇧" }
    if contains(.command) { symbols += "⌘" }
    return symbols
  }
}

extension EvieModifierFlags: Codable {
  private static let names: [(EvieModifierFlags, String)] = [
    (.control, "control"),
    (.option, "option"),
    (.shift, "shift"),
    (.command, "command"),
  ]

  public init(from decoder: any Decoder) throws {
    var container = try decoder.unkeyedContainer()
    var flags = EvieModifierFlags()
    while !container.isAtEnd {
      let name = try container.decode(String.self)
      guard let match = Self.names.first(where: { $0.1 == name }) else {
        throw DecodingError.dataCorruptedError(
          in: container,
          debugDescription: "Unknown modifier \(name)"
        )
      }
      flags.insert(match.0)
    }
    self = flags
  }

  public func encode(to encoder: any Encoder) throws {
    var container = encoder.unkeyedContainer()
    for (flag, name) in Self.names where contains(flag) {
      try container.encode(name)
    }
  }
}

/// A single key combination Evie can register globally.
public struct EvieShortcut: Codable, Hashable, Sendable {
  public var keyCode: UInt16
  public var modifiers: EvieModifierFlags

  public init(keyCode: UInt16, modifiers: EvieModifierFlags) {
    self.keyCode = keyCode
    self.modifiers = modifiers
  }

  /// Function keys are usable without a modifier; every other key needs one so a
  /// global registration cannot silently swallow ordinary typing.
  public var requiresModifier: Bool {
    !Self.functionKeyCodes.contains(keyCode)
  }

  public func validate() throws {
    guard requiresModifier else {
      return
    }
    guard !modifiers.intersection(.qualifying).isEmpty else {
      throw ValidationError.missingModifier
    }
  }

  public var displayString: String {
    modifiers.displayString + Self.keyName(for: keyCode)
  }

  /// The character AppKit wants for a menu item's key equivalent, so a menu can
  /// show the same combination the global registration uses. `nil` for keys that
  /// have no character, which a menu cannot display anyway.
  public var menuCharacter: String? {
    Self.menuCharacters[keyCode]
  }

  public enum ValidationError: Error, Equatable, Sendable {
    case missingModifier
  }
}

extension EvieShortcut.ValidationError: LocalizedError {
  public var errorDescription: String? {
    switch self {
    case .missingModifier:
      "Um atalho global precisa de ⌘, ⌥ ou ⌃ para não capturar digitação comum."
    }
  }
}

extension EvieShortcut {
  fileprivate static let functionKeyCodes: Set<UInt16> = [
    122, 120, 99, 118, 96, 97, 98, 100, 101, 109, 103, 111,
  ]

  /// Virtual key codes are a stable ANSI layout mapping. Only the names shown to
  /// the user are localized; the codes themselves never change per language.
  fileprivate static let namedKeys: [UInt16: String] = [
    0: "A", 1: "S", 2: "D", 3: "F", 4: "H", 5: "G", 6: "Z", 7: "X", 8: "C", 9: "V",
    11: "B", 12: "Q", 13: "W", 14: "E", 15: "R", 16: "Y", 17: "T", 31: "O", 32: "U",
    34: "I", 35: "P", 37: "L", 38: "J", 40: "K", 45: "N", 46: "M",
    18: "1", 19: "2", 20: "3", 21: "4", 22: "6", 23: "5", 25: "9", 26: "7", 28: "8",
    29: "0",
    24: "=", 27: "-", 30: "]", 33: "[", 39: "'", 41: ";", 42: "\\", 43: ",", 44: "/",
    47: ".", 50: "`",
    36: "Return", 48: "Tab", 49: "Espaço", 51: "Delete", 53: "Esc",
    115: "Início", 116: "Page Up", 117: "Delete →", 119: "Fim", 121: "Page Down",
    123: "←", 124: "→", 125: "↓", 126: "↑",
    96: "F5", 97: "F6", 98: "F7", 99: "F3", 100: "F8", 101: "F9", 103: "F11",
    109: "F10", 111: "F12", 118: "F4", 120: "F2", 122: "F1",
  ]

  fileprivate static func keyName(for keyCode: UInt16) -> String {
    namedKeys[keyCode] ?? "Tecla \(keyCode)"
  }

  /// Lower-case characters, which is what `NSMenuItem` expects; the modifier mask
  /// carries the rest.
  fileprivate static let menuCharacters: [UInt16: String] = {
    var characters: [UInt16: String] = [
      49: " ", 36: "\r", 48: "\t", 53: "\u{1B}", 51: "\u{8}",
      123: "\u{2190}", 124: "\u{2192}", 125: "\u{2193}", 126: "\u{2191}",
    ]
    for (code, name) in namedKeys where name.count == 1 {
      characters[code] = name.lowercased()
    }
    return characters
  }()
}
