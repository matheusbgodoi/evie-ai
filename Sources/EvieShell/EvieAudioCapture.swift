import AVFoundation
import Accelerate
import EvieCore
import Foundation
import Synchronization

/// Receives microphone buffers on the audio thread.
///
/// This is a protocol rather than a closure on purpose. A closure written inside
/// a `@MainActor` type inherits that isolation even when its type says
/// `@Sendable`, and calling it from the real-time audio thread makes Swift assert
/// the executor and kill the process. A method on a plain `Sendable` class has no
/// isolation to inherit.
protocol EvieAudioBufferSink: Sendable {
  /// Called on the audio thread. Must not block, allocate unboundedly, or hop to
  /// another executor.
  func receive(_ buffer: AVAudioPCMBuffer)
}

/// Owns the microphone.
///
/// The order of operations here is not stylistic. Measured on this Mac, touching
/// `AVAudioEngine().inputNode` before the microphone has been granted does not
/// fail — it hangs the main thread inside `coreaudiod` forever, waiting on a
/// consent decision that can never arrive. So the permission is checked and
/// requested first, the engine is only built afterwards, and the input node is
/// only reached once access is actually granted.
@MainActor
final class EvieAudioCapture: ObservableObject {
  /// Recent input levels, newest last, each already normalised to 0...1.
  @Published private(set) var levels: [CGFloat] = []
  @Published private(set) var isCapturing = false
  @Published private(set) var permission: Permission

  /// Called on every published level update, so the overlay does not need a
  /// Combine subscription just to draw a ring.
  var onLevels: (@MainActor ([CGFloat]) -> Void)?
  /// Reports that the person stopped talking, once. Only fires when
  /// `detectsEndOfSpeech` is on, and only after speech was actually heard.
  var onEndOfSpeech: (@MainActor () -> Void)?

  /// Reports that speech was detected, so the interface can say it is hearing
  /// something rather than only drawing a level.
  var onSpeechStarted: (@MainActor () -> Void)?

  /// Turns on silence detection, which is what ends a turn without anyone
  /// pressing anything. On for every spoken turn, not only calls: having to
  /// click a button to say "I finished talking" is the thing that made speaking
  /// to Evie worse than typing.
  var detectsEndOfSpeech = true

  /// The level above which the gate currently considers someone to be talking.
  /// Published so the waveform can show the same threshold the decision uses
  /// instead of a second guess at it.
  var speechThreshold: CGFloat { gate.speechThreshold }
  var noiseFloor: CGFloat { gate.noiseFloor }

  /// How many level samples the ring and the waveform draw.
  private static let historyLength = 44
  /// Levels are published at a bounded rate rather than per audio buffer.
  /// Roughly thirty frames a second. Forty milliseconds was visibly steppy on
  /// the trace, and going below thirty buys smoothness the eye cannot see at the
  /// cost of waking the main actor more often while the microphone is open.
  static let publishInterval = Duration.milliseconds(30)
  /// Below this the microphone is treated as silent.
  private static let noiseFloorDecibels: Float = -55

  private let meter = EvieLevelMeter()
  private var engine: AVAudioEngine?
  private var publishTask: Task<Void, Never>?
  /// Decides when a turn started and ended, from the room's own noise floor
  /// rather than from constants measured once in one room. Kept across turns so
  /// the floor it learned is not thrown away between questions.
  private var gate = EvieSpeechGate(sampleInterval: EvieAudioCapture.publishInterval)

  init(permission: Permission = EvieAudioCapture.currentPermission()) {
    self.permission = permission
  }

  enum Permission: Equatable, Sendable {
    case notDetermined
    case granted
    case denied
    case restricted

    var allowsCapture: Bool {
      self == .granted
    }
  }

  enum CaptureError: LocalizedError, Equatable {
    case permissionDenied
    case notBundled
    case engineFailed(String)

    var errorDescription: String? {
      switch self {
      case .permissionDenied:
        "O microfone está bloqueado. Libere a Evie em Ajustes do Sistema › "
          + "Privacidade e Segurança › Microfone."
      case .notBundled:
        "Esta cópia da Evie não está empacotada como aplicativo, então o macOS não "
          + "tem como conceder o microfone. Rode Scripts/evie-app build e abra pelo Evie.app."
      case .engineFailed(let reason):
        "Não consegui abrir o microfone: \(reason)"
      }
    }
  }

  static func currentPermission() -> Permission {
    // This call never blocks and works even without a bundle, which is what makes
    // it safe as the very first thing done.
    switch AVCaptureDevice.authorizationStatus(for: .audio) {
    case .authorized: .granted
    case .denied: .denied
    case .restricted: .restricted
    case .notDetermined: .notDetermined
    @unknown default: .denied
    }
  }

