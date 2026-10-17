import EvieCore
import Foundation

// Only asynchronous audio/transcriber boundaries are controlled here. The
// coordinator's start/stop/continuation guards are extracted from production.
// No microphone, UI, model request or network is used.
@MainActor
final class VoiceAsyncBoundary {
  private var suspended: [CheckedContinuation<Void, Never>] = []
  private var entered: [CheckedContinuation<Void, Never>] = []
  var isPaused = false
  private(set) var entries = 0

  func checkpoint() async {
    entries += 1
    let waiters = entered
    entered.removeAll()
    for waiter in waiters { waiter.resume() }
    if isPaused { await withCheckedContinuation { suspended.append($0) } }
  }

  func waitUntilEntered() async {
    if entries > 0 { return }
    await withCheckedContinuation { entered.append($0) }
  }

  func resume() {
    isPaused = false
    let waiters = suspended
    suspended.removeAll()
    for waiter in waiters { waiter.resume() }
  }
}

private struct VoiceCheckFailure: Error { let reason: String }
private enum SyntheticVoiceError: Error { case preparation }

@MainActor
final class VoiceAudioBoundary {
  let prepare = VoiceAsyncBoundary()
  let opening = VoiceAsyncBoundary()
  var isCapturing = false
  var detectsEndOfSpeech = false
  var failsPreparation = false
  private(set) var starts = 0
  private(set) var stops = 0

  func prepareInputFormat() async throws -> Int {
    await prepare.checkpoint()
    if failsPreparation { throw SyntheticVoiceError.preparation }
    return 1
  }

  func start(sink: Int?) async throws {
    starts += 1
    await opening.checkpoint()
    isCapturing = true
  }

  func stop() {
    stops += 1
    isCapturing = false
  }
}

@MainActor
final class EvieSpeechTranscription {
  let finishing = VoiceAsyncBoundary()
  private var didReturn = false
  private var returnedWaiters: [CheckedContinuation<Void, Never>] = []
  func finish() async -> String? {
    await finishing.checkpoint()
    didReturn = true
    let waiters = returnedWaiters
    returnedWaiters.removeAll()
    for waiter in waiters { waiter.resume() }
    return "controlled synthetic transcript"
  }

  func waitUntilReturned() async {
    if didReturn { return }
    await withCheckedContinuation { returnedWaiters.append($0) }
  }
}

@MainActor
final class VoiceViewBoundary {
  var spokenOrigin: ComputerUseRequestOrigin = .typed
  private(set) var beganListening = 0
  private(set) var endedListening = 0
  private(set) var unavailableErrors = 0
  private(set) var transcribing = 0
  var lastTranscript: String?
  var quickTextIsAvailable = true
  private(set) var quickTextAttempts = 0
  func beginQuickText() -> Bool {
    quickTextAttempts += 1
    return quickTextIsAvailable
  }
  func endSpeaking() {}
  func beginListening() { beganListening += 1 }
  func endListening(transcript: String?) {
    endedListening += 1
    lastTranscript = transcript
  }
  func presentTranscribing() { transcribing += 1 }
  func presentVoiceUnavailable(_ error: any Error) { unavailableErrors += 1 }
}

@MainActor final class VoiceResearchBoundary { var isRunning = false }
@MainActor final class VoiceCaptureBoundary { var isPresented = false }
@MainActor final class VoiceWakeBoundary { func disarm() {} }
@MainActor final class VoicePlaybackBoundary { func stop() {} }
@MainActor enum NativeWakeTrainingAccess { static var isActive = false }
@MainActor final class VoicePanelBoundary {
  private(set) var shownQuickText = 0
  private(set) var shownPassive = 0
  func showQuickText() { shownQuickText += 1 }
  func showPassive() { shownPassive += 1 }
}

@MainActor
final class VoiceInputHarness {
  let audioCapture = VoiceAudioBoundary()
  let viewModel = VoiceViewBoundary()
  let researchMode = VoiceResearchBoundary()
  let nativeCaptureConsent = VoiceCaptureBoundary()
  let wakeListener = VoiceWakeBoundary()
  let speechOutput = VoicePlaybackBoundary()
  let panelController = VoicePanelBoundary()
  let transcriptionStarting = VoiceAsyncBoundary()
  let transcriptionCancelling = VoiceAsyncBoundary()
  var recognizer = EvieSpeechTranscription()
  var transcription: Any?
  var isHoldingToTalk = false
  var isInCall = false
  var wakeSuppressedByStop = false
  var voiceInputGeneration: UInt64 = 0
  var voiceInputFinalizingGeneration: UInt64?
  private(set) var wakeUpdates = 0
  private var preparationWaiters: [CheckedContinuation<Void, Never>] = []
  var isPreparingVoiceInput = false {
    didSet {
      guard !isPreparingVoiceInput else { return }
      let waiters = preparationWaiters
      preparationWaiters.removeAll()
      for waiter in waiters { waiter.resume() }
    }
  }

