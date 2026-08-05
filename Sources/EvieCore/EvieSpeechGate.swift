import CoreGraphics
import Foundation

/// Decides when someone started and stopped talking, from the level alone.
///
/// The previous version compared against two fixed numbers taken from one
/// measurement in one room. That works in that room and nowhere else: a quieter
/// speaker, a different microphone gain, or a fan in the background moves the
/// real levels past the constants, and the turn either never ends or ends in the
/// middle of a sentence. Here the thresholds are derived from the noise floor
/// the microphone is actually reporting, so the same code works in a silent room
/// and a noisy one.
///
/// Pure and synchronous so it can be tested against recorded level sequences
/// rather than by talking at a laptop.
public struct EvieSpeechGate: Sendable {
  /// What changed on this sample.
  public enum Event: Equatable, Sendable {
    case none
    case speechStarted
    case speechEnded
  }

  /// How fast the floor follows the level down. Quick, so walking into a quiet
  /// room is noticed within a second.
  private static let floorFallRate: CGFloat = 0.30
  /// And up. Very slow, so a person talking does not drag the floor up to their
  /// own voice and silence themselves.
  private static let floorRiseRate: CGFloat = 0.004
  /// Speech has to clear the floor by at least this much. Prevents a dead-silent
  /// microphone, where the floor is near zero, from hearing speech in noise.
  private static let minimumSpeechMargin: CGFloat = 0.045
  /// And proportionally, for a room where the floor is already high.
  private static let speechMarginRatio: CGFloat = 1.4
  /// Falling back to this much above the floor counts as stopped. Lower than the
  /// starting threshold on purpose: without that gap the gate chatters on every
  /// syllable.
  private static let minimumSilenceMargin: CGFloat = 0.018
  private static let silenceMarginRatio: CGFloat = 0.55

  public var sampleInterval: Duration
  /// How much silence ends a turn. Long enough to survive a pause for breath,
  /// short enough that a finished sentence does not sit there waiting.
  public var silenceToEndTurn: Duration
  /// How much speech must be heard before a turn can end. A cough, a chair, or a
  /// keystroke is not a turn, and ending on one submits nothing.
  public var minimumSpeech: Duration

  private var floor: CGFloat = 0
  private var hasSeenSample = false
  private var isSpeaking = false
  private var speechSamples = 0
  private var silentSamples = 0
  private var hasEnded = false

  public init(
    sampleInterval: Duration = .milliseconds(40),
    silenceToEndTurn: Duration = .milliseconds(900),
    minimumSpeech: Duration = .milliseconds(280)
  ) {
    self.sampleInterval = sampleInterval
    self.silenceToEndTurn = silenceToEndTurn
    self.minimumSpeech = minimumSpeech
  }

  /// The level above which the gate considers someone to be talking, right now.
  /// Exposed so the interface can draw against the same number the decision uses
  /// rather than a second guess at it.
  public var speechThreshold: CGFloat {
    floor + max(Self.minimumSpeechMargin, floor * Self.speechMarginRatio)
  }

  public var silenceThreshold: CGFloat {
    floor + max(Self.minimumSilenceMargin, floor * Self.silenceMarginRatio)
  }

  public var noiseFloor: CGFloat {
    floor
  }

  public var isHearingSpeech: Bool {
    isSpeaking
  }

  /// Takes one level sample and reports what it changed.
  ///
  /// Reports `speechEnded` at most once; the caller is expected to stop the
  /// microphone on it. Call `reset()` before listening again.
  public mutating func absorb(level: CGFloat) -> Event {
    let level = max(0, level)

    // Seeded from the first sample rather than from zero, so the gate does not
    // spend its first second treating ordinary room noise as speech.
    guard hasSeenSample else {
      hasSeenSample = true
      floor = level
      return .none
    }

    let start = speechThreshold
    let stop = silenceThreshold
    // Tracked before the decision, and never while speech is in progress in the
    // downward direction, so a long silence between words cannot pull the floor
    // down to the point where the following word looks like a shout.
    if level < floor {
      floor += (level - floor) * Self.floorFallRate
    } else if !isSpeaking {
      floor += (level - floor) * Self.floorRiseRate
    }

    guard !hasEnded else {
      return .none
    }

    if isSpeaking {
      // Only voiced samples count towards "enough speech to be a turn".
      // Counting elapsed samples instead let a single click qualify simply by
      // being followed by enough silence.
      guard level < stop else {
        speechSamples += 1
        silentSamples = 0
        return .none
      }

      silentSamples += 1
      guard silentSamples >= samples(in: silenceToEndTurn) else {
        return .none
      }
      guard speechSamples >= samples(in: minimumSpeech) else {
        // A chair, a cough, a keystroke. Not a turn, and not a state to stay
        // stuck in either: the gate goes back to waiting so a real turn can
        // still start.
        isSpeaking = false
        speechSamples = 0
        silentSamples = 0
        return .none
      }
      hasEnded = true
      isSpeaking = false
      return .speechEnded
    }

    if level >= start {
      isSpeaking = true
      speechSamples = 1
      silentSamples = 0
      return .speechStarted
    }
    return .none
  }

  /// Forgets the turn but keeps the learned floor, because the room has not
  /// changed between one question and the next.
  public mutating func reset() {
    isSpeaking = false
    speechSamples = 0
    silentSamples = 0
    hasEnded = false
  }

  private func samples(in duration: Duration) -> Int {
    let interval = Double(sampleInterval.components.seconds)
      + Double(sampleInterval.components.attoseconds) / 1e18
    let target = Double(duration.components.seconds)
      + Double(duration.components.attoseconds) / 1e18
    guard interval > 0 else {
      return 1
    }
    return max(1, Int((target / interval).rounded()))
  }
}
