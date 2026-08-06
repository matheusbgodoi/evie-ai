import Foundation

/// The wave that travels under the three dots shown while she is thinking.
///
/// Here rather than in the view because it is the one part of the indicator that
/// can be wrong invisibly: dots pulsing in unison read as a flashing block, a
/// dot that reaches zero reads as one that disappeared, and a wave that does not
/// join up where it repeats shows a seam every cycle.
///
/// Deliberately not a spinner. A spinner claims progress it cannot measure, and
/// how long a local model will take is the one thing nobody knows.
public enum EvieThinkingWave {
  /// How long one full pass takes.
  public static let period = 1.2

  /// How bright a dot is at a point in the cycle.
  ///
  /// Never reaches zero: the floor keeps the row reading as one object rather
  /// than three that keep vanishing.
  ///
  /// A sine rather than the triangle this started as. A triangle is symmetric
  /// about its midpoint, so the dots a third and two thirds along the cycle sit
  /// at exactly the same brightness at every instant — they mirror each other
  /// instead of following each other, and the row bounces rather than travels.
  /// Caught by a test asserting the three are distinct; it is not the kind of
  /// thing that survives being looked at once and approved.
  public static func opacity(forDot index: Int, at phase: Double) -> Double {
    let offset = Double(index) / 3
    let angle = 2 * Double.pi * (phase - offset)
    return 0.28 + 0.62 * (0.5 + 0.5 * sin(angle))
  }
}
