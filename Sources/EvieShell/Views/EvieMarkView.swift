import AppKit
import SwiftUI

/// Evie's mark: a key drawn as ASCII characters.
///
/// The silhouette is a fixed grid drawn into a `Canvas` with square cells, which
/// is the only way to keep the proportions honest — a monospaced glyph cell is
/// about 1.9 times taller than it is wide, so stacked `Text` rows stretch the
/// key vertically.
enum EvieKeyArt {
  /// The only grid that stays legible inside a 28–34 pt badge.
  static let small = [
    " .-. ",
    "( o )",
    " '|' ",
    "  |= ",
    "  '= ",
  ]

  /// For a 44 pt mark and larger.
  static let medium = [
    "  ,-.  ",
    " ( o ) ",
    "  `|'  ",
    "   |   ",
    "   |=  ",
    "   |=  ",
    "   '   ",
  ]

  /// Call mode, 56 pt and up.
  static let large = [
    #"   ___   "#,
    #"  /   \  "#,
    #" |  o  | "#,
    #"  \___/  "#,
    #"    |    "#,
    #"    |    "#,
    #"    |==  "#,
    #"    |    "#,
    #"    |=   "#,
  ]

  /// Shading ramp, dark to bright.
  static let ramp = Array(" .:-=+*#%@")

  /// How solid each character of the source art is. Converted once at load, not
  /// per frame: the art never changes.
  static func density(_ art: [String]) -> [[Double]] {
    art.map { row in
      row.map { character in
        switch character {
        case " ": 0
        case ".", "'", "`", ",": 0.30
        case "-", "_", ":": 0.48
        case "=", "+": 0.66
        case "|", "/", "\\", "(", ")": 0.78
        case "o", "0", "O": 0.88
        default: 1
        }
      }
    }
  }

  static let smallDensity = density(small)
  static let mediumDensity = density(medium)
  static let largeDensity = density(large)

  /// Picks the densest grid that still resolves at the given diameter.
  static func density(forDiameter diameter: CGFloat) -> [[Double]] {
    switch diameter {
    case ..<44: smallDensity
    case ..<56: mediumDensity
    default: largeDensity
    }
  }
}

/// The two hues that separate "you are talking" from "Evie is talking".
///
/// Both pairs were chosen by contrast measurement rather than taste: every value
/// clears 4.5:1 against the HUD surface in light and in dark. The system's own
/// named colours do not — `.mint` resolves to 1.82:1 on a light desktop, which
/// makes "listening" effectively invisible.
enum EvieVoiceTint {
  static let input = dynamic(
    light: (0x0D, 0x77, 0x70),
    dark: (0x17, 0xCF, 0xC2)
  )
  static let output = dynamic(
    light: (0x71, 0x49, 0xE9),
    dark: (0x95, 0x77, 0xEE)
  )
  /// Resting mark: the same violet family as the outgoing voice, one step calmer.
  static let idle = dynamic(
    light: (0x5A, 0x3C, 0xC4),
    dark: (0x7E, 0x6A, 0xE0)
  )

  static func color(for direction: WaveformDirection?) -> Color {
    switch direction {
    case .input: input
    case .output: output
    case nil: idle
    }
  }

  /// Resolves per appearance, so the colour stays correct inside the vibrancy
  /// view and when Increase Contrast changes the effective appearance.
  private static func dynamic(
    light: (Int, Int, Int),
    dark: (Int, Int, Int)
  ) -> Color {
    Color(
      nsColor: NSColor(name: nil) { appearance in
        let components = appearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua ? dark : light
        return NSColor(
          srgbRed: CGFloat(components.0) / 255,
          green: CGFloat(components.1) / 255,
          blue: CGFloat(components.2) / 255,
          alpha: 1
        )
      }
    )
  }
}

/// The circular badge that carries the ASCII key, the reactive ring, and the tap
/// target that opens the voice.
struct EvieMarkView: View {
  var state: EvieVisualState
  var waveformSamples: [CGFloat] = []
  var diameter: CGFloat = 34
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

  /// The cheap layer: a rendered-once drawing tilted by Core Animation. Measured
  /// at roughly a tenth the cost of redrawing the glyphs every frame, which is
  /// what lets the mark stay alive while the overlay simply sits there.
  private var isTilting: Bool {
    isAnimating && !reduceMotion
  }

