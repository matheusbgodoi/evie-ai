import AVFoundation
import EvieCore
import Foundation
import Synchronization

/// One voice Evie can be given.
struct EvieVoiceOption: Identifiable, Hashable, Sendable {
  var id: String
  var name: String
  var isEnhanced: Bool
  /// Lower sorts first. Not shown; it only decides the default and the order.
  var rank: Int = 0

  var displayName: String {
    isEnhanced ? "\(name) · natural" : name
  }
}

/// Evie speaking.
///
/// The synthesiser writes buffers rather than playing them, and those buffers are
/// played through an audio engine here. That extra step buys two things worth the
/// code: the ring around her mark can show the real amplitude of what is being
/// heard rather than a decoration pretending to be one, and swapping in a cloned
/// voice later means changing where the buffers come from and nothing else.
@MainActor
final class EvieSpeechOutput: ObservableObject {
  @Published private(set) var isSpeaking = false

  /// Called with the output level while she speaks, and with an empty array when
  /// she stops.
  var onLevels: (@MainActor ([CGFloat]) -> Void)?
  /// Called when audio actually starts, which is after the first sentence has
  /// been synthesised — not when `speak` returns.
  var onStarted: (@MainActor () -> Void)?
  var onFinished: (@MainActor () -> Void)?

  private static let historyLength = 44
  private static let publishInterval = Duration.milliseconds(40)
  private static let noiseFloorDecibels: Float = -50

  private let synthesizer = AVSpeechSynthesizer()
  private let meter = EvieLevelMeter()
  private var engine: AVAudioEngine?
  private var player: AVAudioPlayerNode?
  private var publishTask: Task<Void, Never>?
  private var speechTask: Task<Void, Never>?
  private var levels: [CGFloat] = []
  private var engineFormat: AVAudioFormat?

  /// Portuguese voices this Mac will actually let Evie use, best first.
  ///
  /// The system lists the natural Siri voices, but a third-party application
  /// cannot instantiate them — verified on this Mac, where
  /// `AVSpeechSynthesisVoice(identifier: "com.apple.siri.natural.Sandra")`
  /// returns nil inside the bundle while appearing in `speechVoices()`. They are
  /// filtered out rather than offered and then failing.
  ///
  /// What remains is ranked deliberately. Apple's own `com.apple.voice` entries
  /// are ordinary speech; the `eloquence` family are the novelty voices, which
  /// are fine to pick and wrong to default to.
  static func availableVoices(matching language: String = "pt-BR") -> [EvieVoiceOption] {
    AVSpeechSynthesisVoice.speechVoices()
      .filter { $0.language == language }
      .filter { AVSpeechSynthesisVoice(identifier: $0.identifier) != nil }
      .map { voice in
        EvieVoiceOption(
          id: voice.identifier,
          name: voice.name,
          isEnhanced: voice.quality != .default,
          rank: rank(of: voice)
        )
      }
      .sorted { left, right in
        left.rank == right.rank ? left.name < right.name : left.rank < right.rank
      }
  }

  private static func rank(of voice: AVSpeechSynthesisVoice) -> Int {
    if voice.quality != .default {
      return 0
    }
    if voice.identifier.contains(".voice.") {
      // `compact` reads better than `super-compact`, and both beat novelty.
      return voice.identifier.contains("super-compact") ? 2 : 1
    }
    return 3
  }

  static var preferredVoiceIdentifier: String? {
    availableVoices().first?.id
  }

  /// Speaks the answer, sentence by sentence.
  ///
  /// Returns as soon as speaking begins; `onFinished` reports the end. Calling it
  /// again, or `stop()`, interrupts whatever is playing — barge-in has to be
  /// immediate or it is not barge-in.
  func speak(_ text: EvieRichText, voiceIdentifier: String?, rate: Double) {
    stop()

    let sentences = text.spokenSentences
    guard !sentences.isEmpty else {
      return
    }

    let voice =
      voiceIdentifier.flatMap(AVSpeechSynthesisVoice.init(identifier:))
      ?? Self.preferredVoiceIdentifier.flatMap(AVSpeechSynthesisVoice.init(identifier:))
    guard let voice else {
      return
    }

    speechTask = Task { @MainActor [weak self] in
      for sentence in sentences {
        guard let self, !Task.isCancelled else {
          return
        }
        guard
          let buffers = await synthesise(sentence, voice: voice, rate: rate),
          let format = buffers.first(where: { $0.frameLength > 0 })?.format
        else {
          continue
        }
        guard !Task.isCancelled else {
          return
        }
        // The engine is built from the first real buffer's format. Connecting
        // before knowing it made the engine adopt the hardware's stereo layout,
        // and a mono buffer scheduled onto a stereo connection simply never
        // plays — the wait for playback never returned and the process hung.
        guard prepareEngine(for: format) else {
          break
        }
        if !isSpeaking {
          isSpeaking = true
          levels = Array(repeating: 0, count: Self.historyLength)
          startPublishing()
          onStarted?()
        }
        await play(buffers)
      }
      self?.finish()
    }
  }

