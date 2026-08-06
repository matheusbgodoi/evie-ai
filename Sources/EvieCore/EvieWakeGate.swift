import Foundation

/// Decides which microphone buffers are worth handing to the recogniser while
/// Evie is armed, and keeps the ones that came just before that decision.
///
/// Arming used to run continuous speech recognition over everything the room
/// said. Measured on this Mac, 30 s armed cost about 4.4% of one core across
/// `evie-shell`, `localspeechrecognition` and `corespeechd` — for a phrase that
/// is spoken for perhaps a second a day. The microphone itself costs more than
/// that (`coreaudiod`, about 7%) and cannot be avoided while she is waiting, but
/// the recogniser can simply not be fed while nobody is talking.
///
/// The trap that makes the naive version useless: by the time a level threshold
/// is crossed, the first syllable is already past. "Ei" would be eaten and the
/// phrase would never match. So the buffers arriving while the gate is shut are
/// not discarded, they are kept in `EvieAudioRing`, and the moment the gate opens
/// they are flushed into the recogniser *before* the live buffer that opened it.
///
/// The ring is filled **only while the gate is shut**, which is what keeps the
/// audio contiguous. If it also filled while open, a gap shorter than the ring
/// would flush audio the recogniser had already been given, and the recogniser
/// would hear the same words twice — worse than no pre-roll at all.
///
/// This is a sibling of `EvieSpeechGate` rather than an extension of it, for two
/// reasons. It answers a different question — "has anyone started talking?"
/// rather than "has this turn finished?" — so the one-shot `speechEnded`, the
/// minimum-turn rule and the end-of-turn timers are all wrong shapes here; this
/// gate has to open and shut for as long as she stays armed. And it runs on the
/// real-time audio thread, where `EvieSpeechGate`'s windowed percentile cannot
/// go: it sorts an array on every sample, and sorting allocates. The idea is
/// borrowed — a threshold measured against the room rather than against a
/// constant — and implemented as an asymmetric one-pole tracker that follows the
/// quiet part of the signal without sorting, allocating, or blocking.
public struct EvieWakeGate: Sendable {
  /// What should happen to the buffer that produced this level.
  public enum Decision: Equatable, Sendable {
    /// Nobody is talking. Keep the buffer in the pre-roll and hand the recogniser
    /// nothing.
    case discard
    /// Talking just started. Flush the pre-roll first, then this buffer.
    case openWithPreRoll
    /// Already talking. This buffer goes straight to the recogniser.
    case feed
  }

  /// How long the gate stays shut before it will believe the room again.
  ///
  /// Nothing is gated during this window — every buffer is fed. Right after the
  /// engine starts there is no estimate of the room yet, and a gate that guesses
  /// at that moment can eat a phrase spoken immediately after arming. Half a
  /// second of unconditional feeding per recogniser cycle, against a 60 s cycle,
  /// is under 1% of the armed time.
  public var settle: Duration
  /// How long the level has to stay up before the gate opens.
  ///
  /// This is what stops a single click from waking the recogniser. It is
  /// deliberately short: the cost of opening on a noise is a little CPU, and the
  /// cost of not opening on speech is the feature not existing. Anything longer
  /// than the pre-roll would clip the phrase, whatever this number says.
  public var onsetConfirmation: Duration
  /// How much quiet closes the gate again. Long enough to sit through the gap
  /// between two words, which is the only reason it is not zero.
  public var hangover: Duration

  /// Speech has to clear the floor by at least this much.
  ///
  /// Measured, not chosen. The wake path reads the same normalised level
  /// `EvieLevelMeter` produces — RMS in decibels mapped from −55 dBFS to 0 — but
  /// per buffer and unsmoothed. A 40 s trace was recorded through the real
  /// microphone on this Mac, half of it the room on its own and half of it a voice
  /// from a metre away, and replayed against candidate thresholds:
  ///
  ///     room only  p10 0.195  p50 0.266  p90 0.351  máx 0.442
  ///     with voice p10 0.513  p50 0.618  p90 0.675  máx 0.718
  ///     tracked floor settles at 0.31
  ///
  /// With these margins that trace opens the gate on the first buffer of speech
  /// and never opens on the room, which was the whole point. Smaller margins were
  /// tried first and failed in the direction that matters least to notice: 0.085
  /// left the gate open 100% of the time and saved nothing at all.
  static let minimumOpenMargin: Float = 0.20
  /// And proportionally, so a louder room needs a louder voice.
  static let openMarginRatio: Float = 0.65
  /// Falling back to this much above the floor counts as quiet. Lower than the
  /// opening threshold on purpose: without the gap the gate chatters on every
  /// syllable, and every chatter is a splice in what the recogniser hears.
  static let minimumCloseMargin: Float = 0.09
  static let closeMarginRatio: Float = 0.30

