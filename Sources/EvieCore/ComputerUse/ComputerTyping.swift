import Foundation

/// How a `type` action reaches the app, chosen by code before anything is
/// posted.
///
/// Three routes, in the order `auto` prefers them:
/// - the focused field's own value (`kAXValueAttribute`, or the selected
///   text for an insertion), read back afterwards, which posts no event and
///   touches no clipboard. Not in browsers: a page sees nothing of a value set
///   from outside, so its own code would submit the old one;
/// - the clipboard and ⌘V, for anything past 20 characters or with a
///   character beyond ASCII, which keyboard events carry unreliably (an
///   accented letter or an emoji typed as unicode keys is dropped or mangled
///   by some apps, and a long text is slow);
/// - unicode key events, at most 20 UTF-16 units per event, which is where
///   key events are known to start losing characters [community-reported
///   limit, not measured here].
public enum TypingMode: String, Sendable, Equatable, CaseIterable {
  case auto
  /// Only the field's value; a field that does not take one fails.
  case accessibility
  case paste
  case keys
}

public enum TypingRoute: Sendable, Equatable {
  /// Set the focused field's value; when the field does not take one, use
  /// `fallback` (`nil`: fail instead).
  indirect case accessibility(fallback: TypingRoute?)
  case paste
  /// Unicode key events, one per chunk, in order.
  case keys([String])
}

public enum ComputerTyping {
  /// UTF-16 units in one unicode key event.
  public static let maximumUnicodeChunk = 20
  /// Past this many characters a text is pasted.
  public static let pasteAbove = 20

  public static func route(
    for text: String,
    mode: TypingMode,
    accessibilityAllowed: Bool
  ) -> TypingRoute {
    switch mode {
    case .accessibility:
      return .accessibility(fallback: nil)
    case .paste:
      return .paste
    case .keys:
      return .keys(unicodeChunks(text))
    case .auto:
      let keyboard: TypingRoute = needsPaste(text) ? .paste : .keys(unicodeChunks(text))
      return accessibilityAllowed ? .accessibility(fallback: keyboard) : keyboard
    }
  }

  /// More than 20 characters, or any character outside ASCII.
  public static func needsPaste(_ text: String) -> Bool {
    text.count > pasteAbove || text.unicodeScalars.contains { !$0.isASCII }
  }

  /// `text` cut into pieces of at most `maximumUnicodeChunk` UTF-16 units.
  ///
  /// Cuts fall between characters, so a letter and its accent, a flag or an
  /// emoji arrive in one event; a single character too long for one event
  /// (a family emoji with skin tones) is cut between its scalars. Either way
  /// a surrogate pair is never split — half of one is not a character any
  /// app can show.
  public static func unicodeChunks(
    _ text: String,
    maximum: Int = maximumUnicodeChunk
  ) -> [String] {
    var chunks: [String] = []
    var current = ""
    var currentUnits = 0
    func flush() {
      if !current.isEmpty {
        chunks.append(current)
        current = ""
        currentUnits = 0
      }
    }
    for character in text {
      let units = character.utf16.count
      if units > maximum {
        flush()
        for scalar in character.unicodeScalars {
          let scalarUnits = UTF16.width(scalar)
          if currentUnits + scalarUnits > maximum {
            flush()
          }
          current.unicodeScalars.append(scalar)
          currentUnits += scalarUnits
        }
        flush()
        continue
      }
      if currentUnits + units > maximum {
        flush()
      }
      current.append(character)
      currentUnits += units
    }
    flush()
    return chunks
  }
}

/// macOS virtual key codes for the keys a `KeyChord` can name.
///
/// Letters, digits and symbols are given at their ANSI (US) positions. The
/// shell asks the keyboard layout in use first, since a symbol moves between
/// layouts; letters and digits sit at the same positions on ABNT2, the
/// owner's layout, so the table is right for them there too.
public enum ComputerKeyCodes {
  public struct Key: Sendable, Equatable {
    public let code: UInt16
    /// The character is the shifted one on its key ("!" on "1").
    public let shift: Bool

    public init(code: UInt16, shift: Bool) {
      self.code = code
      self.shift = shift
    }
  }

  /// The key for a `KeyChord.key`, or `nil` for one this table lacks.
  public static func key(for name: String) -> Key? {
    if let code = named[name] {
      return Key(code: code, shift: false)
    }
    if let code = ansi[name] {
      return Key(code: code, shift: false)
    }
    if let base = shifted[name], let code = ansi[base] {
      return Key(code: code, shift: true)
    }
    return nil
  }

  public static func code(for name: String) -> UInt16? {
    key(for: name)?.code
  }

  static let named: [String: UInt16] = [
    "return": 36, "tab": 48, "space": 49, "delete": 51, "escape": 53, "forwarddelete": 117,
    "home": 115, "end": 119, "pageup": 116, "pagedown": 121,
    "left": 123, "right": 124, "down": 125, "up": 126,
    "f1": 122, "f2": 120, "f3": 99, "f4": 118, "f5": 96, "f6": 97, "f7": 98, "f8": 100,
    "f9": 101, "f10": 109, "f11": 103, "f12": 111, "f13": 105, "f14": 107, "f15": 113,
    "f16": 106, "f17": 64, "f18": 79, "f19": 80, "f20": 90,
  ]

  static let ansi: [String: UInt16] = [
    "a": 0, "s": 1, "d": 2, "f": 3, "h": 4, "g": 5, "z": 6, "x": 7, "c": 8, "v": 9, "b": 11,
    "q": 12, "w": 13, "e": 14, "r": 15, "y": 16, "t": 17, "1": 18, "2": 19, "3": 20, "4": 21,
    "6": 22, "5": 23, "=": 24, "9": 25, "7": 26, "-": 27, "8": 28, "0": 29, "]": 30, "o": 31,
    "u": 32, "[": 33, "i": 34, "p": 35, "l": 37, "j": 38, "'": 39, "k": 40, ";": 41,
    "\\": 42, ",": 43, "/": 44, "n": 45, "m": 46, ".": 47, "`": 50,
  ]

  static let shifted: [String: String] = [
    "!": "1", "@": "2", "#": "3", "$": "4", "%": "5", "^": "6", "&": "7", "*": "8", "(": "9",
    ")": "0", "_": "-", "+": "=", "{": "[", "}": "]", "|": "\\", ":": ";", "\"": "'",
    "<": ",", ">": ".", "?": "/", "~": "`",
  ]
}
