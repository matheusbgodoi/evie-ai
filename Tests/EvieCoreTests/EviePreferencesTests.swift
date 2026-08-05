import Foundation
import Testing

@testable import EvieCore

@Suite("Evie preferences")
struct EviePreferencesTests {
  @Test("ships a usable default binding for every configurable action")
  func defaultsCoverEveryAction() throws {
    let preferences = EviePreferences()

    for action in EvieShortcutAction.allCases {
      let shortcut = preferences.shortcuts.shortcut(for: action)
      #expect(shortcut != nil, "\(action.rawValue) has no default shortcut")
      try shortcut?.validate()
    }
  }

  @Test("default shortcuts do not collide with each other")
  func defaultsHaveNoConflict() {
    #expect(EviePreferences().shortcuts.conflicts().isEmpty)
  }

  @Test("reports the exact pair of actions that share a key combination")
  func detectsConflicts() {
    var shortcuts = EvieShortcutPreferences()
    let combination = EvieShortcut(keyCode: 49, modifiers: [.option, .shift])
    shortcuts.setShortcut(combination, for: .quickText)
    shortcuts.setShortcut(combination, for: .pushToTalk)

    let conflicts = shortcuts.conflicts()

    #expect(conflicts.count == 1)
    #expect(conflicts.first?.shortcut == combination)
    #expect(conflicts.first?.actions == [.quickText, .pushToTalk])
  }

  @Test("a disabled action keeps no binding and cannot conflict")
  func disablingRemovesTheBinding() {
    var shortcuts = EvieShortcutPreferences()
    shortcuts.disable(.pushToTalk)

    #expect(shortcuts.shortcut(for: .pushToTalk) == nil)
    #expect(shortcuts.isDisabled(.pushToTalk))
    #expect(shortcuts.conflicts().isEmpty)
  }

  @Test("resetting an action restores its documented default")
  func resettingRestoresDefault() {
    var shortcuts = EvieShortcutPreferences()
    shortcuts.setShortcut(EvieShortcut(keyCode: 3, modifiers: [.command]), for: .openHistory)
    shortcuts.reset(.openHistory)

    #expect(shortcuts.shortcut(for: .openHistory) == EvieShortcutAction.openHistory.defaultShortcut)
    #expect(!shortcuts.isDisabled(.openHistory))
  }

  @Test("a global shortcut requires at least one non-shift modifier")
  func rejectsUnsafeShortcuts() {
    #expect(throws: EvieShortcut.ValidationError.missingModifier) {
      try EvieShortcut(keyCode: 49, modifiers: []).validate()
    }
    #expect(throws: EvieShortcut.ValidationError.missingModifier) {
      try EvieShortcut(keyCode: 49, modifiers: [.shift]).validate()
    }
    #expect(throws: Never.self) {
      try EvieShortcut(keyCode: 49, modifiers: [.option, .shift]).validate()
    }
  }

  @Test("renders a shortcut the way macOS spells it")
  func rendersDisplayString() {
    #expect(EvieShortcut(keyCode: 49, modifiers: [.option]).displayString == "⌥Espaço")
    #expect(
      EvieShortcut(keyCode: 49, modifiers: [.option, .shift]).displayString == "⌥⇧Espaço"
    )
    #expect(
      EvieShortcut(keyCode: 8, modifiers: [.command, .control]).displayString == "⌃⌘C"
    )
    #expect(EvieShortcut(keyCode: 53, modifiers: [.option]).displayString == "⌥Esc")
  }

  @Test("turning speech off also leaves call mode off")
  func speechOffDisablesCallMode() {
    var voice = EvieVoicePreferences()
    voice.setCallModeEnabled(true)
    #expect(voice.callModeEnabled)
    #expect(voice.speechOutputEnabled)

    voice.setSpeechOutputEnabled(false)

    #expect(!voice.speechOutputEnabled)
    #expect(!voice.callModeEnabled)
  }

  @Test("turning call mode on implies Evie speaks")
  func callModeRequiresSpeech() {
    var voice = EvieVoicePreferences()
    voice.setSpeechOutputEnabled(false)

    voice.setCallModeEnabled(true)

    #expect(voice.speechOutputEnabled)
    #expect(voice.callModeEnabled)
  }

  @Test("an inconsistent voice pair fails validation instead of being rendered")
  func validatesVoiceInvariant() {
    var voice = EvieVoicePreferences()
    voice.callModeEnabled = true
    voice.speechOutputEnabled = false

    #expect(throws: EviePreferences.ValidationError.callModeRequiresSpeechOutput) {
      try voice.validate()
    }
  }

  @Test("the transcript presentation follows the two voice switches")
  func derivesPresentation() {
    var voice = EvieVoicePreferences()

    voice.setCallModeEnabled(false)
    voice.setSpeechOutputEnabled(false)
    #expect(voice.presentation == .textOnly)

    voice.setSpeechOutputEnabled(true)
    #expect(voice.presentation == .textAndSpeech)

    voice.setCallModeEnabled(true)
    #expect(voice.presentation == .call)
  }

  @Test("overlay width is clamped to a legible range")
  func clampsOverlayWidth() {
    var appearance = EvieAppearancePreferences()

    appearance.overlayWidth = 10
    #expect(appearance.resolvedOverlayWidth == EvieAppearancePreferences.minimumOverlayWidth)

    appearance.overlayWidth = 100_000
    #expect(appearance.resolvedOverlayWidth == EvieAppearancePreferences.maximumOverlayWidth)

    appearance.overlayWidth = 700
    #expect(appearance.resolvedOverlayWidth == 700)
  }

  @Test("clearing the custom origin returns the overlay to its anchored default")
  func resetsPlacement() {
    var appearance = EvieAppearancePreferences()
    appearance.overlayOrigin = EvieOverlayOrigin(x: 120, y: 480)
    appearance.overlayWidth = 900

    appearance.resetPlacement()

    #expect(appearance.overlayOrigin == nil)
    #expect(appearance.overlayWidth == EvieAppearancePreferences.defaultOverlayWidth)
    #expect(appearance.isUsingDefaultPlacement)
  }

  @Test("an out-of-range width is rejected before it is written")
  func validatesAppearance() {
    var preferences = EviePreferences()
    preferences.appearance.overlayWidth = 12

    #expect(throws: EviePreferences.ValidationError.invalidOverlayWidth) {
      try preferences.validate()
    }
  }

  @Test("an empty wake phrase is rejected")
  func validatesWakePhrase() {
    var preferences = EviePreferences()
    preferences.voice.wakeWordEnabled = true
    preferences.voice.wakePhrase = "   "

    #expect(throws: EviePreferences.ValidationError.emptyWakePhrase) {
      try preferences.validate()
    }
  }
}

