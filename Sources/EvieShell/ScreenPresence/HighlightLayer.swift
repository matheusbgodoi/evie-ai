import AppKit
import EvieCore
import QuartzCore

/// The amber frame around the element Evie is about to press or the field she
/// is typing into, taken from its Accessibility frame — or from the model's
/// box when the app reports none.
///
/// Filled and solid where the reticle is open brackets: the reticle says
/// "looking here", this says "acting on this".
final class HighlightLayer: CALayer {
  private let frameLayer = CALayer()
  /// A dark hairline just outside the amber, so the frame stays readable on a
  /// yellow or orange interface.
  private let hairline = CALayer()
  private let chip = TypingChipLayer()
  private(set) var target: CGRect?

  override init() {
    super.init()
    hairline.cornerRadius = 7
    hairline.borderWidth = 1
    hairline.borderColor = NSColor.black.withAlphaComponent(0.25).cgColor
    frameLayer.cornerRadius = 6
    frameLayer.borderWidth = 2
    frameLayer.addSublayer(hairline)
    addSublayer(frameLayer)
    addSublayer(chip)
    opacity = 0
    chip.opacity = 0
  }

  override init(layer: Any) {
    super.init(layer: layer)
  }

  @available(*, unavailable)
  required init?(coder: NSCoder) {
    fatalError("init(coder:) has not been implemented")
  }

  func setColours(in appearance: NSAppearance) {
    PresenceMotion.set {
      frameLayer.borderColor = EviePresenceTint.acting.resolved(in: appearance)
      frameLayer.backgroundColor = EviePresenceTint.acting.resolved(in: appearance, alpha: 0.1)
      frameLayer.shadowColor = EviePresenceTint.actingHalo.resolved(in: appearance)
      frameLayer.shadowOpacity = 0.45
      frameLayer.shadowRadius = 6
      frameLayer.shadowOffset = .zero
      chip.setColours(in: appearance)
    }
  }

  /// Frames `rect`. Enters with a fade and a settle from 1.04; when already
  /// up, slides to the new element with a spring from where it is.
  func highlight(_ rect: CGRect) {
    let wasVisible = target != nil
    target = rect
    let response = 0.3
    if wasVisible && !PresenceMotion.reducesMotion {
      PresenceMotion.spring(frameLayer, "position.x", to: rect.midX, response: response)
      PresenceMotion.spring(frameLayer, "position.y", to: rect.midY, response: response * 1.1)
      PresenceMotion.spring(frameLayer, "bounds.size.width", to: rect.width, response: response)
      PresenceMotion.spring(frameLayer, "bounds.size.height", to: rect.height, response: response)
      PresenceMotion.set { hairline.frame = CGRect(origin: .zero, size: rect.size).insetBy(dx: -1, dy: -1) }
      PresenceMotion.ease(self, "opacity", to: Float(1), duration: 0.12)
      return
    }
    PresenceMotion.set {
      frameLayer.bounds = CGRect(origin: .zero, size: rect.size)
      frameLayer.position = CGPoint(x: rect.midX, y: rect.midY)
      hairline.frame = frameLayer.bounds.insetBy(dx: -1, dy: -1)
    }
    PresenceMotion.ease(self, "opacity", to: Float(1), duration: 0.16)
    guard !PresenceMotion.reducesMotion else {
      return
    }
    let settle = CABasicAnimation(keyPath: "transform.scale")
    settle.fromValue = 1.04
    settle.toValue = 1
    settle.duration = 0.16
    settle.timingFunction = PresenceMotion.easeOut
    frameLayer.add(settle, forKey: "enter")
  }

  /// Shows the "Digitando…" chip at the top-left of the highlighted field —
  /// above it when there is room, inside the panel either way.
  func showTypingChip(in panelBounds: CGRect) {
    guard let target else {
      return
    }
    let size = chip.preferredSize
    var origin = CGPoint(x: target.minX, y: target.minY - size.height - 6)
    if origin.y < panelBounds.minY + 4 {
      origin.y = target.maxY + 6
    }
    origin.x = min(max(origin.x, panelBounds.minX + 4), panelBounds.maxX - size.width - 4)
    PresenceMotion.set { chip.frame = CGRect(origin: origin, size: size) }
    chip.startWave()
    PresenceMotion.ease(chip, "opacity", to: Float(1), duration: 0.16)
  }

  func hideTypingChip() {
    PresenceMotion.ease(chip, "opacity", to: Float(0), duration: 0.12)
    chip.stopWave()
  }

