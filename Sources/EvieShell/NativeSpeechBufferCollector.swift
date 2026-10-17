import AVFoundation
import Foundation

/// Cancellation and a missing final callback must both resume a native speech
/// request exactly once. The audio callback can run on any framework thread.
final class NativeSpeechBufferCollector: @unchecked Sendable {
  private let lock = NSLock()
  private var buffers: [AVAudioPCMBuffer] = []
  private var completed = false
  private var continuation: CheckedContinuation<[AVAudioPCMBuffer]?, Never>?

  func begin(_ continuation: CheckedContinuation<[AVAudioPCMBuffer]?, Never>) -> Bool {
    lock.lock()
    if completed {
      lock.unlock()
      continuation.resume(returning: nil)
      return false
    }
    self.continuation = continuation
    lock.unlock()
    return true
  }

  func receive(_ buffer: AVAudioBuffer) {
    guard let pcm = buffer as? AVAudioPCMBuffer else { return }
    lock.lock()
    guard !completed else {
      lock.unlock()
      return
    }
    if pcm.frameLength > 0 {
      buffers.append(pcm)
      lock.unlock()
    } else {
      completed = true
      let result = buffers
      let continuation = continuation
      self.continuation = nil
      buffers = []
      lock.unlock()
      continuation?.resume(returning: result)
    }
  }

  /// Also works before begin(), closing the cancellation-before-install race.
  func cancel() {
    lock.lock()
    guard !completed else {
      lock.unlock()
      return
    }
    completed = true
    buffers = []
    let continuation = continuation
    self.continuation = nil
    lock.unlock()
    continuation?.resume(returning: nil)
  }
}
