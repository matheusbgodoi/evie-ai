import Foundation

/// Finds the silence at the ends of a synthesised phrase.
///
/// A text-to-speech model gives every phrase a little room to breathe at each
/// end — sensible in isolation, and the reason two consecutive phrases have a
/// gap between them that neither sentence asked for. Played back to back the
/// pauses add up, and a paragraph read out loud comes out haltingly.
///
/// Only the ends are touched. Silence *inside* a phrase is punctuation being
/// spoken — a comma, a full stop, the beat before a clause — and removing it
/// would be editing the delivery rather than the padding around it.
public enum EvieSilenceTrim {
  /// Below this a sample counts as silence.
  ///
  /// −45 dBFS. Room tone and the decay at the end of a word sit under it;
  /// anything anybody would call speech sits well above.
  public static let threshold: Float = 0.0056

  /// How much silence to leave in place, in seconds.
  ///
  /// Cutting to the exact first sample clips the attack of a plosive and makes
  /// the phrase start with a click. A little air is part of the sound.
  public static let keptSeconds: Double = 0.04

  /// The range of `samples` worth playing.
  ///
  /// Returns nil when the whole buffer is silence, which is a synthesis that
  /// produced nothing and should not be scheduled at all.
  public static func speechRange(
    in samples: [Float],
    sampleRate: Double
  ) -> Range<Int>? {
    guard !samples.isEmpty, sampleRate > 0 else {
      return nil
    }
    guard let first = samples.firstIndex(where: { abs($0) > threshold }),
      let last = samples.lastIndex(where: { abs($0) > threshold })
    else {
      return nil
    }
    let padding = Int(keptSeconds * sampleRate)
    let start = max(0, first - padding)
    let end = min(samples.count, last + padding + 1)
    guard start < end else {
      return nil
    }
    return start..<end
  }
}