@Suite("Evie speaks the way she was asked")
struct EvieSpeaksAnswerTests {
  /// The default, and the reason it is the default: an answer read aloud to
  /// something you typed interrupts whatever your hands were doing.
  @Test("typed questions are answered in writing by default")
  func typedIsSilentByDefault() {
    let voice = EvieVoicePreferences()

    #expect(voice.speechOutputEnabled)
    #expect(!voice.speaksTypedAnswers)
    #expect(!voice.speaksAnswer(toSpokenPrompt: false))
  }

  @Test("spoken questions are answered out loud")
  func spokenSpeaks() {
    #expect(EvieVoicePreferences().speaksAnswer(toSpokenPrompt: true))
  }

  @Test("the switch makes her read typed answers too")
  func optingIn() {
    var voice = EvieVoicePreferences()
    voice.speaksTypedAnswers = true

    #expect(voice.speaksAnswer(toSpokenPrompt: false))
    #expect(voice.speaksAnswer(toSpokenPrompt: true))
  }

  @Test("with speech off she stays quiet however she was asked")
  func speechOffWinsOverEverything() {
    var voice = EvieVoicePreferences()
    voice.speaksTypedAnswers = true
    voice.setSpeechOutputEnabled(false)

    #expect(!voice.speaksAnswer(toSpokenPrompt: true))
    #expect(!voice.speaksAnswer(toSpokenPrompt: false))
    #expect(!voice.speaksAnswer(toSpokenPrompt: false, inCall: true))
    // The switch is cleared rather than left claiming something untrue.
    #expect(!voice.speaksTypedAnswers)
  }

  /// A call speaks whatever the words arrived as; that is what makes it a call.
  @Test("a call always speaks")
  func callAlwaysSpeaks() {
    #expect(EvieVoicePreferences().speaksAnswer(toSpokenPrompt: false, inCall: true))
  }
}

@Suite("Evie voice library")
struct EvieVoiceLibraryTests {
  /// Removing a system voice must also stop it being the one that speaks.
  @Test("hiding the selected voice deselects it")
  func hidingClearsSelection() {
    var voice = EvieVoicePreferences()
    voice.voiceIdentifier = "com.apple.voice.compact.pt-BR.Luciana"

    voice.hideVoice(identifier: "com.apple.voice.compact.pt-BR.Luciana")

    #expect(voice.voiceIdentifier == nil)
    #expect(voice.hiddenVoiceIdentifiers.contains("com.apple.voice.compact.pt-BR.Luciana"))
  }

  @Test("hiding another voice leaves the selection alone")
  func hidingAnotherKeepsSelection() {
    var voice = EvieVoicePreferences()
    voice.voiceIdentifier = "escolhida"

    voice.hideVoice(identifier: "outra")

    #expect(voice.voiceIdentifier == "escolhida")
  }

  @Test("a hidden voice can be brought back")
  func restoring() {
    var voice = EvieVoicePreferences()
    voice.hideVoice(identifier: "uma")

    voice.showVoice(identifier: "uma")

    #expect(voice.hiddenVoiceIdentifiers.isEmpty)
  }

  @Test("hidden voices survive being written and read")
  func roundTrip() throws {
    var voice = EvieVoicePreferences()
    voice.hideVoice(identifier: "a")
    voice.hideVoice(identifier: "b")

    let data = try JSONEncoder().encode(EviePreferences(voice: voice))
    let decoded = try JSONDecoder().decode(EviePreferences.self, from: data)

    #expect(decoded.voice.hiddenVoiceIdentifiers == ["a", "b"])
  }

