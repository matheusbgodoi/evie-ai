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

  /// Samples ignored when listening starts, while the meter climbs out of zero.
  ///
  /// Measured on this Mac: the published level takes about 0.6 s to reach the
  /// room's real level, ramping 0.000 → 0.098 → 0.251 → 0.300. Anything read
  /// before that describes the meter, not the room.
  private static let settleSamples = 25
  /// How much recent history the floor is estimated from. Long enough to contain
  /// a gap between sentences, which is what makes the estimate a floor rather
  /// than an average of whatever is being said.
  private static let windowSamples = 200
  /// Which point of that window is taken as the floor. Not the minimum: a single
  /// dip — or the tail of the meter warming up — would drag it far below the
  /// room and make the room itself read as speech, which is exactly what
  /// happened. A low percentile is the quiet part of the window without being
  /// the single quietest instant in it.
  private static let floorPercentile = 0.2

  /// Speech has to clear the floor by at least this much.
  ///
  /// Sized from the real range this meter produces rather than from theory. In
  /// the measured trace the room sat between 0.26 and 0.45 while speech reached
  /// 0.72, so a margin of a few hundredths — which is what was here — could not
  /// tell them apart at all.
  private static let minimumSpeechMargin: CGFloat = 0.11
  /// And proportionally, so a louder room needs a louder voice.
  private static let speechMarginRatio: CGFloat = 0.42
  /// Falling back to this much above the floor counts as stopped. Lower than the
  /// starting threshold on purpose: without that gap the gate chatters on every
  /// syllable.
  private static let minimumSilenceMargin: CGFloat = 0.045
  private static let silenceMarginRatio: CGFloat = 0.17

  public var sampleInterval: Duration
  /// How much silence ends a turn. Long enough to survive a pause for breath,
  /// short enough that a finished sentence does not sit there waiting.
  public var silenceToEndTurn: Duration
  /// How much speech must be heard before a turn can end. A cough, a chair, or a
  /// keystroke is not a turn, and ending on one submits nothing.
  public var minimumSpeech: Duration
  /// After this much unbroken sound with no dip at all, the gate stops believing
  /// its own floor.
  ///
  /// Nobody talks for ten seconds without a gap between words. When the level
  /// never falls below the silence threshold for that long, the reading that is
  /// wrong is the floor, not the speaker — so it is re-estimated from the
  /// quietest moment actually observed and the turn starts over. Without this the
  /// gate can latch: a floor that is too low keeps every sample above the
  /// threshold, so nothing ever counts as a dip, so the floor is never corrected.
  public var maximumUnbrokenSpeech: Duration

  /// Recent levels, oldest first, bounded to `windowSamples`.
  private var window: [CGFloat] = []
  private var floor: CGFloat = 0
  private var samplesSeen = 0
  private var isSpeaking = false
  private var speechSamples = 0
  private var silentSamples = 0
  private var hasEnded = false

  public init(
    sampleInterval: Duration = .milliseconds(40),
    silenceToEndTurn: Duration = .milliseconds(900),
    minimumSpeech: Duration = .milliseconds(280),
    maximumUnbrokenSpeech: Duration = .seconds(6)
  ) {
    self.sampleInterval = sampleInterval
    self.silenceToEndTurn = silenceToEndTurn
    self.minimumSpeech = minimumSpeech
    self.maximumUnbrokenSpeech = maximumUnbrokenSpeech
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

    // Exactly zero means the meter has no audio yet, not that the room is
    // silent — no microphone reports a true zero once it is running. Letting
    // those into the window dragged the floor below anything real and made the
    // room itself read as speech.
    guard level > 0 else {
      return .none
    }
    samplesSeen += 1

    // The settling samples are not merely ignored for deciding — they are kept
    // out of the window entirely. They describe the meter climbing out of zero,
    // and leaving them in dragged the estimated floor below the room, which is
    // the whole failure this guards against.
    guard samplesSeen > Self.settleSamples else {
      return .none
    }

    window.append(level)
    if window.count > Self.windowSamples {
      window.removeFirst(window.count - Self.windowSamples)
    }
    floor = Self.percentile(of: window, at: Self.floorPercentile)

    guard !hasEnded else {
      return .none
    }

    let start = speechThreshold
    let stop = silenceThreshold

    if isSpeaking {
      // Only voiced samples count towards "enough speech to be a turn".
      // Counting elapsed samples instead let a single click qualify simply by
      // being followed by enough silence.
      guard level < stop else {
        speechSamples += 1
        silentSamples = 0
        // Nobody talks this long without a gap between words. When it happens,
        // what is wrong is the estimate, not the speaker — so the turn is
        // abandoned rather than left latched forever.
        if speechSamples >= samples(in: maximumUnbrokenSpeech) {
          isSpeaking = false
          speechSamples = 0
          silentSamples = 0
        }
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

  /// The value at a given position of the sorted window.
  static func percentile(of values: [CGFloat], at fraction: Double) -> CGFloat {
    guard !values.isEmpty else {
      return 0
    }
    let sorted = values.sorted()
    let index = Int((Double(sorted.count - 1) * fraction).rounded())
    return sorted[min(max(index, 0), sorted.count - 1)]
  }

  /// Starts a fresh turn.
  ///
  /// The settle-and-learn window runs again, because the level meter restarts
  /// from zero every time the microphone is reopened — carrying the old floor
  /// across while the meter climbs would drag it straight back down to nothing.
  public mutating func reset() {
    isSpeaking = false
    speechSamples = 0
    silentSamples = 0
    hasEnded = false
    samplesSeen = 0
    floor = 0
    window.removeAll(keepingCapacity: true)
  }

  /// True once the room has been measured and the gate is able to decide.
  public var isListening: Bool {
    samplesSeen > Self.settleSamples
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
