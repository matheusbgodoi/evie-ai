import AppKit
import EvieCore
import Foundation

/// Edits the preferences file behind the settings window.
///
/// Every change is written immediately rather than behind a Save button: these
/// are switches and key combinations, they are validated before they are written,
/// and a preference that only applies after you remember to press Save is a
/// preference that quietly does not apply.
@MainActor
final class EviePreferencesViewModel: ObservableObject {
  @Published private(set) var preferences: EviePreferences
  @Published private(set) var feedback: Feedback?
  /// The action whose key combination is currently being captured.
  @Published private(set) var recordingAction: EvieShortcutAction?
  /// Actions the system refused to register, so the row can say so.
  @Published private(set) var unavailableActions: Set<EvieShortcutAction> = []
  /// Cloned voices offered by the local voice engine, empty when it is down.
  @Published private(set) var clonedVoices: [EvieClonedVoice] = []
  @Published private(set) var isVoiceEngineRunning = false

  private let store: EviePreferencesStore
  private let onTestVoice: @MainActor (String?, Double) -> Void
  private let onChange: @MainActor (EviePreferences) -> Void
  private var keyMonitor: Any?

  init(
    preferences: EviePreferences,
    store: EviePreferencesStore,
    loadFailure: EviePreferencesStore.LoadFailure? = nil,
    onTestVoice: @escaping @MainActor (String?, Double) -> Void = { _, _ in },
    onChange: @escaping @MainActor (EviePreferences) -> Void
  ) {
    self.preferences = preferences
    self.store = store
    self.onTestVoice = onTestVoice
    self.onChange = onChange
    if let loadFailure {
      feedback = Feedback(message: loadFailure.message, isError: true)
    }
  }

  /// Adopts a change made outside this window — the call-mode shortcut, or the
  /// overlay being dragged — without writing it back.
  func adopt(_ preferences: EviePreferences) {
    guard preferences != self.preferences else {
      return
    }
    self.preferences = preferences
  }

  func reportShortcutAvailability(unavailable: Set<EvieShortcutAction>) {
    unavailableActions = unavailable
  }

  // MARK: - Shortcuts

  func shortcut(for action: EvieShortcutAction) -> EvieShortcut? {
    preferences.shortcuts.shortcut(for: action)
  }

  func isUsingDefault(_ action: EvieShortcutAction) -> Bool {
    preferences.shortcuts.isUsingDefault(action)
  }

  func isDisabled(_ action: EvieShortcutAction) -> Bool {
    preferences.shortcuts.isDisabled(action)
  }

  /// The other actions that already claim this action's combination.
  func conflictingActions(with action: EvieShortcutAction) -> [EvieShortcutAction] {
    preferences.shortcuts
      .conflicts()
      .first { $0.actions.contains(action) }?
      .actions
      .filter { $0 != action } ?? []
  }

  func disableShortcut(_ action: EvieShortcutAction) {
    cancelRecording()
    apply { $0.shortcuts.disable(action) }
  }

  func resetShortcut(_ action: EvieShortcutAction) {
    cancelRecording()
    apply { $0.shortcuts.reset(action) }
  }

  func resetAllShortcuts() {
    cancelRecording()
    apply { $0.shortcuts.resetAll() }
  }

  /// Starts capturing the next key combination for this action.
  ///
  /// A local monitor is used rather than first-responder plumbing so the capture
  /// works from an ordinary SwiftUI row and always ends up back here.
  func beginRecording(_ action: EvieShortcutAction) {
    cancelRecording()
    recordingAction = action
    feedback = Feedback(
      message: "Pressione a combinação que você quer. Esc cancela.",
      isError: false
    )
    // The event itself is not `Sendable`, so the two values that matter are
    // lifted out of it before anything crosses an isolation boundary.
    keyMonitor = NSEvent.addLocalMonitorForEvents(matching: [.keyDown]) {
      [weak self] event in
      let keyCode = event.keyCode
      var modifiers: EvieModifierFlags = []
      if event.modifierFlags.contains(.command) { modifiers.insert(.command) }
      if event.modifierFlags.contains(.option) { modifiers.insert(.option) }
      if event.modifierFlags.contains(.control) { modifiers.insert(.control) }
      if event.modifierFlags.contains(.shift) { modifiers.insert(.shift) }

      guard let self else {
        return event
      }
      let consumed = MainActor.assumeIsolated {
        self.consume(keyCode: keyCode, modifiers: modifiers)
      }
      return consumed ? nil : event
    }
  }

  /// Always call this when the recorder leaves the screen. There is no `deinit`
  /// cleanup: the monitor token is not `Sendable`, so it cannot be touched from a
  /// nonisolated deinit under strict concurrency.
  func cancelRecording() {
    if let keyMonitor {
      NSEvent.removeMonitor(keyMonitor)
      self.keyMonitor = nil
    }
    recordingAction = nil
  }