  /// How quickly the floor follows the level downwards. Fast, because a level
  /// below the current floor is proof the floor is wrong.
  static let fallTimeConstant = 0.1
  /// And upwards, which is slow on purpose: a floor that chased speech upwards
  /// would close the gate in the middle of a sentence. Two seconds is enough for
  /// the floor to reach a room it has never heard within the first few seconds of
  /// arming, and far too slow to follow a sentence.
  static let riseTimeConstant = 2.0

  private var floor: Float = 0
  private var isOpen = false
  private var elapsed = 0.0
  private var aboveSeconds = 0.0
  private var quietSeconds = 0.0

  /// Everything is measured in seconds rather than in buffers, and that is not
  /// tidiness. The tap asks for 1024 frames and this Mac hands over 4800 —
  /// measured, 200 buffers in 20 s at 48 kHz — so a gate counting buffers had a
  /// hangover of 2.8 s instead of 0.6 s and never closed at all.
  public init(
    settle: Duration = .milliseconds(500),
    onsetConfirmation: Duration = .milliseconds(40),
    hangover: Duration = .milliseconds(600)
  ) {
    self.settle = settle
    self.onsetConfirmation = onsetConfirmation
    self.hangover = hangover
  }

  /// The level above which the gate will open, right now.
  public var openThreshold: Float {
    floor + max(Self.minimumOpenMargin, floor * Self.openMarginRatio)
  }

  public var closeThreshold: Float {
    floor + max(Self.minimumCloseMargin, floor * Self.closeMarginRatio)
  }

  public var noiseFloor: Float {
    floor
  }

  public var isFeeding: Bool {
    isOpen
  }

  /// Takes the level of one buffer and says what to do with it.
  ///
  /// Allocation-free and lock-free by construction: this runs inside the audio
  /// tap, where allocating or blocking is a dropout.
  public mutating func absorb(level rawLevel: Float, duration: Duration) -> Decision {
    let level = max(0, rawLevel)
    let seconds = Self.seconds(duration)
    elapsed += seconds

    // While settling, the floor is allowed to move quickly in both directions so
    // it reaches the room within the window, and nothing is gated.
    guard elapsed > Self.seconds(settle) else {
      floor += (level - floor) * Self.coefficient(seconds: seconds, timeConstant: Self.fallTimeConstant)
      isOpen = true
      return .feed
    }

    if level < floor {
      floor += (level - floor)
        * Self.coefficient(seconds: seconds, timeConstant: Self.fallTimeConstant)
    } else if !isOpen {
      // The floor is only allowed to climb while the gate is shut. Letting it
      // climb during speech is how a level gate closes on a talking person: the
      // floor chases the voice, the voice never clears it again, and the rest of
      // the sentence is thrown away.
      floor += (level - floor)
        * Self.coefficient(seconds: seconds, timeConstant: Self.riseTimeConstant)
    }

    if isOpen {
      guard level < closeThreshold else {
        quietSeconds = 0
        return .feed
      }
      quietSeconds += seconds
      guard quietSeconds >= Self.seconds(hangover) else {
        return .feed
      }
      isOpen = false
      aboveSeconds = 0
      return .discard
    }

    guard level >= openThreshold else {
      aboveSeconds = 0
      return .discard
    }
    aboveSeconds += seconds
    guard aboveSeconds >= Self.seconds(onsetConfirmation) else {
      // Still deciding. The buffer goes to the pre-roll, which is why waiting
      // here costs nothing: it will be fed if the gate opens.
      return .discard
    }
    isOpen = true
    quietSeconds = 0
    return .openWithPreRoll
  }

