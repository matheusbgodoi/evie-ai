import SwiftUI

enum WaveformDirection: Hashable {
  case input
  case output

  var accessibilityLabel: String {
    switch self {
    case .input:
      "Nível do microfone"
    case .output:
      "Nível da voz da Evie"
    }
  }
}

/// A live level trace, drawn from the audio and nothing else.
///
/// Three things it deliberately does not do. It has no timer of its own, so an
/// idle overlay never redraws for decoration. It applies no shaping pattern — an
/// earlier version multiplied each bar by `sin(index)` to look wave-like, which
/// made a steady tone come out rippling and meant the picture was partly
/// invented. And it draws in a single `Canvas` rather than as a stack of animated
/// capsules, because thirty independently animating SwiftUI views for something
/// that changes thirty times a second is a measurable amount of a CPU core.
///
/// Levels are read against the room's own noise floor, so quiet speech in a
/// silent room and ordinary speech next to a fan both fill the same height. That
/// is what makes it feel responsive: the movement tracks *you*, not the room.
struct WaveformView: View {
  var samples: [CGFloat]
  var direction: WaveformDirection = .input
  var tint: Color = .mint
  var isActive = true
  var barCount = 30
  /// The measured ambient level, subtracted so the trace sits flat when nobody
  /// is talking. Zero means "no estimate yet", which simply shows raw levels.
  var noiseFloor: CGFloat = 0

  @Environment(\.accessibilityReduceMotion) private var reduceMotion

  var body: some View {
    Canvas(opaque: false, rendersAsynchronously: false) { context, size in
      draw(in: &context, size: size)
    }
    .frame(minHeight: 20)
    .animation(reduceMotion ? nil : .linear(duration: 0.045), value: samples)
    .accessibilityElement(children: .ignore)
    .accessibilityLabel(direction.accessibilityLabel)
    .accessibilityValue(accessibilityValue)
  }

  private func draw(in context: inout GraphicsContext, size: CGSize) {
    let bars = normalisedBars
    guard !bars.isEmpty, size.width > 0, size.height > 0 else {
      return
    }

    let gap: CGFloat = 2.5
    let width = max(1.5, (size.width - gap * CGFloat(bars.count - 1)) / CGFloat(bars.count))
    let middle = size.height / 2
    // A hairline at rest rather than nothing, so the trace reads as live and
    // silent rather than as broken.
    let minimumHeight = min(width, 2.5)
    let opacity = isActive ? 1.0 : 0.3

    for (index, sample) in bars.enumerated() {
      let x = CGFloat(index) * (width + gap)
      let height = max(minimumHeight, sample * size.height)
      let rect = CGRect(
        x: x,
        y: middle - height / 2,
        width: width,
        height: height
      )

      // Older samples sit further back, which is what gives the trace its sense
      // of direction without moving anything.
      let age = CGFloat(index) / CGFloat(max(bars.count - 1, 1))
      let strength = 0.42 + 0.58 * age
      context.fill(
        Path(roundedRect: rect, cornerRadius: width / 2),
        with: .color(tint.opacity(opacity * strength))
      )
    }
  }

  /// The samples, oldest first, measured above the noise floor.
  private var normalisedBars: [CGFloat] {
    let count = max(barCount, 1)
    guard !samples.isEmpty else {
      return Array(repeating: 0, count: count)
    }

    let resampled: [CGFloat]
    if samples.count == count {
      resampled = samples
    } else if samples.count > count {
      // Keep the newest, which is the part anyone is looking at.
      resampled = Array(samples.suffix(count))
    } else {
      resampled = Array(repeating: 0, count: count - samples.count) + samples
    }

    return resampled.map(shape)
  }

  /// Turns a raw level into a height.
  ///
  /// The floor is subtracted before scaling, so what is drawn is how far above
  /// the room someone is rather than how loud the room is. A gentle curve
  /// follows, because loudness is perceived closer to logarithmically than
  /// linearly and a linear bar makes normal speech look timid.
  private func shape(_ level: CGFloat) -> CGFloat {
    let floor = min(max(noiseFloor, 0), 0.9)
    let above = max(0, level - floor)
    let span = max(1 - floor, 0.1)
    return min(1, pow(above / span, 0.62))
  }

  private var accessibilityValue: String {
    let peak = normalisedBars.max() ?? 0
    return "\(Int((peak * 100).rounded())) por cento"
  }
}