  /// Returns true when the key press was consumed by the recorder rather than
  /// being delivered to whatever had focus.
  private func consume(keyCode: UInt16, modifiers: EvieModifierFlags) -> Bool {
    guard let action = recordingAction else {
      return false
    }

    // Escape on its own leaves the capture without changing anything.
    if keyCode == 53, modifiers.isEmpty {
      cancelRecording()
      feedback = nil
      return true
    }

    let candidate = EvieShortcut(keyCode: keyCode, modifiers: modifiers)
    do {
      try candidate.validate()
    } catch {
      feedback = Feedback(
        message: (error as? LocalizedError)?.errorDescription
          ?? "Essa combinação não serve como atalho global.",
        isError: true
      )
      return true
    }

    cancelRecording()
    apply(
      successMessage: "\(action.title): \(candidate.displayString)."
    ) {
      $0.shortcuts.setShortcut(candidate, for: action)
    }
    return true
  }

  // MARK: - Voice

  func setSpeechOutputEnabled(_ enabled: Bool) {
    let leavingCall = !enabled && preferences.voice.callModeEnabled
    apply(
      successMessage: leavingCall
        ? "Sem a fala não existe ligação, então o modo ligação também foi desligado."
        : nil
    ) {
      $0.voice.setSpeechOutputEnabled(enabled)
    }
  }

  func setCallModeEnabled(_ enabled: Bool) {
    let enablingSpeech = enabled && !preferences.voice.speechOutputEnabled
    apply(
      successMessage: enablingSpeech
        ? "O modo ligação precisa da fala, então liguei a fala junto."
        : nil
    ) {
      $0.voice.setCallModeEnabled(enabled)
    }
  }

  func setWakeWordEnabled(_ enabled: Bool) {
    apply { $0.voice.wakeWordEnabled = enabled }
  }

  func setPushToTalkEnabled(_ enabled: Bool) {
    apply { $0.voice.pushToTalkEnabled = enabled }
  }

  func setWakePhrase(_ phrase: String) {
    apply { $0.voice.wakePhrase = phrase }
  }

  func setVoiceIdentifier(_ identifier: String?) {
    apply {
      $0.voice.voiceIdentifier = identifier
      // Choosing a system voice means not using a cloned one.
      $0.voice.clonedVoiceID = nil
    }
  }

  func setClonedVoiceID(_ identifier: String) {
    apply { $0.voice.clonedVoiceID = identifier }
  }

  /// Asks the voice engine whether it is up and what it has. Cheap, and called
  /// whenever the voice settings appear, because the engine is started and
  /// stopped outside Evie.
  func refreshVoiceEngine() async {
    let client = EvieOmniVoiceClient()
    let healthy = await client.isHealthy()
    isVoiceEngineRunning = healthy
    clonedVoices = healthy ? await client.voices() : []
  }

  /// The value the picker binds to: one list holding both engines.
  var selectedVoiceKey: String {
    if let cloned = preferences.voice.clonedVoiceID, !cloned.isEmpty {
      return "cloned:\(cloned)"
    }
    return "system:\(preferences.voice.voiceIdentifier ?? "")"
  }

  func selectVoice(key: String) {
    if key.hasPrefix("cloned:") {
      setClonedVoiceID(String(key.dropFirst("cloned:".count)))
    } else {
      let identifier = String(key.dropFirst("system:".count))
      setVoiceIdentifier(identifier.isEmpty ? nil : identifier)
    }
  }

  /// Speaks a sample with whatever is selected right now, so the choice can be
  /// heard before it is lived with.
  func testVoice() {
    onTestVoice(preferences.voice.voiceIdentifier, preferences.voice.resolvedSpeechRate)
  }

  func setSpeechRate(_ rate: Double) {
    apply { $0.voice.speechRate = rate }
  }

  func setRetainsRawAudio(_ retains: Bool) {
    apply(
      successMessage: retains
        ? "O áudio bruto passará a ficar salvo neste Mac até você apagar."
        : nil
    ) {
      $0.voice.retainsRawAudio = retains
    }
  }

  // MARK: - Appearance

  func setOverlayWidth(_ width: CGFloat) {
    apply { $0.appearance.overlayWidth = width }
  }

  func setAnimatesLogo(_ animates: Bool) {
    apply { $0.appearance.animatesLogo = animates }
  }

  func resetPlacement() {
    apply(successMessage: "A Evie voltou para o rodapé, centralizada.") {
      $0.appearance.resetPlacement()
    }
  }

  // MARK: - Persistence

  /// Applies a change, writes it, and reverts if the result would be invalid.
  private func apply(
    successMessage: String? = nil,
    _ mutate: (inout EviePreferences) -> Void
  ) {
    var updated = preferences
    mutate(&updated)
    guard updated != preferences else {
      return
    }

    do {
      try store.save(updated)
      preferences = updated
      onChange(updated)
      feedback = successMessage.map { Feedback(message: $0, isError: false) }
    } catch {
      feedback = Feedback(
        message: (error as? LocalizedError)?.errorDescription
          ?? error.localizedDescription,
        isError: true
      )
    }
  }
}

extension EviePreferencesViewModel {
  struct Feedback: Equatable {
    let message: String
    let isError: Bool
  }
}
