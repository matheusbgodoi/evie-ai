import Foundation
import Testing

@testable import EvieCore

@Suite("Evie wake gate")
struct EvieWakeGateTests {
  // MARK: - The thing that must never break

  /// The failure that makes the whole optimisation worthless: by the time the
  /// level clears the threshold, "Ei" has already been said. If the pre-roll does
  /// not deliver it, the phrase never matches and Evie never comes.
  @Test("speech after a long silence is not clipped at the start")
  func speechAfterSilenceIsNotClipped() {
    var pipeline = Pipeline()
    pipeline.run(silence(seconds: 20))
    let onset = pipeline.framesProduced
    pipeline.run(speech(seconds: 2))

    let fed = pipeline.fed
    #expect(!fed.isEmpty, "não alimentou nada quando alguém falou")
    let firstFed = try! #require(pipeline.firstFedFrame(atOrAfter: onset - Pipeline.preRollFrames))
    // Everything from half a second before the first loud buffer onwards is
    // handed over, which is what the pre-roll is for.
    #expect(
      firstFed <= onset,
      "o começo da fala foi cortado: alimentou a partir do quadro \(firstFed), fala em \(onset)"
    )
    #expect(
      onset - firstFed >= Pipeline.preRollFrames - Pipeline.bufferFrames,
      "o pré-rolo entregou só \(onset - firstFed) quadros antes da fala"
    )
  }

  /// A pre-roll that repeats or skips audio is worse than none: the recogniser
  /// hears a stutter or a cut, and either can turn the phrase into something else.
  @Test("what reaches the recogniser is contiguous, with nothing repeated")
  func feedIsContiguous() {
    var pipeline = Pipeline()
    pipeline.run(silence(seconds: 5))
    pipeline.run(speech(seconds: 2))
    pipeline.run(silence(seconds: 3))
    // A second turn, close enough that the ring still holds audio the recogniser
    // was already given during the first one.
    pipeline.run(speech(seconds: 2))
    pipeline.run(silence(seconds: 2))

    for (previous, next) in zip(pipeline.fed, pipeline.fed.dropFirst()) {
      #expect(next > previous, "quadro repetido ou fora de ordem: \(previous) → \(next)")
    }
    #expect(Set(pipeline.fed).count == pipeline.fed.count, "quadros duplicados")
  }

  @Test("the pre-roll holds exactly the audio just before the gate opened")
  func preRollIsExactlyTheTail() {
    var pipeline = Pipeline()
    pipeline.run(silence(seconds: 10))
    let beforeOpening = pipeline.fed.count
    pipeline.run(speech(seconds: 1))

    let opening = try! #require(pipeline.openings.first)
    let flushed = Array(pipeline.fed[beforeOpening..<(beforeOpening + opening.preRollFrames)])
    #expect(
      opening.preRollFrames == Pipeline.preRollFrames,
      "pré-rolo com \(opening.preRollFrames) quadros, esperado \(Pipeline.preRollFrames)"
    )
    // The frames immediately before the buffer that opened the gate, in order.
    let expected = Array(
      (opening.firstFrameOfOpeningBuffer - Pipeline.preRollFrames)
        ..< opening.firstFrameOfOpeningBuffer
    ).map { Float($0) }
    #expect(flushed == expected, "o pré-rolo não é o trecho imediatamente anterior")
  }

  // MARK: - Not opening on everything

  @Test("a single loud buffer does not open the gate")
  func briefNoiseDoesNotOpen() {
    var pipeline = Pipeline()
    pipeline.run(silence(seconds: 10))
    let quiet = pipeline.fed.count
    pipeline.run([ordinaryVoice])
    pipeline.run(silence(seconds: 5))

    #expect(pipeline.fed.count == quiet, "um estalo sozinho abriu o portão")
  }

  @Test("an ordinary room on its own is never handed to the recogniser")
  func silenceCostsNothing() {
    var pipeline = Pipeline()
    pipeline.run(silence(seconds: 60))

    // Only the settle window and the hangover after it, which is a bounded
    // one-off per recogniser cycle rather than a fraction of the minute.
    let fedSeconds = Double(pipeline.fed.count) / Pipeline.sampleRate
    #expect(fedSeconds < 2, "entregou \(fedSeconds)s de sala silenciosa ao reconhecedor")
  }

  /// The room is not the same room everywhere. A gate with a fixed threshold
  /// either never opens in a noisy kitchen or never closes near a fan.
  @Test("a noisy room raises the threshold instead of opening the gate")
  func noisyRoomDoesNotOpen() {
    var pipeline = Pipeline()
    pipeline.run(noise(noisyRoom, seconds: 30))
    let fedSeconds = Double(pipeline.fed.count) / Pipeline.sampleRate

    #expect(fedSeconds < 2, "a sala barulhenta sozinha abriu o portão por \(fedSeconds)s")
    #expect(pipeline.gate.noiseFloor > 0.2, "não aprendeu o piso: \(pipeline.gate.noiseFloor)")
  }

  @Test("a quiet speaker in a quiet room still opens the gate")
  func quietSpeakerOpens() {
    var pipeline = Pipeline()
    pipeline.run(silence(seconds: 10))
    let quiet = pipeline.fed.count
    pipeline.run(speech(quietVoice, seconds: 2))

    #expect(pipeline.fed.count > quiet, "não abriu para uma voz baixa")
  }

  /// Nothing is gated while the room is still being measured, because a gate that
  /// guesses at that moment can eat a phrase said the instant she is armed.
  @Test("the first half second is fed unconditionally")
  func settleFeedsEverything() {
    var pipeline = Pipeline()
    pipeline.run(silence(seconds: 0.4))

    #expect(pipeline.fed.count == pipeline.framesProduced, "cortou durante o assentamento")
  }

  /// The gap between two words is not the end of a sentence, and closing on it
  /// would splice the phrase in half.
  @Test("a gap between words does not close the gate")
  func gapBetweenWordsKeepsFeeding() {
    var pipeline = Pipeline()
    pipeline.run(silence(seconds: 10))
    pipeline.run(speech(seconds: 0.5))
    let fedBeforeGap = pipeline.fed.count
    let producedBeforeGap = pipeline.framesProduced
    pipeline.run(silence(seconds: 0.2))
    pipeline.run(speech(seconds: 0.5))

    #expect(pipeline.openings.count == 1, "reabriu no meio da frase: \(pipeline.openings.count)")
    // Nothing was withheld across the gap either — the recogniser gets the pause
    // as a pause, not as a splice.
    #expect(
      pipeline.fed.count - fedBeforeGap == pipeline.framesProduced - producedBeforeGap,
      "o silêncio entre as palavras não chegou inteiro ao reconhecedor"
    )
  }

  /// The bug that made the first measured version report "portão aberto em 200 de
  /// 200 buffers": the tap was asked for 1024 frames and handed over 4800, so
  /// every duration expressed in buffers was almost five times too long and the
  /// gate never closed. Nothing here may depend on the buffer size.
  @Test("the buffer size the device chooses does not change the behaviour")
  func independentOfBufferSize() {
    let large = 4_800
    var pipeline = Pipeline(bufferFrames: large)
    pipeline.run(silence(seconds: 30, bufferFrames: large))
    let quietFrames = pipeline.fed.count
    pipeline.run(speech(seconds: 2, bufferFrames: large))

    #expect(
      Double(quietFrames) / Pipeline.sampleRate < 2,
      "não fechou o portão com buffers de 100 ms"
    )
    #expect(pipeline.openings.count == 1, "não abriu para a fala com buffers de 100 ms")
  }

  @Test("the threshold to close is below the threshold to open")
  func hysteresis() {
    var pipeline = Pipeline()
    pipeline.run(silence(seconds: 5))

    #expect(pipeline.gate.closeThreshold < pipeline.gate.openThreshold)
  }

  @Test("a new recogniser cycle measures the room again")
  func resetRelearns() {
    var pipeline = Pipeline()
    pipeline.run(noise(noisyRoom, seconds: 10))
    #expect(pipeline.gate.noiseFloor > 0.2)

    pipeline.gate.reset()
    #expect(pipeline.gate.noiseFloor == 0)
  }
}

