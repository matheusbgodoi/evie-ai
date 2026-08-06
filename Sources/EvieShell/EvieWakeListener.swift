import AVFoundation
import Accelerate
import EvieCore
import Foundation
import Synchronization

/// Sits between the microphone and the recogniser, and only lets audio through
/// while somebody is talking.
///
/// The decision and the pre-roll both live in `EvieWakeGate` and `EvieAudioRing`,
/// where they can be tested without a microphone. What is here is the part that
/// cannot be: reading the level off a real buffer, and turning the pre-roll back
/// into a buffer the recogniser's converter will accept.
///
/// Everything runs on the real-time audio thread. Nothing here allocates — the
/// pre-roll buffer and the rings are built once, at arming — and nothing here
/// hops actors, for the reason `EvieAudioBufferSink` documents in
/// EvieAudioCapture.swift.
@available(macOS 26, *)
final class EvieWakeAudioSink: EvieAudioBufferSink, @unchecked Sendable {
  /// What the gate did, so the cost of arming can be reported as a measurement
  /// rather than a claim.
  struct Statistics: Sendable {
    var buffers = 0
    var fed = 0
    var openings = 0
    var floor: Float = 0
    var peakLevel: Float = 0
    var openThreshold: Float = 0
    var bufferSeconds: Double = 0
    /// Every level seen, up to a bound. The thresholds in `EvieWakeGate` are
    /// supposed to be measured rather than chosen, and this is what they were
    /// measured from.
    var levels: [Float] = []
  }

  /// Enough for several minutes of levels at the rate the tap really delivers,
  /// and small enough to be irrelevant next to the audio buffers themselves.
  private static let tracedLevels = 4_096

  private struct State {
    var gate: EvieWakeGate
    /// One ring per channel, so the pre-roll never has to interleave.
    var rings: [EvieAudioRing]
    var statistics = Statistics()
  }

  private let state: Mutex<State>
  private let pump: AnalyzerInputPump
  /// Allocated once and reused. Building a buffer at the moment speech starts is
  /// an allocation on the audio thread, which is the one place it must not
  /// happen.
  private let preRollBuffer: AVAudioPCMBuffer
  private let channelCount: Int
  private let noiseFloorDecibels: Float
  private let sampleRate: Double

  /// How much audio is kept from before the gate opens.
  ///
  /// Half a second covers the onset confirmation, the time the level takes to
  /// climb past the threshold, and the syllable that was already in the air when
  /// it did. "Ei, Evie" lasts about a second, so losing its start loses the
  /// phrase.
  static let preRoll: Duration = .milliseconds(500)

  init?(format: AVAudioFormat, pump: AnalyzerInputPump, noiseFloorDecibels: Float) {
    let channels = Int(format.channelCount)
    let preRollFrames = AVAudioFrameCount(Self.seconds(Self.preRoll) * format.sampleRate)
    guard channels > 0, preRollFrames > 0, format.commonFormat == .pcmFormatFloat32,
      let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: preRollFrames)
    else {
      // A format without float channel data cannot be metered or copied here, and
      // guessing at it would be worse than not gating: the caller falls back to
      // feeding the recogniser everything, which is what it did before this
      // existed.
      return nil
    }