  /// True when this process has a bundle identity. Without one the consent dialog
  /// has no application to name and no usage description to show.
  static var isBundled: Bool {
    Bundle.main.bundleIdentifier != nil
  }

  /// Asks for the microphone if it has not been decided yet.
  func requestPermission() async -> Permission {
    permission = Self.currentPermission()
    guard permission == .notDetermined else {
      return permission
    }
    guard Self.isBundled else {
      return permission
    }

    let granted = await AVCaptureDevice.requestAccess(for: .audio)
    permission = granted ? .granted : .denied
    return permission
  }

  /// Obtains consent and reports the format the microphone will produce, without
  /// opening it yet.
  ///
  /// Split from `start` because the transcriber has to be configured for this
  /// exact format before the first buffer arrives, and the format is only knowable
  /// once permission exists.
  func prepareInputFormat() async throws -> AVAudioFormat {
    guard Self.isBundled else {
      throw CaptureError.notBundled
    }
    let resolved = await requestPermission()
    guard resolved.allowsCapture else {
      throw CaptureError.permissionDenied
    }

    let engine = self.engine ?? AVAudioEngine()
    self.engine = engine
    let format = engine.inputNode.outputFormat(forBus: 0)
    guard format.sampleRate > 0, format.channelCount > 0 else {
      self.engine = nil
      throw CaptureError.engineFailed("nenhum dispositivo de entrada disponível")
    }
    return format
  }

  /// Opens the microphone. `sink` receives every buffer as it arrives, on the
  /// audio thread.
  func start(sink: (any EvieAudioBufferSink)? = nil) async throws {
    guard !isCapturing else {
      return
    }

    let format = try await prepareInputFormat()
    guard let engine else {
      throw CaptureError.engineFailed("motor de áudio indisponível")
    }
    let input = engine.inputNode

    let meter = meter
    let floor = Self.noiseFloorDecibels
    Self.installTap(on: input, format: format, meter: meter, floor: floor, sink: sink)

    do {
      engine.prepare()
      try engine.start()
    } catch {
      input.removeTap(onBus: 0)
      self.engine = nil
      throw CaptureError.engineFailed(error.localizedDescription)
    }

    isCapturing = true
    levels = Array(repeating: 0, count: Self.historyLength)
    gate.reset()
    startPublishing()
  }

  /// Installs the audio tap from a nonisolated context.
  ///
  /// This is not stylistic. A closure literal written inside a `@MainActor`
  /// method is itself main-actor isolated, whatever it captures and whatever its
  /// type says — and the audio tap invokes it on a real-time thread, where Swift
  /// checks the executor and traps. That crash was reproduced twice from the
  /// crash report before the closure was moved here, where it has no isolation to
  /// inherit.
  ///
  /// Nothing this closure touches may be actor-isolated.
  private nonisolated static func installTap(
    on input: AVAudioInputNode,
    format: AVAudioFormat,
    meter: EvieLevelMeter,
    floor: Float,
    sink: (any EvieAudioBufferSink)?
  ) {
    input.installTap(onBus: 0, bufferSize: 1_024, format: format) { buffer, _ in
      meter.absorb(buffer, noiseFloorDecibels: floor)
      sink?.receive(buffer)
    }
  }

  /// Stops the engine itself rather than merely ignoring buffers.
  ///
  /// Muting by discarding samples would leave the system microphone indicator lit
  /// while claiming Evie is not listening, which is exactly the kind of dishonest
  /// state this project refuses.
  func stop() {
    publishTask?.cancel()
    publishTask = nil

    if let engine {
      engine.inputNode.removeTap(onBus: 0)
      engine.stop()
    }
    engine = nil
    meter.reset()
    isCapturing = false
    levels = []
  }

  /// Decides whether the turn is over.
  ///
  /// It waits for speech before it will ever end a turn, so opening the
  /// microphone in a quiet room does not immediately submit nothing.
  private func considerEndOfSpeech(level: CGFloat) {
    let event = gate.absorb(level: level)
    guard detectsEndOfSpeech else {
      return
    }
    switch event {
    case .speechStarted:
      onSpeechStarted?()
    case .speechEnded:
      onEndOfSpeech?()
    case .none:
      break
    }
  }

  private func startPublishing() {
    publishTask?.cancel()
    publishTask = Task { @MainActor [weak self] in
      while !Task.isCancelled {
        try? await Task.sleep(for: Self.publishInterval)
        guard let self, self.isCapturing else {
          return
        }
        let level = CGFloat(self.meter.currentLevel())
        var updated = self.levels
        if updated.count >= Self.historyLength {
          updated.removeFirst(updated.count - Self.historyLength + 1)
        }
        updated.append(level)
        self.levels = updated
        self.onLevels?(updated)
        self.considerEndOfSpeech(level: level)
      }
    }
  }
}