// MARK: - The ring on its own

@Suite("Evie audio ring")
struct EvieAudioRingTests {
  @Test("it keeps the newest audio when it runs out of room")
  func wraps() {
    var ring = EvieAudioRing(capacity: 8)
    ring.append((0..<5).map(Float.init))
    ring.append((5..<12).map(Float.init))

    #expect(ring.count == 8)
    #expect(ring.drain() == (4..<12).map(Float.init))
  }

  @Test("a write that straddles the end of the storage comes back in order")
  func wrapsAcrossTheBoundary() {
    var ring = EvieAudioRing(capacity: 8)
    ring.append((0..<6).map(Float.init))
    _ = ring.drain()
    // The write head is now at 6, so this one wraps around the end.
    ring.append((100..<105).map(Float.init))

    #expect(ring.drain() == (100..<105).map(Float.init))
  }

  @Test("more audio than it holds keeps only the tail")
  func longerThanCapacity() {
    var ring = EvieAudioRing(capacity: 4)
    ring.append((0..<100).map(Float.init))

    #expect(ring.drain() == (96..<100).map(Float.init))
  }

  @Test("draining empties it, so nothing is handed over twice")
  func drainEmpties() {
    var ring = EvieAudioRing(capacity: 8)
    ring.append((0..<8).map(Float.init))

    #expect(ring.drain().count == 8)
    #expect(ring.isEmpty)
    #expect(ring.drain().isEmpty)
  }

  @Test("a destination smaller than the ring gets the newest audio, not the oldest")
  func partialDrain() {
    var ring = EvieAudioRing(capacity: 8)
    ring.append((0..<8).map(Float.init))

    var destination = [Float](repeating: 0, count: 3)
    let written = destination.withUnsafeMutableBufferPointer { ring.drain(into: $0) }

    #expect(written == 3)
    #expect(destination == [5, 6, 7])
    #expect(ring.isEmpty)
  }

