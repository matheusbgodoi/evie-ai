import AVFoundation
import EvieCore
import Foundation

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

  private var capture: EvieAudioCapture?
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
    // No `onLevels`, and that omission is the feature. Nothing about the
    // overlay may suggest she is listening, because from the person's point of
    // view she is not — she is waiting to be called.
    try await capture.start(sink: pump)

    self.capture = capture
    self.recogniser = recogniser
  }

  @available(macOS 26, *)
  private func restartCycle() async throws {
    capture?.stop()
    capture = nil
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