    self.pump = pump
    preRollBuffer = buffer
    channelCount = channels
    self.noiseFloorDecibels = noiseFloorDecibels
    sampleRate = format.sampleRate
    var initial = State(
      gate: EvieWakeGate(),
      rings: (0..<channels).map { _ in EvieAudioRing(capacity: Int(preRollFrames)) }
    )
    // Reserved here so appending a level on the audio thread never allocates.
    initial.statistics.levels.reserveCapacity(Self.tracedLevels)
    state = Mutex(initial)
  }

  func receive(_ buffer: AVAudioPCMBuffer) {
    guard let channels = buffer.floatChannelData, buffer.frameLength > 0,
      Int(buffer.format.channelCount) == channelCount
    else {
      return
    }
    let frames = Int(buffer.frameLength)
    let level = Self.level(of: channels[0], frames: frames, noiseFloor: noiseFloorDecibels)
    // Taken from the buffer rather than from the size the tap was asked for. This
    // Mac hands over 4800 frames when 1024 were requested, and a gate that
    // believed the request had a hangover almost five times longer than it meant.
    let duration = Duration.nanoseconds(Int(Double(frames) / sampleRate * 1e9))

    let decision = state.withLock { state -> EvieWakeGate.Decision in
      let decision = state.gate.absorb(level: level, duration: duration)
      state.statistics.buffers += 1
      state.statistics.bufferSeconds = Double(frames) / self.sampleRate
      state.statistics.peakLevel = max(state.statistics.peakLevel, level)
      state.statistics.floor = state.gate.noiseFloor
      state.statistics.openThreshold = state.gate.openThreshold
      if state.statistics.levels.count < Self.tracedLevels {
        state.statistics.levels.append(level)
      }

      switch decision {
      case .discard:
        // Kept, not thrown away: this is the audio that will turn out to have
        // been the beginning of the phrase.
        for channel in 0..<self.channelCount {
          state.rings[channel].append(UnsafeBufferPointer(start: channels[channel], count: frames))
        }
      case .openWithPreRoll:
        state.statistics.openings += 1
        state.statistics.fed += 1
        self.flushPreRoll(from: &state)
      case .feed:
        state.statistics.fed += 1
      }
      return decision
    }

    guard decision != .discard else {
      return
    }
    pump.receive(buffer)
  }

  /// Hands the recogniser everything the rings held, in one buffer, before the
  /// live audio that follows it.
  ///
  /// Called with the lock held and only from the audio thread, which is what
  /// makes reusing a single buffer safe: there is never a second flush in
  /// flight.
  private func flushPreRoll(from state: inout State) {
    var written = 0
    for channel in 0..<channelCount {
      guard let destination = preRollBuffer.floatChannelData?[channel] else {
        return
      }
      written = state.rings[channel].drain(
        into: UnsafeMutableBufferPointer(
          start: destination, count: Int(preRollBuffer.frameCapacity)
        )
      )
    }
    guard written > 0 else {
      return
    }
    preRollBuffer.frameLength = AVAudioFrameCount(written)
    pump.receive(preRollBuffer)
  }

  func statistics() -> Statistics {
    state.withLock { $0.statistics }
  }

  /// The same normalised level `EvieLevelMeter` publishes, but per buffer and
  /// without the attack/release smoothing.
  ///
  /// Smoothing is right for a waveform and wrong here: its release deliberately
  /// lags, and a gate that opened late would clip exactly the syllable the
  /// pre-roll exists to save.
  private static func level(
    of channel: UnsafePointer<Float>,
    frames: Int,
    noiseFloor: Float
  ) -> Float {
    var meanSquare: Float = 0
    vDSP_measqv(channel, 1, &meanSquare, vDSP_Length(frames))
    let decibels = 20 * log10(max(sqrt(meanSquare), 1e-7))
    return max(0, min(1, (decibels - noiseFloor) / -noiseFloor))
  }

  private static func seconds(_ duration: Duration) -> Double {
    Double(duration.components.seconds) + Double(duration.components.attoseconds) / 1e18
  }
}

/// Listens for the phrase that wakes her, and for nothing else.
///
/// What it deliberately does not do is as much of the design as what it does.
/// While armed there is no waveform, no "ouvindo", no visible microphone
/// anywhere in the overlay — she looks exactly as idle as she looks when she is
/// idle. Nothing heard is written to disk, sent anywhere, or kept beyond a short
/// rolling tail that exists only to be compared against the phrase and is thrown
/// away on every restart.
///
/// **One thing cannot be hidden, and pretending otherwise would be the dishonest
/// kind of interface this project refuses:** macOS shows the orange microphone
/// dot in the menu bar whenever *any* application has the microphone open, and
/// there is no exemption a third-party app can claim. Siri escapes it because
/// "Hey Siri" runs on the always-on processor built into Apple Silicon, which is
/// reachable only by Apple's own system service. So while Evie is armed, the dot
/// is on. That is the true statement, and the settings pane says it.
///
/// The recogniser is restarted on a cycle. Left running it accumulates a
/// transcript for as long as it lives, which is both a growing allocation and a
/// growing pile of speech held for no reason. Restarting bounds both. The cost is
/// that a phrase spoken exactly across a restart is missed; at one restart a
/// minute against a phrase lasting about a second, that is rare enough to say out
/// loud rather than engineer around.
@MainActor
final class EvieWakeListener: ObservableObject {
  /// True while the microphone is open waiting for the phrase.
  @Published private(set) var isArmed = false
  /// The last thing the recogniser produced, kept only so the settings pane can
  /// show what it actually heard.
  ///
  /// That display is the whole reason tuning a wake phrase is possible at all:
  /// "Evie" is not a Portuguese word, and guessing which real words the
  /// recogniser will build out of it is not something anybody should have to do
  /// from the outside.
  @Published private(set) var lastHeard = ""
  @Published private(set) var failure: String?

  /// Fired once, after disarming, when the phrase was heard.
  var onWake: (@MainActor () -> Void)?

  /// How long a recogniser lives before being replaced.
  static let recycleInterval: Duration = .seconds(60)
  /// How much of the transcript is kept for comparison.
  ///
  /// Only the tail can match — a wake phrase is what you just said — so holding
  /// more is holding speech for no purpose.
  static let retainedCharacters = 80

  /// Whether the recogniser is fed only while somebody is talking.
  ///
  /// On for every real arming. It exists as a switch so `--wake-cost-check` can
  /// measure the same code with and without the gate, in the same room, minutes
  /// apart — which is the only way the saving is a measurement instead of a
  /// story.
  var gatesRecogniser = true

