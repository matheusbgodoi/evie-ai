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

/// A data-driven waveform with no internal timer. The audio owner controls its
/// refresh rate, so an idle overlay never redraws just for decoration.
struct WaveformView: View {
  var samples: [CGFloat]
  var direction: WaveformDirection = .input
  var tint: Color = .mint
  var isActive = true
  var barCount = 28

  @Environment(\.accessibilityReduceMotion) private var reduceMotion

  var body: some View {
    GeometryReader { proxy in
      let bars = normalizedBars
      let availableWidth = max(proxy.size.width, 1)
      let gap: CGFloat = 2
      let width = max(2, (availableWidth - gap * CGFloat(bars.count - 1)) / CGFloat(bars.count))

      HStack(alignment: .center, spacing: gap) {
        ForEach(Array(bars.enumerated()), id: \.offset) { index, sample in
          Capsule(style: .continuous)
            .fill(
              LinearGradient(
                colors: [tint.opacity(0.54), tint],
                startPoint: .bottom,
                endPoint: .top
              )
            )
            .frame(
              width: width,
              height: barHeight(
                sample: sample,
                index: index,
                availableHeight: proxy.size.height
              )
            )
            .opacity(isActive ? 1 : 0.28)
        }
      }
      .frame(maxWidth: .infinity, maxHeight: .infinity)
      .animation(
        reduceMotion ? nil : .smooth(duration: 0.11),
        value: normalizedBars
      )
    }
    .frame(minHeight: 18)
    .accessibilityElement(children: .ignore)
    .accessibilityLabel(direction.accessibilityLabel)
    .accessibilityValue(accessibilityValue)
  }

  private var normalizedBars: [CGFloat] {
    let count = max(barCount, 1)
    guard !samples.isEmpty else {
      return Array(repeating: 0.04, count: count)
    }

    if samples.count == count {
      return samples.map(clamp)
    }

    return (0..<count).map { index in
      let position = CGFloat(index) / CGFloat(max(count - 1, 1))
      let sourceIndex = Int((position * CGFloat(samples.count - 1)).rounded())
      return clamp(samples[sourceIndex])
    }
  }

  private func barHeight(sample: CGFloat, index: Int, availableHeight: CGFloat) -> CGFloat {
    let minimum = min(max(availableHeight * 0.14, 3), availableHeight)
    let shaped = pow(sample, 0.72)
    let symmetryBias = 0.82 + 0.18 * sin(CGFloat(index) * 0.86 + 0.7)
    return max(
      minimum, min(availableHeight, minimum + shaped * symmetryBias * (availableHeight - minimum)))
  }

  private func clamp(_ value: CGFloat) -> CGFloat {
    min(max(value, 0), 1)
  }

  private var accessibilityValue: String {
    let peak = normalizedBars.max() ?? 0
    return "\(Int((peak * 100).rounded())) por cento"
  }
}
