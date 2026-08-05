import CoreGraphics
import Foundation
import Testing

@testable import EvieCore

@Suite("Evie speech gate")
struct EvieSpeechGateTests {
  /// The case the fixed thresholds got right, kept so the adaptive version does
  /// not regress it.
  @Test("ordinary speech in a quiet room starts and ends a turn")
  func ordinaryRoom() {
    var gate = EvieSpeechGate()
    let events = run(
      &gate,
      silence(silentRoom, seconds: 2) + speech(ordinaryVoice, seconds: 2)
        + silence(silentRoom, seconds: 2)
    )

    #expect(events.contains(.speechStarted))
    #expect(events.contains(.speechEnded))
  }

  /// The case that made the user click the button by hand: a quiet speaker whose
  /// level never reaches the old fixed 0.16.
  @Test("a quiet speaker is still heard")
  func quietSpeaker() {
    var gate = EvieSpeechGate()
    let events = run(
      &gate,
      silence(silentRoom, seconds: 2) + speech(quietVoice, seconds: 2)
        + silence(silentRoom, seconds: 2)
    )

    #expect(events.contains(.speechStarted))
    #expect(events.contains(.speechEnded))
  }

  /// And the opposite room, where the old fixed floor would have called the fan
  /// speech and ended a turn that never started.
  @Test("a noisy room does not hear speech in its own noise")
  func noisyRoomAlone() {
    var gate = EvieSpeechGate()
    let events = run(&gate, silence(noisyRoom, seconds: 8))

    #expect(!events.contains(.speechStarted))
    #expect(!events.contains(.speechEnded))
  }

  @Test("speech over a noisy room is still heard")
  func speechOverNoise() {
    var gate = EvieSpeechGate()
    let events = run(
      &gate,
      silence(noisyRoom, seconds: 3) + speech(ordinaryVoice, seconds: 2)
        + silence(noisyRoom, seconds: 3)
    )

    #expect(events.contains(.speechStarted))
    #expect(events.contains(.speechEnded))
  }

  // MARK: - Not ending too early

  @Test("a pause for breath does not end the turn")
  func breathPause() {
    var gate = EvieSpeechGate()
    let events = run(
      &gate,
      silence(silentRoom, seconds: 2)
        + speech(ordinaryVoice, seconds: 1)
        // Shorter than the silence that ends a turn.
        + silence(silentRoom, seconds: 0.5)
        + speech(ordinaryVoice, seconds: 1)
    )

    #expect(events.filter { $0 == .speechStarted }.count == 1)
    #expect(!events.contains(.speechEnded))
  }

  @Test("silence alone never ends a turn that never started")
  func silenceAlone() {
    var gate = EvieSpeechGate()
    let events = run(&gate, silence(silentRoom, seconds: 8))

    #expect(events.isEmpty)
  }

  /// A chair, a cough, a keystroke. Ending on one submits nothing and looks
  /// broken.
  @Test("a single click is too short to be a turn")
  func briefNoiseIsNotATurn() {
    var gate = EvieSpeechGate()
    let events = run(
      &gate,
      silence(silentRoom, seconds: 2) + speech(ordinaryVoice, seconds: 0.08)
        + silence(silentRoom, seconds: 3)
    )

    #expect(!events.contains(.speechEnded))
  }

  /// A false start must not leave the gate stuck: the real sentence that follows
  /// still has to be heard and still has to end.
  @Test("a click does not block the sentence that follows it")
  func recoversFromAFalseStart() {
    var gate = EvieSpeechGate()
    let events = run(
      &gate,
      silence(silentRoom, seconds: 2)
        + speech(ordinaryVoice, seconds: 0.08)
        + silence(silentRoom, seconds: 2)
        + speech(ordinaryVoice, seconds: 1.5)
        + silence(silentRoom, seconds: 2)
    )

    #expect(events.contains(.speechEnded))
    #expect(events.filter { $0 == .speechEnded }.count == 1)
  }

  // MARK: - Behaviour of the ending

  @Test("the end is reported once, not on every silent sample after")
  func endsOnce() {
    var gate = EvieSpeechGate()
    let events = run(
      &gate,
      silence(silentRoom, seconds: 2) + speech(ordinaryVoice, seconds: 1)
        + silence(silentRoom, seconds: 10)
    )

    #expect(events.filter { $0 == .speechEnded }.count == 1)
  }

  @Test("the room is measured, not guessed")
  func learnsTheFloor() {
    var gate = EvieSpeechGate()
    _ = run(&gate, silence(noisyRoom, seconds: 3))

    #expect(gate.noiseFloor > 0.05, "não aprendeu o piso da sala: \(gate.noiseFloor)")
    #expect(gate.isListening)
  }

  /// The bug the user hit, in the shape it happened. The level meter starts at
  /// zero every time the microphone opens, so the first samples describe the
  /// meter and not the room; seeding from them put the floor at zero, made
  /// ambient noise read as speech immediately, and left the turn unable to end.
  @Test("the meter climbing out of zero is not mistaken for silence")
  func ignoresTheMeterWarmingUp() {
    var gate = EvieSpeechGate()
    // Exactly what the microphone produces: a ramp from zero up to room noise.
    let ramp: [CGFloat] = (0..<10).map { CGFloat($0) * (noisyRoom / 10) }
    let events = run(&gate, ramp + silence(noisyRoom, seconds: 8))

    #expect(gate.noiseFloor > 0.05, "piso ficou em \(gate.noiseFloor)")
    #expect(!events.contains(.speechStarted), "confundiu o ruído da sala com fala")
  }

