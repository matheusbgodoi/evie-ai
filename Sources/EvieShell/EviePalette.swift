import AppKit

/// Colours that more than one surface draws with, defined once.
///
/// Violet is Evie's own colour (`docs/UI_UX.md`, "Voice colours"): it is her
/// voice going out (`EvieVoiceTint.output`) and her look at the screen
/// (`EviePresenceTint.seeing`), so the waveform and the glow must stay the same
/// hue. Until the v2 branches were merged on 2026-10-16 each kept its own copy of
/// the pair; one definition keeps a later change from moving only one of them.
enum EviePalette {
  /// Evie's violet: `#7149E9` in light appearance, `#9577EE` in dark.
  static let violet = adaptive(light: rgb(0x7149E9), dark: rgb(0x9577EE))

  /// An opaque sRGB colour from `0xRRGGBB`.
  static func rgb(_ hex: UInt32) -> NSColor {
    NSColor(
      srgbRed: CGFloat((hex >> 16) & 0xFF) / 255,
      green: CGFloat((hex >> 8) & 0xFF) / 255,
      blue: CGFloat(hex & 0xFF) / 255,
      alpha: 1
    )
  }

  /// A colour that resolves per appearance, as `docs/UI_UX.md` asks of every
  /// voice and presence colour.
  static func adaptive(light: NSColor, dark: NSColor) -> NSColor {
    NSColor(name: nil) { appearance in
      appearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua ? dark : light
    }
  }
}