  func stop() {
    speechTask?.cancel()
    speechTask = nil
    publishTask?.cancel()
    publishTask = nil

    if synthesizer.isSpeaking {
      synthesizer.stopSpeaking(at: .immediate)
    }
    teardownEngine()
    meter.reset()

    if isSpeaking {
      isSpeaking = false
      levels = []
      onLevels?([])
    }
  }
}

extension EvieSpeechOutput {
  /// Builds the engine for a specific buffer format, or reuses the running one
  /// when the format has not changed.
  fileprivate func prepareEngine(for format: AVAudioFormat) -> Bool {
    if let engine, engine.isRunning, engineFormat == format {
      return true
    }
    teardownEngine()

    let engine = AVAudioEngine()
    let player = AVAudioPlayerNode()
    engine.attach(player)
    engine.connect(player, to: engine.mainMixerNode, format: format)
    Self.installTap(on: engine.mainMixerNode, meter: meter, floor: Self.noiseFloorDecibels)

    engine.prepare()
    do {
      try engine.start()
    } catch {
      return false
    }
    player.play()

    self.engine = engine
    self.player = player
    engineFormat = format
    return true
  }

  fileprivate func teardownEngine() {
    if let engine {
      engine.mainMixerNode.removeTap(onBus: 0)
      player?.stop()
      engine.stop()
    }
    engine = nil
    player = nil
    engineFormat = nil
  }

  /// Same reason as the microphone tap: a closure written inside a `@MainActor`
  /// type inherits that isolation, and the audio thread traps on it.
  fileprivate nonisolated static func installTap(
    on node: AVAudioNode,
    meter: EvieLevelMeter,
    floor: Float
  ) {
    node.installTap(onBus: 0, bufferSize: 1_024, format: nil) { buffer, _ in
      meter.absorb(buffer, noiseFloorDecibels: floor)
    }
  }

  /// Renders one sentence to buffers.
  fileprivate func synthesise(
    _ sentence: String,
    voice: AVSpeechSynthesisVoice,
    rate: Double
  ) async -> [AVAudioPCMBuffer]? {
    let utterance = AVSpeechUtterance(string: sentence)
    utterance.voice = voice
    utterance.rate = Float(rate)

    return await withCheckedContinuation { continuation in
      let collector = BufferCollector(continuation: continuation)
      synthesizer.write(utterance) { buffer in
        collector.receive(buffer)
      }
    }
  }

  /// Plays one sentence and returns when it has actually been heard.
  ///
  /// Only the last buffer is awaited. Awaiting each one would serialise on
  /// playback and leave a gap between them; joining them first would mean
  /// assuming a sample format the compact voices do not share with the natural
  /// ones.
  fileprivate func play(_ buffers: [AVAudioPCMBuffer]) async {
    guard let player else {
      return
    }
    let usable = buffers.filter { $0.frameLength > 0 && $0.format == engineFormat }
    guard let last = usable.last else {
      return
    }

    Self.queue(usable.dropLast(), on: player)
    await player.scheduleBuffer(last, completionCallbackType: .dataPlayedBack)
  }

  /// Queues without awaiting. Kept out of the async function because calling the
  /// synchronous overload from an async context is a warning, and this build
  /// treats warnings as errors — the fire-and-forget behaviour is the point here.
  fileprivate static func queue(
    _ buffers: some Sequence<AVAudioPCMBuffer>,
    on player: AVAudioPlayerNode
  ) {
    for buffer in buffers {
      player.scheduleBuffer(buffer, at: nil, options: [], completionHandler: nil)
    }
  }

  fileprivate func finish() {
    guard isSpeaking else {
      return
    }
    stop()
    onFinished?()
  }

  fileprivate func startPublishing() {
    publishTask?.cancel()
    publishTask = Task { @MainActor [weak self] in
      while !Task.isCancelled {
        try? await Task.sleep(for: Self.publishInterval)
        guard let self, self.isSpeaking else {
          return
        }
        var updated = self.levels
        if updated.count >= Self.historyLength {
          updated.removeFirst(updated.count - Self.historyLength + 1)
        }
        updated.append(CGFloat(self.meter.currentLevel()))
        self.levels = updated
        self.onLevels?(updated)
      }
    }
  }
}

/// Gathers the synthesiser's buffers and resumes once it sends the empty one that
/// marks the end.
///
/// The callback arrives off the main actor. `AVAudioPCMBuffer` predates
/// `Sendable`, so the collection is guarded by a lock and the buffers are only
/// ever touched inside it; the continuation is resumed exactly once.
private final class BufferCollector: @unchecked Sendable {
  private let lock = NSLock()
  private var buffers: [AVAudioPCMBuffer] = []
  private var hasFinished = false
  private let continuation: CheckedContinuation<[AVAudioPCMBuffer]?, Never>

  init(continuation: CheckedContinuation<[AVAudioPCMBuffer]?, Never>) {
    self.continuation = continuation
  }

  func receive(_ buffer: AVAudioBuffer) {
    guard let pcm = buffer as? AVAudioPCMBuffer else {
      return
    }

    lock.lock()
    guard !hasFinished else {
      lock.unlock()
      return
    }
    guard pcm.frameLength > 0 else {
      hasFinished = true
      let collected = buffers
      buffers = []
      lock.unlock()
      continuation.resume(returning: collected)
      return
    }
    buffers.append(pcm)
    lock.unlock()
  }
}
