import AVFoundation
import Accelerate
import EvieCore
import Foundation
import Synchronization

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

  /// How many level samples the ring and the waveform draw.
  private static let historyLength = 44
  /// Levels are published at a bounded rate rather than per audio buffer.
  private static let publishInterval = Duration.milliseconds(40)
  /// Below this the microphone is treated as silent.
  private static let noiseFloorDecibels: Float = -55

  private let meter = LevelMeter()
  private var engine: AVAudioEngine?
  private var publishTask: Task<Void, Never>?

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

  func start() async throws {
    guard !isCapturing else {
      return
    }
    guard Self.isBundled else {
      throw CaptureError.notBundled
    }

    let resolved = await requestPermission()
    guard resolved.allowsCapture else {
      throw CaptureError.permissionDenied
    }

    let engine = AVAudioEngine()
    let input = engine.inputNode
    let format = input.outputFormat(forBus: 0)
    guard format.sampleRate > 0, format.channelCount > 0 else {
      throw CaptureError.engineFailed("nenhum dispositivo de entrada disponível")
    }

    let meter = meter
    let floor = Self.noiseFloorDecibels
    input.installTap(onBus: 0, bufferSize: 1_024, format: format) { buffer, _ in
      meter.absorb(buffer, noiseFloorDecibels: floor)
    }

    do {
      engine.prepare()
      try engine.start()
    } catch {
      input.removeTap(onBus: 0)
      throw CaptureError.engineFailed(error.localizedDescription)
    }

    self.engine = engine
    isCapturing = true
    levels = Array(repeating: 0, count: Self.historyLength)
    startPublishing()
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
      }
    }
  }
}

/// Turns audio buffers into one smoothed level.
///
/// It runs on the audio thread, so it holds no Swift concurrency machinery and
/// does nothing that can allocate or block. A short attack and a long release
/// stop the ring from flickering between syllables.
private final class LevelMeter: Sendable {
  private struct State {
    var level: Float = 0
  }

  private let state = Mutex(State())

  /// Rises quickly so speech onset is visible immediately.
  private static let attack: Float = 0.35
  /// Falls slowly so the gaps inside a sentence do not read as silence.
  private static let release: Float = 0.06

  func absorb(_ buffer: AVAudioPCMBuffer, noiseFloorDecibels: Float) {
    guard let channel = buffer.floatChannelData?[0] else {
      return
    }
    let frames = vDSP_Length(buffer.frameLength)
    guard frames > 0 else {
      return
    }

    var meanSquare: Float = 0
    vDSP_measqv(channel, 1, &meanSquare, frames)
    let rms = sqrt(meanSquare)
    let decibels = 20 * log10(max(rms, 1e-7))
    let normalised = max(0, min(1, (decibels - noiseFloorDecibels) / -noiseFloorDecibels))

    state.withLock { state in
      let coefficient = normalised > state.level ? Self.attack : Self.release
      state.level += (normalised - state.level) * coefficient
    }
  }

  func currentLevel() -> Float {
    state.withLock { $0.level }
  }

  func reset() {
    state.withLock { $0.level = 0 }
  }
}
