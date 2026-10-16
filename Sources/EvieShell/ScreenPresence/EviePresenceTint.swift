import AppKit

/// The colours of the screen presence indicator.
///
/// Two hues carry the one distinction that matters on screen: violet while
/// Evie is looking, amber once she has the mouse or the keyboard. Violet is
/// Evie's own colour (`docs/UI_UX.md`, "Voice colours"); amber marks the step
/// up in trust from looking to acting. Gray is the paused and stopped state,
/// where nothing is happening on her side.
///
/// Colour is never the only signal — each state also has its own shape (a
/// soft glow, a bracket reticle, a solid edge with a cursor, a half-width
/// glow) — because violet and amber can both drift under the common
/// colour-vision differences.
///
/// The layers that draw these do not follow AppKit's appearance changes on
/// their own, so every use goes through `resolved(in:)` with the panel's
/// appearance.
enum EviePresenceTint {
  /// The seeing and observing glow, reticle and pill dot: Evie's violet, the
  /// same definition her outgoing voice uses.
  static let seeing = EviePalette.violet
  /// The far end of the seeing gradient, so the glow is not one flat colour.
  static let seeingDeep = EviePalette.adaptive(
    light: EviePalette.rgb(0x4F46E5), dark: EviePalette.rgb(0x818CF8))
  /// The acting edge, the element highlight and the ghost cursor.
  static let acting = EviePalette.adaptive(
    light: EviePalette.rgb(0xB45309), dark: EviePalette.rgb(0xFBBF24))
  /// The halo around amber strokes, the same in both appearances.
  static let actingHalo = EviePalette.rgb(0xF59E0B)
  /// Paused and stopped.
  static let paused = NSColor.secondaryLabelColor
}

extension NSColor {
  /// This colour as a `CGColor` for `appearance`. A dynamic `NSColor` turned
  /// into a `CGColor` outside a drawing appearance resolves against whatever
  /// happens to be current, which is how a layer ends up light-mode violet on
  /// a dark desktop.
  func resolved(in appearance: NSAppearance, alpha: CGFloat = 1) -> CGColor {
    var colour = CGColor(gray: 0, alpha: 0)
    appearance.performAsCurrentDrawingAppearance {
      colour = withAlphaComponent(alpha).cgColor
    }
    return colour
  }
}
