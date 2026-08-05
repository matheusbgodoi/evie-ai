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
      silence(0.04, seconds: 1) + speech(0.45, seconds: 2) + silence(0.04, seconds: 2)
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
      silence(0.012, seconds: 1) + speech(0.11, seconds: 2) + silence(0.012, seconds: 2)
    )

    #expect(events.contains(.speechStarted))
    #expect(events.contains(.speechEnded))
  }

  /// And the opposite room, where the old fixed floor would have called the fan
  /// speech and ended a turn that never started.
  @Test("a noisy room does not hear speech in its own noise")
  func noisyRoomAlone() {
    var gate = EvieSpeechGate()
    let events = run(&gate, silence(0.14, seconds: 6))

    #expect(!events.contains(.speechStarted))
    #expect(!events.contains(.speechEnded))
  }

  @Test("speech over a noisy room is still heard")
  func speechOverNoise() {
    var gate = EvieSpeechGate()
    let events = run(
      &gate,
      silence(0.14, seconds: 2) + speech(0.52, seconds: 2) + silence(0.14, seconds: 2)
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
      silence(0.03, seconds: 1)
        + speech(0.40, seconds: 1)
        // Shorter than the silence that ends a turn.
        + silence(0.03, seconds: 0.5)
        + speech(0.40, seconds: 1)
    )

    #expect(events.filter { $0 == .speechStarted }.count == 1)
    #expect(!events.contains(.speechEnded))
  }

  @Test("silence alone never ends a turn that never started")
  func silenceAlone() {
    var gate = EvieSpeechGate()
    let events = run(&gate, silence(0.02, seconds: 8))

    #expect(events.isEmpty)
  }

  /// A chair, a cough, a keystroke. Ending on one submits nothing and looks
  /// broken.
  @Test("a single click is too short to be a turn")
  func briefNoiseIsNotATurn() {
    var gate = EvieSpeechGate()
    let events = run(
      &gate,
      silence(0.03, seconds: 1) + speech(0.6, seconds: 0.08) + silence(0.03, seconds: 3)
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
      silence(0.03, seconds: 1)
        + speech(0.6, seconds: 0.08)
        + silence(0.03, seconds: 2)
        + speech(0.4, seconds: 1.5)
        + silence(0.03, seconds: 2)
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
      silence(0.03, seconds: 1) + speech(0.4, seconds: 1) + silence(0.03, seconds: 10)
    )

    #expect(events.filter { $0 == .speechEnded }.count == 1)
  }

  @Test("resetting allows the next turn without relearning the room")
  func resetKeepsTheFloor() {
    var gate = EvieSpeechGate()
    _ = run(&gate, silence(0.13, seconds: 3) + speech(0.5, seconds: 1) + silence(0.13, seconds: 2))
    let learned = gate.noiseFloor
    gate.reset()

    #expect(learned > 0.05, "não aprendeu o piso da sala: \(learned)")

    let events = run(&gate, speech(0.5, seconds: 1) + silence(0.13, seconds: 2))
    #expect(events.contains(.speechStarted))
    #expect(events.contains(.speechEnded))
  }

  /// Without a gap between starting and stopping, every syllable would toggle it.
  @Test("the threshold to stop is below the threshold to start")
  func hysteresis() {
    var gate = EvieSpeechGate()
    _ = run(&gate, silence(0.05, seconds: 2))

    #expect(gate.silenceThreshold < gate.speechThreshold)
  }

  @Test("a turn ends within about a second of the last word")
  func endsPromptly() {
    var gate = EvieSpeechGate()
    let interval = 0.04
    var samples = silence(0.03, seconds: 1) + speech(0.4, seconds: 1)
    let beforeSilence = samples.count
    samples += silence(0.03, seconds: 3)

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