  func startTranscription(inputFormat: Int) async throws -> Int? {
    await transcriptionStarting.checkpoint()
    recognizer = EvieSpeechTranscription()
    transcription = recognizer
    return 1
  }

  func cancelTranscription() async {
    transcription = nil
    await transcriptionCancelling.checkpoint()
  }

  func updateWakeListening() { wakeUpdates += 1 }
  func updateToggleMenuTitle() {}

  func waitUntilPreparedTaskEnds() async {
    if !isPreparingVoiceInput { return }
    await withCheckedContinuation { preparationWaiters.append($0) }
  }
}

@main
struct VoiceInputValidation {
  @MainActor
  static func main() async {
    do {
      try await run()
    } catch {
      let reason = (error as? VoiceCheckFailure)?.reason ?? String(describing: error)
      FileHandle.standardError.write(Data(("FAIL: " + reason + "\n").utf8))
      exit(1)
    }
  }

  @MainActor
  private static func run() async throws {
    try await releaseDuringPreparation()
    try await emergencyDuringPreparation()
    try await invalidationDuringPreparation()
    try await competingCaptureDuringPreparation()
    try await endedCallDuringPreparation()
    try await invalidationDuringTranscriptionStart()
    try await invalidationDuringAudioStart()
    try await positivePushToTalk()
    try await positiveClickedTurn()
    try await stalePreparationError()
    try await staleFinalization()
    try await oldFinalizationCannotClearNewToken()
    try urlReviewPreservesEmergencyWakeSuppression()
    try explicitConversationReactivatesWake()
    try trainingBlocksQuickText()
    print(
      "PASS: production voice-input and quick-text methods; 15 controlled lifecycle/suppression cases; no microphone/UI/network"
    )
  }

  @MainActor
  private static func check(_ condition: Bool, _ reason: String) throws {
    if !condition { throw VoiceCheckFailure(reason: reason) }
  }

  @MainActor
  private static func releaseDuringPreparation() async throws {
    let harness = VoiceInputHarness()
    harness.isHoldingToTalk = true
    harness.audioCapture.prepare.isPaused = true
    harness.invokeStart(origin: .pushToTalk)
    await harness.audioCapture.prepare.waitUntilEntered()
    harness.isHoldingToTalk = false
    harness.invokeStop()
    harness.audioCapture.prepare.resume()
    await harness.waitUntilPreparedTaskEnds()
    try check(
      harness.audioCapture.starts == 0, "PTT release during preparation opened the microphone")
    try check(harness.transcriptionStarting.entries == 0, "released PTT started transcription")
    try check(harness.wakeUpdates == 1, "released PTT did not hand back wake listening once")
  }

  @MainActor
  private static func emergencyDuringPreparation() async throws {
    let harness = VoiceInputHarness()
    harness.audioCapture.prepare.isPaused = true
    harness.invokeStart(origin: .clickedMark)
    await harness.audioCapture.prepare.waitUntilEntered()
    harness.voiceInputGeneration &+= 1
    harness.wakeSuppressedByStop = true
    harness.audioCapture.prepare.resume()
    await harness.waitUntilPreparedTaskEnds()
    try check(harness.audioCapture.starts == 0, "emergency cancellation opened audio")
    try check(harness.wakeUpdates == 0, "emergency cancellation rearmed wake listening")
  }

  @MainActor
  private static func invalidationDuringPreparation() async throws {
    let harness = VoiceInputHarness()
    harness.audioCapture.prepare.isPaused = true
    harness.invokeStart(origin: .clickedMark)
    await harness.audioCapture.prepare.waitUntilEntered()
    harness.voiceInputGeneration &+= 1
    harness.audioCapture.prepare.resume()
    await harness.waitUntilPreparedTaskEnds()
    try check(harness.audioCapture.starts == 0, "invalidated preparation opened the microphone")
  }