  /// How far a one-pole tracker moves in `seconds`, given its time constant.
  /// Written this way so the gate behaves the same whether the tap hands over
  /// 1024 frames or 4800.
  private static func coefficient(seconds: Double, timeConstant: Double) -> Float {
    guard timeConstant > 0 else {
      return 1
    }
    return Float(1 - exp(-seconds / timeConstant))
  }

  /// Starts over, for a new recogniser cycle.
  ///
  /// The floor goes with it. The microphone is reopened on every cycle and the
  /// room may not be the one it learned.
  public mutating func reset() {
    floor = 0
    isOpen = false
    elapsed = 0
    aboveSeconds = 0
    quietSeconds = 0
  }

  static func seconds(_ duration: Duration) -> Double {
    Double(duration.components.seconds) + Double(duration.components.attoseconds) / 1e18
  }
}

/// The last fraction of a second of audio, kept so the start of a phrase is not
/// lost to the decision that it was a phrase.
///
/// Fixed capacity, allocated once, written from the audio thread. Nothing here
/// grows, and the only work per buffer is a copy.
public struct EvieAudioRing: Sendable {
  private var storage: [Float]
  /// Where the oldest sample lives.
  private var start = 0
  private(set) public var count = 0

  public let capacity: Int

  public init(capacity: Int) {
    self.capacity = max(1, capacity)
    storage = [Float](repeating: 0, count: self.capacity)
  }

  public var isEmpty: Bool {
    count == 0
  }

  public mutating func append(_ samples: [Float]) {
    samples.withUnsafeBufferPointer { append($0) }
  }

  /// Adds samples, dropping the oldest ones when there is no room.
  public mutating func append(_ samples: UnsafeBufferPointer<Float>) {
    guard let base = samples.baseAddress, !samples.isEmpty else {
      return
    }
    // More than the ring holds means everything currently in it is already too
    // old to matter. Keeping the tail and nothing else is both correct and one
    // copy instead of two.
    if samples.count >= capacity {
      let offset = samples.count - capacity
      storage.withUnsafeMutableBufferPointer { destination in
        destination.baseAddress?.update(from: base + offset, count: capacity)
      }
      start = 0
      count = capacity
      return
    }

    let end = (start + count) % capacity
    let firstChunk = min(samples.count, capacity - end)
    storage.withUnsafeMutableBufferPointer { destination in
      guard let target = destination.baseAddress else {
        return
      }
      target.advanced(by: end).update(from: base, count: firstChunk)
      if firstChunk < samples.count {
        target.update(from: base + firstChunk, count: samples.count - firstChunk)
      }
    }

    let total = count + samples.count
    if total > capacity {
      // Overwritten from the front: the oldest samples are gone, and `start` has
      // to follow the write head rather than stay where it was.
      start = (start + total - capacity) % capacity
      count = capacity
    } else {
      count = total
    }
  }

  /// Copies everything held, oldest first, and empties the ring.
  ///
  /// Returns how many samples were written, which is `min(count, destination
  /// capacity)`. Emptying is not a convenience: the samples handed over are about
  /// to be given to the recogniser, and a ring that kept them would hand them
  /// over again on the next opening.
  public mutating func drain(into destination: UnsafeMutableBufferPointer<Float>) -> Int {
    guard let target = destination.baseAddress else {
      count = 0
      return 0
    }
    let wanted = min(count, destination.count)
    guard wanted > 0 else {
      count = 0
      return 0
    }
    // Only the newest `wanted` samples fit, and if something has to be dropped it
    // is the oldest — the pre-roll exists to hold what came just before the gate
    // opened.
    let from = (start + count - wanted) % capacity
    let firstChunk = min(wanted, capacity - from)
    storage.withUnsafeBufferPointer { source in
      guard let base = source.baseAddress else {
        return
      }
      target.update(from: base + from, count: firstChunk)
      if firstChunk < wanted {
        target.advanced(by: firstChunk).update(from: base, count: wanted - firstChunk)
      }
    }
    start = 0
    count = 0
    return wanted
  }

  /// Allocating drain, for tests and for nothing on the audio thread.
  public mutating func drain() -> [Float] {
    var output = [Float](repeating: 0, count: count)
    let written = output.withUnsafeMutableBufferPointer { drain(into: $0) }
    output.removeLast(output.count - written)
    return output
  }

  public mutating func removeAll() {
    start = 0
    count = 0
  }
}