  @Test("nothing is hidden to begin with")
  func defaultsToNothingHidden() {
    #expect(EvieVoicePreferences().hiddenVoiceIdentifiers.isEmpty)
  }
}

@Suite("Evie preferences store")
struct EviePreferencesStoreTests {
  @Test("round-trips every section through the loader")
  func roundTrip() throws {
    let fileURL = temporaryFileURL()
    var preferences = EviePreferences()
    preferences.appearance.overlayWidth = 720
    preferences.appearance.overlayOrigin = EvieOverlayOrigin(x: 42, y: 96)
    preferences.shortcuts.setShortcut(
      EvieShortcut(keyCode: 9, modifiers: [.option, .control]),
      for: .pushToTalk
    )
    preferences.shortcuts.disable(.openSettings)
    preferences.voice.setSpeechOutputEnabled(true)
    preferences.voice.setCallModeEnabled(true)
    preferences.voice.wakePhrase = "Ei, Evie"

    try EviePreferencesStore(fileURL: fileURL).save(preferences)
    let loaded = EviePreferencesStore(fileURL: fileURL).load()

    #expect(loaded == preferences)
  }

  @Test("a missing file resolves to defaults instead of failing")
  func missingFileUsesDefaults() throws {
    let loaded = EviePreferencesStore(fileURL: temporaryFileURL()).load()

    #expect(loaded == EviePreferences())
  }

  @Test("restricts the preferences directory and file to the current user")
  func permissions() throws {
    let fileURL = temporaryFileURL()

    try EviePreferencesStore(fileURL: fileURL).save(EviePreferences())

    let fileAttributes = try FileManager.default.attributesOfItem(atPath: fileURL.path)
    let directoryAttributes = try FileManager.default.attributesOfItem(
      atPath: fileURL.deletingLastPathComponent().path
    )
    #expect((fileAttributes[.posixPermissions] as? NSNumber)?.intValue == 0o600)
    #expect((directoryAttributes[.posixPermissions] as? NSNumber)?.intValue == 0o700)
  }

  @Test("never writes preferences that violate the voice invariant")
  func rejectsInvalidPreferences() throws {
    let fileURL = temporaryFileURL()
    var preferences = EviePreferences()
    preferences.voice.callModeEnabled = true
    preferences.voice.speechOutputEnabled = false

    #expect(throws: EviePreferences.ValidationError.callModeRequiresSpeechOutput) {
      try EviePreferencesStore(fileURL: fileURL).save(preferences)
    }
    #expect(!FileManager.default.fileExists(atPath: fileURL.path))
  }

  @Test("a damaged file falls back to defaults and is repaired by the next save")
  func repairsDamagedFile() throws {
    let fileURL = temporaryFileURL()
    try FileManager.default.createDirectory(
      at: fileURL.deletingLastPathComponent(),
      withIntermediateDirectories: true
    )
    try Data("{ not json".utf8).write(to: fileURL)
    let store = EviePreferencesStore(fileURL: fileURL)

    #expect(store.load() == EviePreferences())

    var repaired = EviePreferences()
    repaired.appearance.overlayWidth = 640
    try store.save(repaired)

    #expect(store.load() == repaired)
  }

  @Test("an unsupported schema version falls back to defaults rather than guessing")
  func rejectsUnknownSchema() throws {
    let fileURL = temporaryFileURL()
    try FileManager.default.createDirectory(
      at: fileURL.deletingLastPathComponent(),
      withIntermediateDirectories: true
    )
    try Data(#"{"schema_version": 99}"#.utf8).write(to: fileURL)

    #expect(EviePreferencesStore(fileURL: fileURL).load() == EviePreferences())
  }

  @Test("an omitted action keeps its default and an explicit null stays disabled")
  func decodesDisabledBindings() throws {
    let fileURL = temporaryFileURL()
    try FileManager.default.createDirectory(
      at: fileURL.deletingLastPathComponent(),
      withIntermediateDirectories: true
    )
    let document = """
      {
        "schema_version": 1,
        "shortcuts": {
          "push_to_talk": null
        }
      }
      """
    try Data(document.utf8).write(to: fileURL)

    let loaded = EviePreferencesStore(fileURL: fileURL).load()

    #expect(loaded.shortcuts.isDisabled(.pushToTalk))
    #expect(loaded.shortcuts.shortcut(for: .pushToTalk) == nil)
    #expect(
      loaded.shortcuts.shortcut(for: .toggleOverlay)
        == EvieShortcutAction.toggleOverlay
        .defaultShortcut
    )
  }
}

extension EviePreferencesStoreTests {
  fileprivate func temporaryFileURL() -> URL {
    FileManager.default.temporaryDirectory
      .appendingPathComponent(UUID().uuidString, isDirectory: true)
      .appendingPathComponent("preferences.json", isDirectory: false)
  }
}
