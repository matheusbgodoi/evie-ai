import AppKit
import SwiftUI

/// The colours that separate "you are talking" from "Evie is talking".
///
/// These are the system colours the interface has always used. Only one value is
/// substituted, and only in light appearance: `.mint` resolves to 1.82:1 against
/// the HUD surface there, below the 3:1 WCAG asks of a graphical object, which
/// made "listening" almost invisible on a light desktop. Dark appearance — where
/// it measures 9:1 — is untouched.
enum EvieVoiceTint {
  static let input = adaptive(
    light: NSColor(srgbRed: 0x0D / 255, green: 0x77 / 255, blue: 0x70 / 255, alpha: 1),
    dark: NSColor(Color.mint)
  )
  static let output = Color.pink
  static let idle = Color.indigo

  static func color(for direction: WaveformDirection?) -> Color {
    switch direction {
    case .input: input
    case .output: output
    case nil: idle
    }
  }

  private static func adaptive(light: NSColor, dark: NSColor) -> Color {
    Color(
      nsColor: NSColor(name: nil) { appearance in
        appearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua ? dark : light
      }
    )
  }
}

/// Evie's mark: the sparkle badge, which is also the button that opens the voice.
///
/// An ASCII key lived here briefly and is in the history if it is ever wanted at a
/// larger size. At thirty points the sparkle is simply the better mark: it is a
/// vector, so it stays crisp, and the system animates it for free.
struct EvieMarkView: View {
  /// One half-cycle of the breathing motion.
  private static let breathPeriod: TimeInterval = 2.6

  var state: EvieVisualState
  var waveformSamples: [CGFloat] = []
  var diameter: CGFloat = 30
  /// False while the overlay is off screen or the user turned motion off.
  var isAnimating = true
  var isInteractive = true
  var onActivate: (() -> Void)? = nil

  @Environment(\.accessibilityReduceMotion) private var reduceMotion

  private var direction: WaveformDirection? {
    state.waveformDirection
  }

  private var tint: Color {
    EvieVoiceTint.color(for: direction)
  }

  private var isMoving: Bool {
    isAnimating && !reduceMotion
  }

  var body: some View {
    ZStack {
      EvieVoiceRing(
        samples: waveformSamples,
        tint: tint,
        direction: direction,
        isAnimating: isMoving
      )
      .frame(width: diameter * 1.5, height: diameter * 1.5)
      .allowsHitTesting(false)

      // No `allowsHitTesting(false)` here: the badge handles its own hover and
      // click inside the layer view, and blocking hits made pressing the mark do
      // nothing at all.
      breathingBadge
    }
    .frame(width: diameter, height: diameter)
    .help(helpText)
    .accessibilityAddTraits(onActivate == nil ? [] : .isButton)
    .accessibilityLabel(accessibilityLabel)
  }

  /// The badge. Its breathing lives in Core Animation rather than SwiftUI; see
  /// `EvieBadgeLayerView` for the measurements that forced that.
  private var breathingBadge: some View {
    EvieBadgeLayerView(
      symbolName: "sparkles",
      tint: tint,
      diameter: diameter,
      isAnimating: isMoving,
      isInteractive: isInteractive && onActivate != nil,
      action: onActivate
    )
    .frame(width: diameter, height: diameter)
  }

  private var helpText: String {
    guard onActivate != nil else {
      return "Evie"
    }
    return direction == .input ? "Parar de ouvir" : "Falar com a Evie"
  }

  private var accessibilityLabel: String {
    switch direction {
    case .input: "Evie está ouvindo você"
    case .output: "Evie está falando"
    case nil: onActivate == nil ? "Evie" : "Falar com a Evie"
    }
  }
}

/// The reactive halo around the badge.
///
/// Direction is encoded twice: incoming audio grows inward with many thin bars,
/// outgoing audio grows outward with fewer thick ones. Colour alone would not
/// survive the common colour-vision differences.
private struct EvieVoiceRing: View {
  var samples: [CGFloat]
  var tint: Color
  var direction: WaveformDirection?
  var isAnimating: Bool

  var body: some View {
    Canvas(opaque: false, rendersAsynchronously: false) { context, size in
      draw(in: &context, size: size)
    }
    .opacity(direction == nil ? 0 : 1)
    .animation(isAnimating ? .smooth(duration: 0.18) : nil, value: direction)
    .animation(isAnimating ? .smooth(duration: 0.09) : nil, value: samples)
  }

  private var barCount: Int {
    direction == .input ? 44 : 22
  }

  private var lineWidth: CGFloat {
    direction == .input ? 1.3 : 2.4
  }

  private func draw(in context: inout GraphicsContext, size: CGSize) {
    guard let direction else {
      return
    }
    let centre = CGPoint(x: size.width / 2, y: size.height / 2)
    let ringRadius = min(size.width, size.height) * 0.4
    let maximumLength = min(size.width, size.height) * 0.12
    let levels = resampled()

    // One path, one stroke: separate strokes per bar measured several times more
    // expensive for no visual difference.
    var path = Path()
    for index in 0..<barCount {
      let angle = (Double(index) / Double(barCount)) * 2 * .pi - .pi / 2
      let level = Double(levels[index])
      let length = maximumLength * (0.16 + 0.84 * level)
      let inner = direction == .input ? ringRadius - length : ringRadius
      let outer = direction == .input ? ringRadius : ringRadius + length
      path.move(
        to: CGPoint(x: centre.x + cos(angle) * inner, y: centre.y + sin(angle) * inner)
      )
      path.addLine(
        to: CGPoint(x: centre.x + cos(angle) * outer, y: centre.y + sin(angle) * outer)
      )
    }

    context.stroke(
      path,
      with: .color(tint.opacity(0.72)),
      style: StrokeStyle(lineWidth: lineWidth, lineCap: .round)
    )
  }

  /// Stretches whatever the audio owner supplied across the ring. With no data
  /// the ring stays flat rather than inventing movement.
  private func resampled() -> [CGFloat] {
    guard !samples.isEmpty else {
      return Array(repeating: 0, count: barCount)
    }
    return (0..<barCount).map { index in
      let position = CGFloat(index) / CGFloat(max(barCount - 1, 1))
      let sourceIndex = Int((position * CGFloat(samples.count - 1)).rounded())
      return min(max(samples[sourceIndex], 0), 1)
    }
  }
}
