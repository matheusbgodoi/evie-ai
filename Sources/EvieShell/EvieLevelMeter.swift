import AVFoundation
import Accelerate
import Foundation
import Synchronization

/// Turns audio buffers into one smoothed level.
///
/// It runs on the audio thread, so it holds no Swift concurrency machinery and
/// does nothing that can allocate or block. A short attack and a long release
/// stop the ring from flickering between syllables.
final class EvieLevelMeter: Sendable {
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