  @MainActor
  private static func competingCaptureDuringPreparation() async throws {
    let harness = VoiceInputHarness()
    harness.audioCapture.prepare.isPaused = true
    harness.invokeStart(origin: .clickedMark)
    await harness.audioCapture.prepare.waitUntilEntered()
    harness.nativeCaptureConsent.isPresented = true
    harness.audioCapture.prepare.resume()
    await harness.waitUntilPreparedTaskEnds()
    try check(
      harness.audioCapture.starts == 0, "pending capture confirmation allowed microphone start")
    try check(harness.wakeUpdates == 0, "pending capture confirmation rearmed wake listening")
  }

  @MainActor
  private static func endedCallDuringPreparation() async throws {
    let harness = VoiceInputHarness()
    harness.isInCall = true
    harness.audioCapture.prepare.isPaused = true
    harness.invokeStart(origin: .callMode)
    await harness.audioCapture.prepare.waitUntilEntered()
    harness.isInCall = false
    harness.audioCapture.prepare.resume()
    await harness.waitUntilPreparedTaskEnds()
    try check(harness.audioCapture.starts == 0, "ended call opened a late microphone")
  }

  @MainActor
  private static func invalidationDuringTranscriptionStart() async throws {
    let harness = VoiceInputHarness()
    harness.transcriptionStarting.isPaused = true
    harness.transcriptionCancelling.isPaused = true
    harness.invokeStart(origin: .clickedMark)
    await harness.transcriptionStarting.waitUntilEntered()
    harness.voiceInputGeneration &+= 1
    harness.transcriptionStarting.resume()
    await harness.transcriptionCancelling.waitUntilEntered()
    try check(harness.audioCapture.starts == 0, "stale transcriber opened audio")
    try check(harness.isPreparingVoiceInput, "preparation ended before recognizer cleanup")
    harness.invokeStart(origin: .clickedMark)
    try check(harness.audioCapture.prepare.entries == 1, "cleanup allowed overlapping preparation")
    harness.transcriptionCancelling.resume()
    await harness.waitUntilPreparedTaskEnds()
    try check(harness.transcription == nil, "stale recognizer remained installed")
  }

  @MainActor
  private static func invalidationDuringAudioStart() async throws {
    let harness = VoiceInputHarness()
    harness.audioCapture.opening.isPaused = true
    harness.invokeStart(origin: .clickedMark)
    await harness.audioCapture.opening.waitUntilEntered()
    harness.voiceInputGeneration &+= 1
    harness.audioCapture.opening.resume()
    await harness.waitUntilPreparedTaskEnds()
    try check(!harness.audioCapture.isCapturing, "late audio start survived invalidation")
    try check(harness.audioCapture.stops == 1, "late audio start was not stopped")
    try check(harness.viewModel.beganListening == 0, "stale audio start entered listening UI")
    try check(harness.transcription == nil, "late audio start retained recognizer")
  }

  @MainActor
  private static func positivePushToTalk() async throws {
    let harness = VoiceInputHarness()
    harness.isHoldingToTalk = true
    harness.invokeStart(origin: .pushToTalk)
    await harness.waitUntilPreparedTaskEnds()
    try check(harness.audioCapture.starts == 1, "positive PTT did not capture once")
    try check(!harness.audioCapture.detectsEndOfSpeech, "PTT enabled automatic end detection")
    try check(harness.viewModel.beganListening == 1, "positive PTT did not enter listening")
    harness.isHoldingToTalk = false
    harness.invokeStop()
    await harness.recognizer.finishing.waitUntilEntered()
    await harness.recognizer.waitUntilReturned()
    try check(!harness.audioCapture.isCapturing, "PTT stop left audio active")
    try check(harness.viewModel.endedListening == 1, "released PTT lost its valid final transcript")
  }

  @MainActor
  private static func positiveClickedTurn() async throws {
    let harness = VoiceInputHarness()
    harness.invokeStart(origin: .clickedMark)
    await harness.waitUntilPreparedTaskEnds()
    try check(harness.audioCapture.starts == 1, "positive clicked turn did not capture once")
    try check(harness.audioCapture.detectsEndOfSpeech, "clicked turn did not detect speech end")
    harness.invokeStop()
    await harness.recognizer.finishing.waitUntilEntered()
    await harness.recognizer.waitUntilReturned()
    try check(harness.viewModel.endedListening == 1, "clicked turn lost its valid final transcript")
  }

