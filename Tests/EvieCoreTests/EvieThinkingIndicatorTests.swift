import Foundation
import Testing

@testable import EvieCore

/// The wave that runs under the three dots while she thinks.
///
/// Tested because it is the one piece of the indicator that can be wrong in a
/// way nobody notices: dots that all pulse together read as a flashing block,
/// and a dot that reaches zero reads as one that vanished.
@Suite("Evie thinking indicator")
struct EvieThinkingIndicatorTests {
  @Test("no dot ever goes out completely")
  func staysVisible() {
    for step in 0..<120 {
      let phase = Double(step) / 120
      for dot in 0..<3 {
        let opacity = EvieThinkingWave.opacity(forDot: dot, at: phase)
        #expect(opacity > 0.2, "ponto \(dot) sumiu em \(phase)")
        #expect(opacity <= 1)
      }
    }
  }

  /// Three dots pulsing in unison is a flashing block, not a wave.
  @Test("the dots are out of step with each other")
  func dotsAreOffset() {
    let atStart = (0..<3).map { EvieThinkingWave.opacity(forDot: $0, at: 0) }

    #expect(Set(atStart.map { ($0 * 100).rounded() }).count == 3)
  }

  /// It loops, so there is no seam where the animation restarts visibly.
  @Test("the wave joins up where it repeats")
  func loopsCleanly() {
    for dot in 0..<3 {
      let start = EvieThinkingWave.opacity(forDot: dot, at: 0)
      let end = EvieThinkingWave.opacity(forDot: dot, at: 0.9999)
      #expect(abs(start - end) < 0.01, "ponto \(dot) salta ao repetir")
    }
  }
}