  private var capture: EvieAudioCapture?
  /// Held for the diagnostic, which reports how much of the armed time the gate
  /// actually spent open.
  private var sink: AnyObject?
  /// Held as `AnyObject` because the concrete type is `@available(macOS 26, *)`
  /// and a stored property cannot carry that. The same shape `AppCoordinator`
  /// already uses for the recogniser it owns.
  private var recogniser: AnyObject?
  private var recycleTask: Task<Void, Never>?
  private var phrases = ""

  var isSupported: Bool {
    if #available(macOS 26, *) {
      return EvieSpeechTranscription.isSupported
    }
    return false
  }

  /// Opens the microphone and starts watching for the phrase.
  ///
  /// Safe to call when already armed with the same phrases; re-arming with
  /// different ones restarts cleanly rather than running two recognisers.
  func arm(phrases configured: String) async {
    guard !EvieWakePhrase.phrases(in: configured).isEmpty else {
      failure =
        "A frase precisa de pelo menos \(EvieWakePhrase.minimumPhraseCharacters) letras."
      return
    }
    if isArmed, configured == phrases {
      return
    }
    disarm()
    phrases = configured

    guard #available(macOS 26, *), EvieSpeechTranscription.isSupported else {
      failure = "Este Mac não faz reconhecimento de fala para pt-BR."
      return
    }

    do {
      try await startCycle()
      isArmed = true
      failure = nil
      recycleTask = Task { @MainActor [weak self] in
        while !Task.isCancelled {
          try? await Task.sleep(for: Self.recycleInterval)
          guard !Task.isCancelled, let self, isArmed else {
            return
          }
          // Replaced rather than reset: the transcript, its allocation, and
          // everything heard so far all go with it.
          try? await restartCycle()
        }
      }
    } catch {
      disarm()
      failure = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
    }
  }

  /// Closes the microphone and forgets everything heard.
  ///
  /// The microphone is released synchronously, before anything is awaited: the
  /// only caller that matters is about to open it for a real turn, and handing it
  /// over a task hop later means two owners for that gap.
  func disarm() {
    recycleTask?.cancel()
    recycleTask = nil
    capture?.stop()
    capture = nil
    sink = nil
    isArmed = false
    lastHeard = ""

    guard #available(macOS 26, *), let recogniser = recogniser as? EvieSpeechTranscription
    else {
      self.recogniser = nil
      return
    }
    self.recogniser = nil
    Task { await recogniser.cancel() }
  }

  @available(macOS 26, *)
  private func startCycle() async throws {
    let capture = EvieAudioCapture()
    let format = try await capture.prepareInputFormat()
    let recogniser = EvieSpeechTranscription()
    let pump = try await recogniser.start(inputFormat: format)

    recogniser.onTranscriptChanged = { [weak self] settled, volatile in
      self?.consider(settled: settled, volatile: volatile)
    }

    // The gate goes between the microphone and the recogniser, not around the
    // microphone: the tap stays open and keeps costing what it costs, and what
    // stops during silence is the expensive half. If the format is one the gate
    // cannot meter, the recogniser is fed everything, exactly as before.
    let gate =
      gatesRecogniser
      ? EvieWakeAudioSink(
        format: format,
        pump: pump,
        noiseFloorDecibels: EvieAudioCapture.noiseFloorDecibels
      )
      : nil
    sink = gate

    // No `onLevels`, and that omission is the feature. Nothing about the
    // overlay may suggest she is listening, because from the person's point of
    // view she is not — she is waiting to be called.
    try await capture.start(sink: gate ?? pump)

    self.capture = capture
    self.recogniser = recogniser
  }

  /// What the gate did while armed, for `--wake-cost-check`. Nil when the
  /// recogniser is being fed everything.
  @available(macOS 26, *)
  var gateStatistics: EvieWakeAudioSink.Statistics? {
    (sink as? EvieWakeAudioSink)?.statistics()
  }

  @available(macOS 26, *)
  private func restartCycle() async throws {
    capture?.stop()
    capture = nil
    sink = nil
    if let previous = recogniser as? EvieSpeechTranscription {
      await previous.cancel()
    }
    recogniser = nil
    lastHeard = ""
    try await startCycle()
  }

  /// Compares what was heard against the phrase, and keeps nothing else.
  private func consider(settled: String, volatile: String) {
    let heard = (settled + " " + volatile).trimmingCharacters(in: .whitespacesAndNewlines)
    // Only the tail is kept. Everything before it has already failed to match
    // and can never match again, so holding it would be retaining speech for no
    // reason at all.
    lastHeard = String(heard.suffix(Self.retainedCharacters))

    guard EvieWakePhrase.matches(lastHeard, phrases: phrases) else {
      return
    }
    // Disarmed *before* the callback, so the microphone Evie is about to open
    // for the real turn is not the second one open at the time.
    disarm()
    onWake?()
  }
}