  @Test("removeAll forgets everything")
  func removesAll() {
    var ring = EvieAudioRing(capacity: 8)
    ring.append((0..<8).map(Float.init))
    ring.removeAll()

    #expect(ring.isEmpty)
    #expect(ring.drain().isEmpty)
  }
}

// MARK: - Harness

extension EvieWakeGateTests {
  /// The whole path, without a microphone: buffers of numbered frames, a gate
  /// deciding on each one, a ring holding what the gate refused, and a record of
  /// exactly which frames the recogniser would have received in which order.
  ///
  /// The frames are numbered because that is what makes a duplicated or dropped
  /// frame visible at all — a test that only counted them would pass on audio the
  /// recogniser hears as a stutter.
  struct Pipeline {
    static let sampleRate = 48_000.0
    /// What the tap is asked for.
    static let bufferFrames = 1_024
    static let preRollFrames = Int(0.5 * sampleRate)

    /// What the tap actually hands over is not always what it was asked for, so
    /// scenarios can be replayed at another buffer size.
    let bufferFrames: Int
    var bufferDuration: Duration {
      .nanoseconds(Int(Double(bufferFrames) / Self.sampleRate * 1e9))
    }

    var gate = EvieWakeGate()
    var ring = EvieAudioRing(capacity: preRollFrames)
    /// Every frame handed to the recogniser, in the order it was handed over.
    var fed: [Float] = []
    var framesProduced = 0
    var openings: [Opening] = []

    struct Opening {
      var preRollFrames: Int
      var firstFrameOfOpeningBuffer: Int
    }

    init(bufferFrames: Int = Pipeline.bufferFrames) {
      self.bufferFrames = bufferFrames
    }

    /// Feeds one buffer per level, exactly as `EvieWakeAudioSink` does.
    mutating func run(_ levels: [Float]) {
      for level in levels {
        let first = framesProduced
        let frames = (first..<(first + bufferFrames)).map(Float.init)
        framesProduced += bufferFrames

        switch gate.absorb(level: level, duration: bufferDuration) {
        case .discard:
          ring.append(frames)
        case .openWithPreRoll:
          let preRoll = ring.drain()
          openings.append(
            Opening(preRollFrames: preRoll.count, firstFrameOfOpeningBuffer: first)
          )
          fed += preRoll
          fed += frames
        case .feed:
          fed += frames
        }
      }
    }

    func firstFedFrame(atOrAfter frame: Int) -> Int? {
      fed.first { $0 >= Float(frame) }.map { Int($0) }
    }
  }

  /// Levels as the real path produces them: RMS in decibels mapped from a
  /// −55 dBFS floor, which is what `EvieLevelMeter` and `EvieWakeAudioSink` both
  /// do. Writing the scenarios in decibels keeps them anchored to something
  /// physical rather than to a number that happens to pass.
  fileprivate func level(dBFS: Double) -> Float {
    Float(max(0, min(1, 1 + dBFS / 55)))
  }

  fileprivate var silentRoom: Float { level(dBFS: -50) }
  fileprivate var noisyRoom: Float { level(dBFS: -38) }
  fileprivate var quietVoice: Float { level(dBFS: -30) }
  fileprivate var ordinaryVoice: Float { level(dBFS: -20) }

  /// One level per audio buffer, which is every 21.3 ms at 48 kHz — or every
  /// 100 ms, which is what this Mac actually delivers.
  fileprivate func buffers(
    _ level: Float,
    seconds: Double,
    bufferFrames: Int = Pipeline.bufferFrames
  ) -> [Float] {
    Array(
      repeating: level,
      count: max(1, Int((seconds * Pipeline.sampleRate / Double(bufferFrames)).rounded()))
    )
  }

  fileprivate func noise(
    _ level: Float,
    seconds: Double,
    bufferFrames: Int = Pipeline.bufferFrames
  ) -> [Float] {
    // Never flat: a gate that relied on an exactly constant floor would pass a
    // test made of constants and fail in a room.
    buffers(level, seconds: seconds, bufferFrames: bufferFrames).enumerated().map { index, value in
      value + (index % 3 == 0 ? 0.006 : -0.004)
    }
  }

  fileprivate func silence(seconds: Double, bufferFrames: Int = Pipeline.bufferFrames) -> [Float] {
    noise(silentRoom, seconds: seconds, bufferFrames: bufferFrames)
  }

  fileprivate func speech(
    _ peak: Float? = nil,
    seconds: Double,
    bufferFrames: Int = Pipeline.bufferFrames
  ) -> [Float] {
    // Speech has syllables, and the dips between them are what a naive gate
    // mistakes for the end of it.
    buffers(peak ?? ordinaryVoice, seconds: seconds, bufferFrames: bufferFrames)
      .enumerated().map { index, value in
        index % 5 == 0 ? value * 0.6 : value
      }
  }
}
