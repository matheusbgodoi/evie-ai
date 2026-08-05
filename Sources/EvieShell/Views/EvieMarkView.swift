import AppKit
import SwiftUI

/// Evie's mark: a key drawn in ASCII.
///
/// The art is drawn with its own characters. An earlier version replaced each
/// one with a glyph from a shading ramp according to how solid it was, which is
/// the technique for turning a *photograph* into ASCII — applied to art that was
/// already ASCII it destroyed the drawing, and the key came out as a scattering
/// of `+ : - =`. The light now changes only how bright a character is, never
/// which character it is.
enum EvieKeyArt {
  /// Three columns wide, so it still reads as a key inside a 30-point badge.
  static let compact = [
    " _ ",
    "(o)",
    " | ",
    " |=",
    " '=",
  ]

  /// For call mode and anywhere the mark is given real room.
  static let large = [
    "  _  ",
    " / \\ ",
    "( o )",
    " \\_/ ",
    "  |  ",
    "  |==",
    "  |  ",
    "  '==",
  ]

  static func art(forDiameter diameter: CGFloat) -> [String] {
    diameter < 52 ? compact : large
  }
}

/// The colours that separate "you are talking" from "Evie is talking".
///
/// These are the system colours the interface already used. Only one value is
/// substituted, and only in light appearance: `.mint` resolves to 1.82:1 against
/// the HUD surface there, below the 3:1 WCAG asks of a graphical object, which
/// made "listening" almost invisible on a light desktop. Dark appearance — where
/// it measures 9:1 — is untouched, so the look nobody complained about is exactly
/// the look that remains.
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

/// The circular badge that carries the key, the reactive ring, and the tap target
/// that opens the voice.
struct EvieMarkView: View {
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

  /// The cheap layer: a drawing rendered once and tilted by Core Animation.
  /// Measured at roughly a tenth the cost of redrawing every frame, which is what
  /// lets the mark stay alive while the overlay simply sits there.
  private var isTilting: Bool {
    isAnimating && !reduceMotion
  }

  /// The expensive layer: light sweeping across the key, one redraw per frame.
  /// Reserved for moments that have something real to convey.
  private var isSweeping: Bool {
    guard isTilting else {
      return false
    }
    switch state {
    case .listening, .speaking, .transcribing, .thinking, .usingTool: return true
    default: return false
    }
  }

  private var sweepInterval: Double {
    switch state {
    case .listening, .speaking: 1.0 / 30.0
    default: 1.0 / 20.0
    }
  }

  var body: some View {
    ZStack {
      badge

      EvieVoiceRing(
        samples: waveformSamples,
        tint: tint,
        direction: direction,
        isAnimating: isTilting
      )
      .frame(width: diameter * 1.5, height: diameter * 1.5)
      .allowsHitTesting(false)

      AsciiKeyCanvas(
        art: EvieKeyArt.art(forDiameter: diameter),
        isSweeping: isSweeping,
        sweepInterval: sweepInterval
      )
      // The compact art is three columns against five rows, so height binds and
      // there is horizontal room to spare. Giving it a little more of the badge
      // buys legibility that a 30-point circle badly needs.
      .frame(width: diameter * 0.76, height: diameter * 0.76)
      // Twelve degrees, not twenty. On a drawing this small a wide swing reads
      // as crooked rather than as depth.
      .rotation3DEffect(
        .degrees(isTilting ? 12 : -12),
        axis: (x: 0.1, y: 1, z: 0),
        anchorZ: 0,
        perspective: 0.6
      )
      .animation(
        isTilting
          ? .easeInOut(duration: 3.4).repeatForever(autoreverses: true)
          : .default,
        value: isTilting
      )
      .allowsHitTesting(false)
    }
    .frame(width: diameter, height: diameter)
    .contentShape(Circle())
    .onTapGesture {
      onActivate?()
    }
    .onHover { hovering in
      guard isInteractive, onActivate != nil else {
        return
      }
      if hovering {
        NSCursor.pointingHand.push()
      } else {
        NSCursor.pop()
      }
    }
    .help(helpText)
    .accessibilityAddTraits(onActivate == nil ? [] : .isButton)
    .accessibilityLabel(accessibilityLabel)
  }