  /// The expensive layer: light actually sweeping across the key, one redraw per
  /// frame. Reserved for moments that have something real to convey.
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
      badgeBackground

      EvieVoiceRing(
        samples: waveformSamples,
        tint: tint,
        direction: direction,
        isAnimating: isTilting
      )
      .frame(width: diameter * 1.5, height: diameter * 1.5)
      .allowsHitTesting(false)

      AsciiKeyCanvas(
        density: EvieKeyArt.density(forDiameter: diameter),
        tint: tint,
        isSweeping: isSweeping,
        sweepInterval: sweepInterval,
        intensity: direction == nil ? 0.74 : 1
      )
      .frame(width: diameter * 0.62, height: diameter * 0.62)
      .rotation3DEffect(
        .degrees(isTilting ? 22 : -22),
        axis: (x: 0.12, y: 1, z: 0),
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

  private var badgeBackground: some View {
    Circle()
      .fill(
        RadialGradient(
          colors: [tint.opacity(0.95), tint.opacity(0.6)],
          center: .topLeading,
          startRadius: 0,
          endRadius: diameter
        )
      )
      .overlay {
        Circle().strokeBorder(.white.opacity(0.24), lineWidth: 0.7)
      }
      .shadow(color: tint.opacity(0.38), radius: 6)
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

/// Draws the key with square cells. Each cell picks a glyph from the ramp by how
/// solid it is and how much light reaches it.
private struct AsciiKeyCanvas: View {
  var density: [[Double]]
  var tint: Color
  var isSweeping: Bool
  var sweepInterval: Double
  var intensity: Double

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

  /// The ramp is declared as canvas symbols rather than resolved per frame.
  /// `context.resolve(Text:)` re-runs text shaping on every call and measured
  /// six times more expensive than reusing cached symbols.
  private func canvas(at time: TimeInterval) -> some View {
    Canvas(opaque: false, rendersAsynchronously: false) { context, size in
      draw(in: &context, size: size, time: time)
    } symbols: {
      ForEach(Array(EvieKeyArt.ramp.enumerated()), id: \.offset) { index, character in
        Text(String(character))
          .font(.system(size: 9, weight: .bold, design: .monospaced))
          .foregroundStyle(tint)
          .tag(index)
      }
    }
  }

  private func draw(in context: inout GraphicsContext, size: CGSize, time: TimeInterval) {
    let rowCount = density.count
    guard rowCount > 0, let columnCount = density.first?.count, columnCount > 0 else {
      return
    }
    // Square cells, so the key keeps its proportions whatever the font metrics.
    let cell = min(size.width / CGFloat(columnCount), size.height / CGFloat(rowCount))
    guard cell > 0.2 else {
      return
    }
    let originX = (size.width - cell * CGFloat(columnCount)) / 2
    let originY = (size.height - cell * CGFloat(rowCount)) / 2

    let glyphs = (0..<EvieKeyArt.ramp.count).compactMap(context.resolveSymbol(id:))
    guard glyphs.count == EvieKeyArt.ramp.count else {
      return
    }
    let glyphScale = cell / 6.2

    for (rowIndex, row) in density.enumerated() {
      for (columnIndex, solidity) in row.enumerated() where solidity > 0 {
        // Light travels down and across the face of the key.
        let sweep =
          time == 0
          ? 0.72
          : 0.5 + 0.5 * sin(time * 2.1 - Double(rowIndex) * 0.55 + Double(columnIndex) * 0.3)
        let shaded = min(max(solidity * (0.55 + 0.45 * sweep) * intensity, 0), 1)
        let index = min(
          EvieKeyArt.ramp.count - 1,
          Int(shaded * Double(EvieKeyArt.ramp.count - 1) + 0.5)
        )
        guard index > 0 else {
          continue
        }

        let glyph = glyphs[index]
        let centreX = originX + (CGFloat(columnIndex) + 0.5) * cell
        let centreY = originY + (CGFloat(rowIndex) + 0.5) * cell
        context.opacity = 0.6 + 0.4 * shaded
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
/// survive the common colour-vision differences, where teal and violet both fall
/// towards blue.
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