  /// And the second half of the same bug: once the floor was wrong it could
  /// never recover, because it was only allowed to rise while not speaking.
  @Test("a floor seeded too low recovers instead of latching")
  func recoversFromABadFloor() {
    var gate = EvieSpeechGate()
    let ramp: [CGFloat] = (0..<10).map { _ in 0.0 }
    let events = run(&gate, ramp + silence(noisyRoom, seconds: 20))

    // It does briefly mistake the room for speech — with a floor of zero it can
    // do nothing else. What matters is that it recalibrates instead of latching,
    // and never ends a turn, which would have submitted nothing.
    #expect(!events.contains(.speechEnded))
    #expect(gate.noiseFloor > 0.05, "não recuperou: \(gate.noiseFloor)")
    #expect(!gate.isHearingSpeech, "ficou preso achando que é fala")
  }

  @Test("a fresh turn measures the room again")
  func resetRelearns() {
    var gate = EvieSpeechGate()
    _ = run(&gate, silence(noisyRoom, seconds: 3) + speech(ordinaryVoice, seconds: 1)
        + silence(noisyRoom, seconds: 3))
    gate.reset()

    #expect(!gate.isListening)

    let events = run(
      &gate,
      silence(noisyRoom, seconds: 2) + speech(ordinaryVoice, seconds: 1)
        + silence(noisyRoom, seconds: 3)
    )
    #expect(events.contains(.speechStarted))
    #expect(events.contains(.speechEnded))
  }

  /// Without a gap between starting and stopping, every syllable would toggle it.
  @Test("the threshold to stop is below the threshold to start")
  func hysteresis() {
    var gate = EvieSpeechGate()
    _ = run(&gate, silence(silentRoom, seconds: 2))

    #expect(gate.silenceThreshold < gate.speechThreshold)
  }

  @Test("a turn ends within about a second of the last word")
  func endsPromptly() {
    var gate = EvieSpeechGate()
    let interval = 0.04
    var samples = silence(silentRoom, seconds: 2) + speech(ordinaryVoice, seconds: 1)
    let beforeSilence = samples.count
    samples += silence(silentRoom, seconds: 3)

    var index = 0
    var endedAt: Int?
    for level in samples {
      if gate.absorb(level: level) == .speechEnded, endedAt == nil {
        endedAt = index
      }
      index += 1
    }

    let ended = try! #require(endedAt)
    let delay = Double(ended - beforeSilence) * interval
    #expect(delay > 0.5, "encerrou rápido demais: \(delay)s")
    #expect(delay < 1.5, "demorou demais para encerrar: \(delay)s")
  }
}

extension EvieSpeechGateTests {
  /// Levels as the real meter produces them.
  ///
  /// `EvieLevelMeter` maps decibels linearly from a -55 dBFS floor, so a level is
  /// `1 + dBFS / 55`. Writing the scenarios in decibels keeps them anchored to
  /// something physical: an earlier version of this suite invented "quiet speech"
  /// at 0.11, which is -49 dBFS — quieter than most rooms, and a level no speaker
  /// produces. Measured on this Mac, an ordinary room sits near 0.3 and speech
  /// reaches 0.72, which is what these numbers reproduce.
  fileprivate func level(dBFS: Double) -> CGFloat {
    CGFloat(max(0, min(1, 1 + dBFS / 55)))
  }

  /// A silent room, a room with a fan, quiet speech, ordinary speech.
  fileprivate var silentRoom: CGFloat { level(dBFS: -50) }
  fileprivate var noisyRoom: CGFloat { level(dBFS: -38) }
  fileprivate var quietVoice: CGFloat { level(dBFS: -30) }
  fileprivate var ordinaryVoice: CGFloat { level(dBFS: -20) }

  /// Levels at the 40 ms publish interval the capture actually uses.
  fileprivate func samples(_ level: CGFloat, seconds: Double) -> [CGFloat] {
    Array(repeating: level, count: max(1, Int((seconds / 0.04).rounded())))
  }

  fileprivate func silence(_ level: CGFloat, seconds: Double) -> [CGFloat] {
    // Real silence is not flat; a little jitter keeps the test honest about a
    // gate that might rely on an exactly constant floor.
    samples(level, seconds: seconds).enumerated().map { index, value in
      value + (index % 3 == 0 ? 0.004 : -0.003)
    }
  }

  /// Speech is not flat either — it has syllables, and the dips between them are
  /// what a naive gate mistakes for the end.
  fileprivate func speech(_ peak: CGFloat, seconds: Double) -> [CGFloat] {
    samples(peak, seconds: seconds).enumerated().map { index, value in
      index % 5 == 0 ? value * 0.55 : value
    }
  }

  fileprivate func run(
    _ gate: inout EvieSpeechGate,
    _ levels: [CGFloat]
  ) -> [EvieSpeechGate.Event] {
    levels.map { gate.absorb(level: $0) }.filter { $0 != .none }
  }
}