  /// The reduced-motion stand-in for the click ripple: the frame flashes to
  /// full strength once.
  func flash() {
    let flash = CABasicAnimation(keyPath: "backgroundColor")
    flash.fromValue = frameLayer.borderColor
    flash.toValue = frameLayer.backgroundColor
    flash.duration = 0.2
    frameLayer.add(flash, forKey: "flash")
  }

  func fadeOut(duration: Double) {
    target = nil
    PresenceMotion.ease(self, "opacity", to: Float(0), duration: duration)
    chip.stopWave()
    PresenceMotion.ease(chip, "opacity", to: Float(0), duration: duration)
  }
}

/// The small amber tag that says Evie is typing, carrying the same travelling
/// dots as the thinking indicator. Nothing in it reacts to keystrokes:
/// keyboard-driven actions never animate.
final class TypingChipLayer: CALayer {
  private let label = CATextLayer()
  private let dots = (0..<3).map { _ in CALayer() }
  nonisolated(unsafe) private static let font = NSFont.systemFont(ofSize: 11, weight: .semibold)
  private static let dotSize: CGFloat = 4

  override init() {
    super.init()
    cornerRadius = 8
    label.string = ScreenPresenceCopy.typingChip
    label.font = Self.font
    label.fontSize = Self.font.pointSize
    label.contentsScale = 2
    addSublayer(label)
    for dot in dots {
      dot.cornerRadius = Self.dotSize / 2
      addSublayer(dot)
    }
    layOutContents()
  }

  override init(layer: Any) {
    super.init(layer: layer)
  }

  @available(*, unavailable)
  required init?(coder: NSCoder) {
    fatalError("init(coder:) has not been implemented")
  }

  var preferredSize: CGSize {
    CGSize(width: 10 + 3 * Self.dotSize + 2 * 3 + 6 + textWidth + 10, height: 20)
  }

  private var textWidth: CGFloat {
    ceil((ScreenPresenceCopy.typingChip as NSString).size(withAttributes: [.font: Self.font]).width)
  }

  func setColours(in appearance: NSAppearance) {
    backgroundColor = EviePresenceTint.acting.resolved(in: appearance)
    // Dark text on amber in both appearances: amber is light enough that
    // white on it fails contrast in dark mode, where the amber is brightest.
    let ink = NSColor(white: 0.08, alpha: 0.9).cgColor
    label.foregroundColor = ink
    for dot in dots {
      dot.backgroundColor = ink
    }
    shadowColor = NSColor.black.cgColor
    shadowOpacity = 0.25
    shadowRadius = 3
    shadowOffset = CGSize(width: 0, height: 1)
  }

  override func layoutSublayers() {
    super.layoutSublayers()
    layOutContents()
  }

  private func layOutContents() {
    let height = bounds.height > 0 ? bounds.height : 20
    for (index, dot) in dots.enumerated() {
      dot.frame = CGRect(
        x: 10 + CGFloat(index) * (Self.dotSize + 3),
        y: (height - Self.dotSize) / 2,
        width: Self.dotSize,
        height: Self.dotSize
      )
    }
    let textHeight = ceil(Self.font.ascender - Self.font.descender)
    label.frame = CGRect(
      x: 10 + 3 * Self.dotSize + 6 + 6, y: (height - textHeight) / 2,
      width: textWidth + 2, height: textHeight)
  }

  func startWave() {
    PresenceWave.start(on: dots)
  }

  func stopWave() {
    PresenceWave.stop(on: dots)
  }
}

/// The thinking dots' travelling wave as Core Animation keyframes, sampled
/// from `EvieThinkingWave` so the pill and the chip move exactly like the
/// thinking indicator does, with no per-frame work in this process.
enum PresenceWave {
  private static let samples = 24

  static func start(on dots: [CALayer]) {
    guard !PresenceMotion.reducesMotion else {
      for dot in dots { dot.opacity = 0.9 }
      return
    }
    for (index, dot) in dots.enumerated() {
      let animation = CAKeyframeAnimation(keyPath: "opacity")
      animation.values = (0...samples).map { step in
        EvieThinkingWave.opacity(forDot: index, at: Double(step) / Double(samples))
      }
      animation.duration = EvieThinkingWave.period
      animation.repeatCount = .infinity
      animation.calculationMode = .linear
      dot.add(animation, forKey: "wave")
    }
  }

  /// Removes the loops, so a hidden chip or pill leaves nothing running.
  static func stop(on dots: [CALayer]) {
    for dot in dots {
      dot.removeAnimation(forKey: "wave")
    }
  }
}