  @MainActor
  private static func stalePreparationError() async throws {
    let harness = VoiceInputHarness()
    harness.audioCapture.prepare.isPaused = true
    harness.audioCapture.failsPreparation = true
    harness.invokeStart(origin: .clickedMark)
    await harness.audioCapture.prepare.waitUntilEntered()
    harness.voiceInputGeneration &+= 1
    harness.wakeSuppressedByStop = true
    harness.audioCapture.prepare.resume()
    await harness.waitUntilPreparedTaskEnds()
    try check(harness.viewModel.unavailableErrors == 0, "stale error replaced the stopped UI")
    try check(harness.audioCapture.starts == 0, "failed preparation opened audio")
    try check(harness.wakeUpdates == 0, "stale preparation error rearmed stopped wake listening")
  }

  @MainActor
  private static func staleFinalization() async throws {
    let harness = VoiceInputHarness()
    harness.invokeStart(origin: .clickedMark)
    await harness.waitUntilPreparedTaskEnds()
    let recognizer = harness.recognizer
    recognizer.finishing.isPaused = true
    harness.invokeStop()
    await recognizer.finishing.waitUntilEntered()
    try check(harness.voiceInputFinalizingGeneration != nil, "pending finish had no token")
    harness.voiceInputGeneration &+= 1
    harness.voiceInputFinalizingGeneration = nil
    harness.wakeSuppressedByStop = true
    recognizer.finishing.resume()
    await recognizer.waitUntilReturned()
    try check(harness.viewModel.endedListening == 0, "revoked finish delivered a stale transcript")
    try check(harness.voiceInputFinalizingGeneration == nil, "revoked finish retained its token")
  }

  @MainActor
  private static func oldFinalizationCannotClearNewToken() async throws {
    let harness = VoiceInputHarness()
    harness.invokeStart(origin: .clickedMark)
    await harness.waitUntilPreparedTaskEnds()
    let oldRecognizer = harness.recognizer
    oldRecognizer.finishing.isPaused = true
    harness.invokeStop()
    await oldRecognizer.finishing.waitUntilEntered()
    let oldToken = harness.voiceInputFinalizingGeneration

    harness.invokeStart(origin: .clickedMark)
    await harness.waitUntilPreparedTaskEnds()
    let currentRecognizer = harness.recognizer
    currentRecognizer.finishing.isPaused = true
    harness.invokeStop()
    await currentRecognizer.finishing.waitUntilEntered()
    let currentToken = harness.voiceInputFinalizingGeneration
    try check(currentToken != nil && oldToken != currentToken, "new finish reused an old token")
    oldRecognizer.finishing.resume()
    await oldRecognizer.waitUntilReturned()
    try check(harness.viewModel.endedListening == 0, "old finish delivered into the new turn")
    try check(
      harness.voiceInputFinalizingGeneration == currentToken, "old finish cleared the new token")
    currentRecognizer.finishing.resume()
    await currentRecognizer.waitUntilReturned()
    try check(harness.viewModel.endedListening == 1, "current finish did not complete")
    try check(harness.voiceInputFinalizingGeneration == nil, "current finish token did not clear")
  }

  @MainActor
  private static func urlReviewPreservesEmergencyWakeSuppression() throws {
    let harness = VoiceInputHarness()
    harness.wakeSuppressedByStop = true
    harness.invokeQuickText(reactivatingWake: false)
    try check(harness.wakeSuppressedByStop, "URL review cleared emergency wake suppression")
    try check(harness.wakeUpdates == 0, "URL review rearmed wake listening")
    try check(harness.panelController.shownQuickText == 1, "URL review did not show its draft UI")
  }

  @MainActor
  private static func explicitConversationReactivatesWake() throws {
    let harness = VoiceInputHarness()
    harness.wakeSuppressedByStop = true
    harness.invokeQuickText(reactivatingWake: true)
    try check(!harness.wakeSuppressedByStop, "explicit conversation did not clear wake suppression")
    try check(harness.wakeUpdates == 1, "explicit conversation did not update wake once")
    try check(harness.panelController.shownQuickText == 1, "explicit conversation did not open UI")
  }

  @MainActor
  private static func trainingBlocksQuickText() throws {
    let harness = VoiceInputHarness()
    NativeWakeTrainingAccess.isActive = true
    defer { NativeWakeTrainingAccess.isActive = false }
    harness.invokeQuickText(reactivatingWake: true)
    try check(harness.wakeUpdates == 0, "quick-text interrupted wake enrollment")
    try check(harness.viewModel.quickTextAttempts == 0, "quick-text mutated UI during enrollment")
  }
}