  /// The flat badge the interface already had: one colour with a soft diagonal
  /// lift, a hairline rim, and a coloured shadow. Not a radial gradient.
  private var badge: some View {
    Circle()
      .fill(
        LinearGradient(
          colors: [tint.opacity(0.82), tint],
          startPoint: .topLeading,
          endPoint: .bottomTrailing
        )
      )
      .overlay {
        Circle().strokeBorder(.white.opacity(0.22), lineWidth: 0.6)
      }
      .shadow(color: tint.opacity(0.32), radius: 6)
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

/// Draws the key on a square-celled grid.
///
/// Square cells matter: a monospaced glyph box is about 1.9 times taller than it
/// is wide, so stacked `Text` rows would stretch the drawing vertically.
private struct AsciiKeyCanvas: View {
  var art: [String]
  var isSweeping: Bool
  var sweepInterval: Double

  var body: some View {
    if isSweeping {
      TimelineView(.animation(minimumInterval: sweepInterval, paused: false)) { timeline in
        canvas(at: timeline.date.timeIntervalSinceReferenceDate)
      }
    } else {
      // No timeline in the tree at all. Ordering the panel out does not stop a
      // running timeline, so absence is the only reliable off switch.
      canvas(at: 0)
    }
  }

  private func canvas(at time: TimeInterval) -> some View {
    Canvas(opaque: false, rendersAsynchronously: false) { context, size in
      draw(in: &context, size: size, time: time)
    } symbols: {
      ForEach(Self.alphabet, id: \.self) { character in
        Text(String(character))
          .font(.system(size: 12, weight: .bold, design: .monospaced))
          .foregroundStyle(.white)
          .tag(character)
      }
    }
  }

  /// Every character any of the arts uses. Declared as canvas symbols so text
  /// shaping happens once instead of per glyph per frame.
  private static let alphabet: [Character] = ["_", "(", ")", "o", "|", "=", "'", "/", "\\"]

  private func draw(in context: inout GraphicsContext, size: CGSize, time: TimeInterval) {
    let rowCount = art.count
    guard rowCount > 0, let columnCount = art.first?.count, columnCount > 0 else {
      return
    }
    let cell = min(size.width / CGFloat(columnCount), size.height / CGFloat(rowCount))
    guard cell > 0.4 else {
      return
    }
    let originX = (size.width - cell * CGFloat(columnCount)) / 2
    let originY = (size.height - cell * CGFloat(rowCount)) / 2
    // Symbols are laid out at twelve points; scale the drawing rather than
    // re-resolving them at every size.
    let glyphScale = cell * 1.5 / 12

    for (rowIndex, row) in art.enumerated() {
      for (columnIndex, character) in row.enumerated() where character != " " {
        guard let glyph = context.resolveSymbol(id: character) else {
          continue
        }
        // Light travels across the face. It changes brightness only — the
        // character always stays the one the drawing calls for.
        let sweep =
          time == 0
          ? 0.75
          : 0.5 + 0.5
            * sin(time * 2.0 + Double(columnIndex) * 0.7 - Double(rowIndex) * 0.45)

        let centreX = originX + (CGFloat(columnIndex) + 0.5) * cell
        let centreY = originY + (CGFloat(rowIndex) + 0.5) * cell
        context.opacity = 0.72 + 0.28 * sweep
        context.draw(
          glyph,
          in: CGRect(
            x: centreX - glyph.size.width * glyphScale / 2,
            y: centreY - glyph.size.height * glyphScale / 2,
            width: glyph.size.width * glyphScale,
            height: glyph.size.height * glyphScale
          )
        )
      }
    }
    context.opacity = 1
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
