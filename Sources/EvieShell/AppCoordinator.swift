import AVFoundation
import AppKit
import EvieCore

@MainActor
final class AppCoordinator: NSObject {
  private let conversationStore: EvieConversationStore
  private let configurationLoader: EvieConfigurationLoader
  private let configurationStore: EvieConfigurationStore
  private let preferencesStore: EviePreferencesStore
  private var preferences: EviePreferences
  private let preferencesLoadFailure: EviePreferencesStore.LoadFailure?
  private let configurationEnvironment: [String: String]
  private let viewModel: OverlayViewModel
  private let chrome: OverlayChromeModel
  private let panelController: OverlayPanelController
  private let startupConfigurationError: (any Error)?
  private var hotKeyController: GlobalHotKeyController?
  private var statusItem: NSStatusItem?
  private var settingsWindowController: SettingsWindowController?
  private var preferencesViewModel: EviePreferencesViewModel?
  /// Owned here rather than by the settings window: the folders decide what Evie
  /// can reach on every turn, so they have to outlive a window that is usually
  /// closed.
  private let rootsViewModel = EvieRootsViewModel()
  private let audioCapture = EvieAudioCapture()
  private let speechOutput = EvieSpeechOutput()
  /// True while push-to-talk is holding the microphone open, so releasing the key
  /// stops it but a click on the mark toggles instead.
  private var isHoldingToTalk = false
  /// Whether the overlay is currently showing the voice-only surface. Distinct
  /// from the preference: the preference says the mark may switch into a call,
  /// this says it did.
  private var isInCall = false
  /// Held as `AnyObject` because speech recognition needs macOS 26 and the
  /// coordinator does not. Every use is inside an availability check.
  private var transcription: AnyObject?
  private var historyWindowController: ConversationHistoryWindowController?
  private weak var visibilityMenuItem: NSMenuItem?

  override init() {
    let processEnvironment = ProcessInfo.processInfo.environment
    let supportedEnvironmentNames = [
      "EVIE_CONFIG_FILE",
      "EVIE_MODEL_ENDPOINT",
      "EVIE_MODEL_NAME",
      "EVIE_MODEL_CONTEXT",
      "EVIE_MODEL_MAX_COMPLETION",
      "EVIE_MODEL_TEMPERATURE",
      "EVIE_MODEL_TOP_P",
      "EVIE_MODEL_TIMEOUT_SECONDS",
    ]
    let configurationEnvironment = Dictionary(
      uniqueKeysWithValues: supportedEnvironmentNames.compactMap { name in
        processEnvironment[name].map { (name, $0) }
      }
    )
    let configurationLoader = EvieConfigurationLoader()
    let resolvedFileResult: Result<URL, any Error>
    do {
      resolvedFileResult = .success(
        try configurationLoader.resolvedFileURL(environment: configurationEnvironment)
      )
    } catch {
      resolvedFileResult = .failure(error)
    }

    let loadResult:
      (
        configuration: EvieConfiguration,
        fileURL: URL,
        error: (any Error)?
      )
    switch resolvedFileResult {
    case .success(let configurationFileURL):
      do {
        let configuration = try configurationLoader.load(environment: configurationEnvironment)
        loadResult = (configuration, configurationFileURL, nil)
      } catch {
        loadResult = (EvieConfiguration(), configurationFileURL, error)
      }
    case .failure(let error):
      loadResult = (EvieConfiguration(), configurationLoader.fileURL, error)
    }

    let conversationStore = EvieConversationStore()
    let preferencesStore = EviePreferencesStore(
      fileURL: loadResult.fileURL
        .deletingLastPathComponent()
        .appendingPathComponent("preferences.json", isDirectory: false)
    )
    let preferencesResult = preferencesStore.loadWithDiagnostics()
    let viewModel = OverlayViewModel(
      agentClient: TurboFieldfareClient(configuration: loadResult.configuration),
      conversationStore: conversationStore,
      capabilities: Self.capabilities(
        for: preferencesResult.preferences,
        hasGrantedFolders: !EvieRootRegistry().load().isEmpty
      )
    )
    // Evie never launches into a call: that is an action, and actions are taken
    // by the person, not restored from a file.
    let chrome = OverlayChromeModel(appearance: preferencesResult.preferences.appearance)

    self.conversationStore = conversationStore
    self.configurationLoader = configurationLoader
    configurationStore = EvieConfigurationStore(fileURL: loadResult.fileURL)
    self.preferencesStore = preferencesStore
    preferences = preferencesResult.preferences
    preferencesLoadFailure = preferencesResult.failure
    self.configurationEnvironment = configurationEnvironment
    self.viewModel = viewModel
    self.chrome = chrome
    startupConfigurationError = loadResult.error
    panelController = OverlayPanelController(
      viewModel: viewModel,
      chrome: chrome,
      appearance: preferencesResult.preferences.appearance,
      preferencesStore: preferencesStore
    )
    super.init()

    viewModel.grantedRoots = { [rootsViewModel] in rootsViewModel.roots }
    rootsViewModel.onChange = { [weak self] roots in
      guard let self else { return }
      viewModel.applyCapabilities(
        Self.capabilities(for: preferences, hasGrantedFolders: !roots.isEmpty)
      )
    }
  }

  /// Evie only claims a capability whose code path is actually wired up.
  ///
  /// A preference is an intention, not a capability: wanting her to speak does
  /// not make her able to. Listening additionally requires a bundle identity,
  /// because without one macOS will never hand over the microphone.
  fileprivate static func capabilities(
    for preferences: EviePreferences,
    hasGrantedFolders: Bool
  ) -> EvieCapabilitySnapshot {
    var capabilities = EvieCapabilitySnapshot.textOnly
    capabilities.readsImagesAndDocuments = true
    // Told the truth about her own reach: with nothing granted she must not
    // offer to look, and the moment a folder is authorised she must know she
    // can. Claiming either wrongly is the fastest way to make her useless.
    capabilities.readsLocalFiles = hasGrantedFolders
    capabilities.speaksAnswers =
      preferences.voice.speechOutputEnabled && !EvieSpeechOutput.availableVoices().isEmpty
    if EvieAudioCapture.isBundled, preferences.voice.pushToTalkEnabled {
      if #available(macOS 26, *) {
        capabilities.listensToSpeech = EvieSpeechTranscription.isSupported
      }
    }
    return capabilities
  }

  func start() {
    NSApp.setActivationPolicy(.accessory)
    configureStatusItem()

    audioCapture.onLevels = { [weak self] levels in
      self?.viewModel.updateInputLevels(levels)
    }
    audioCapture.onEndOfSpeech = { [weak self] in
      self?.stopListening()
    }
    viewModel.onVoiceActivationRequested = { [weak self] in
      self?.activateVoice()
    }
    speechOutput.onLevels = { [weak self] levels in
      self?.viewModel.updateOutputLevels(levels)
    }
    speechOutput.onStarted = { [weak self] in
      self?.viewModel.beginSpeaking()
    }
    speechOutput.onFinished = { [weak self] in
      guard let self else { return }
      viewModel.endSpeaking()
      // A call keeps going. When she stops talking the microphone opens again,
      // which is the difference between a call and a sequence of questions.
      if isInCall {
        startListening()
      }
    }
    viewModel.onAnswerReady = { [weak self] answer in
      self?.speak(answer)
    }

    do {
      let controller = try GlobalHotKeyController()
      controller.onAction = { [weak self] action, phase in
        self?.perform(action, phase: phase)
      }
      hotKeyController = controller
      applyShortcuts()
    } catch {
      viewModel.presentRuntimeError(title: "Atalhos globais indisponíveis", error: error)
      panelController.showPassive()
    }

    // Evie has no Dock icon, so there is no ordinary way to reach Settings when a
    // shortcut is unavailable. This flag is that way out, and it is what makes the
    // window testable without a mouse.
    if CommandLine.arguments.contains("--open-settings") {
      openSettings()
    }

    if let startupConfigurationError {
      viewModel.presentRuntimeError(
        title: "Configuração local inválida",
        error: startupConfigurationError
      )
      panelController.showPassive()
    } else {
      openQuickText()
    }
  }

  /// Diagnostics for `--presentation-check`. Not used by the running application.
  var presentationDiagnostics: String {
    panelController.diagnostics
  }

  func diagnosticShow() {
    openQuickText()
  }

  func diagnosticHide() {
    panelController.hide()
  }

  func stop() {
    audioCapture.stop()
    speechOutput.stop()
    viewModel.cancelCurrentInteraction()
    hotKeyController = nil
    if let statusItem {
      NSStatusBar.system.removeStatusItem(statusItem)
    }
    statusItem = nil
    settingsWindowController?.close()
    settingsWindowController = nil
    historyWindowController?.close()
    historyWindowController = nil
  }

  func prepareForTermination() async {
    audioCapture.stop()
    speechOutput.stop()
    viewModel.cancelCurrentInteraction()
    await viewModel.waitForHistoryPersistence()
  }
}

extension AppCoordinator {
  fileprivate func configureStatusItem() {
    let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
    item.button?.image = NSImage(
      systemSymbolName: "sparkles",
      accessibilityDescription: "Evie"
    )
    item.button?.toolTip = "Evie · assistente pessoal"

    let menu = NSMenu()
    menu.delegate = self
    item.menu = menu
    statusItem = item
    rebuildMenu()
  }

  /// Rebuilds the menu so every item shows the shortcut currently bound to it.
  ///
  /// Every action lives here as well as on a key combination: a shortcut the
  /// system refused, or one the user disabled, must never make a feature
  /// unreachable.
  fileprivate func rebuildMenu() {
    guard let menu = statusItem?.menu else {
      return
    }
    menu.removeAllItems()

    add(
      to: menu, title: "Conversar com a Evie…", action: #selector(openQuickText),
      shortcut: .quickText)
    add(to: menu, title: "Falar com a Evie", action: #selector(speakToEvie), shortcut: .pushToTalk)
    add(
      to: menu,
      title: preferences.voice.callModeEnabled ? "Sair do modo ligação" : "Entrar no modo ligação",
      action: #selector(toggleCallModeFromMenu),
      shortcut: .toggleCallMode
    )

    menu.addItem(.separator())

    add(
      to: menu, title: "Nova conversa", action: #selector(newConversation),
      shortcut: .newConversation)
    add(to: menu, title: "Histórico…", action: #selector(openHistory), shortcut: .openHistory)
    let visibility = add(
      to: menu,
      title: panelController.isVisible ? "Ocultar Evie" : "Mostrar Evie",
      action: #selector(toggleOverlay),
      shortcut: .toggleOverlay
    )
    visibilityMenuItem = visibility

    menu.addItem(.separator())

    add(
      to: menu, title: "Parar tudo agora", action: #selector(stopEverythingFromMenu),
      shortcut: .emergencyStop)
    add(to: menu, title: "Configurações…", action: #selector(openSettings), shortcut: .openSettings)

    menu.addItem(.separator())

    let identityItem = NSMenuItem(
      title: "Evie · assistente pessoal",
      action: nil,
      keyEquivalent: ""
    )
    identityItem.isEnabled = false
    menu.addItem(identityItem)

    let quitItem = NSMenuItem(title: "Encerrar Evie", action: #selector(quit), keyEquivalent: "q")
    quitItem.target = self
    menu.addItem(quitItem)
  }

  @discardableResult
  fileprivate func add(
    to menu: NSMenu,
    title: String,
    action: Selector,
    shortcut: EvieShortcutAction
  ) -> NSMenuItem {
    let item = NSMenuItem(title: title, action: action, keyEquivalent: "")
    item.target = self
    if let binding = preferences.shortcuts.shortcut(for: shortcut),
      let character = binding.menuCharacter
    {
      item.keyEquivalent = character
      item.keyEquivalentModifierMask = Self.modifierMask(for: binding.modifiers)
    }
    menu.addItem(item)
    return item
  }

  fileprivate static func modifierMask(
    for modifiers: EvieModifierFlags
  ) -> NSEvent.ModifierFlags {
    var mask: NSEvent.ModifierFlags = []
    if modifiers.contains(.command) { mask.insert(.command) }
    if modifiers.contains(.option) { mask.insert(.option) }
    if modifiers.contains(.control) { mask.insert(.control) }
    if modifiers.contains(.shift) { mask.insert(.shift) }
    return mask
  }

  @objc fileprivate func speakToEvie() {
    viewModel.requestVoiceActivation()
  }

  @objc fileprivate func toggleCallModeFromMenu() {
    toggleCallMode()
  }

  @objc fileprivate func stopEverythingFromMenu() {
    stopEverything()
  }

  @objc fileprivate func toggleOverlay() {
    if panelController.isVisible {
      panelController.hide()
    } else {
      openQuickText()
    }
    updateToggleMenuTitle()
  }

  fileprivate func toggleQuickText() {
    if panelController.isVisible, viewModel.isQuickTextEntryPresented {
      panelController.hide()
    } else {
      openQuickText()
    }
    updateToggleMenuTitle()
  }

  @objc fileprivate func openQuickText() {
    if viewModel.beginQuickText() {
      panelController.showQuickText()
    } else {
      panelController.showPassive()
    }
    updateToggleMenuTitle()
  }

  @objc fileprivate func newConversation() {
    viewModel.startNewConversation()
    panelController.showQuickText()
    historyWindowController?.close()
    updateToggleMenuTitle()
  }

  @objc fileprivate func openHistory() {
    if historyWindowController == nil {
      let historyViewModel = ConversationHistoryViewModel(
        store: conversationStore,
        onContinue: { [weak self] id in
          guard let self else { return }
          Task { @MainActor in
            guard await self.viewModel.openConversation(id: id) else {
              return
            }
            self.panelController.showQuickText()
            self.historyWindowController?.close()
            self.updateToggleMenuTitle()
          }
        },
        onNewConversation: { [weak self] in
          self?.newConversation()
        },
        onPrepareDelete: { [weak self] id in
          await self?.viewModel.prepareForConversationDeletion(id: id)
        },
        onDelete: { [weak self] id in
          self?.viewModel.conversationWasDeleted(id: id)
        }
      )
      historyWindowController = ConversationHistoryWindowController(
        viewModel: historyViewModel
      )
    }
    Task { @MainActor [weak self] in
      guard let self else { return }
      await viewModel.waitForHistoryPersistence()
      historyWindowController?.present()
    }
  }

  @objc fileprivate func quit() {
    NSApp.terminate(nil)
  }

  @objc fileprivate func openSettings() {
    if settingsWindowController == nil {
      let modelViewModel = ModelSettingsViewModel(
        configuration: viewModel.configuration,
        store: configurationStore,
        loader: configurationLoader,
        environment: configurationEnvironment
      ) { [weak self] configuration in
        self?.viewModel.applyConfiguration(configuration)
      }
      let preferencesViewModel = EviePreferencesViewModel(
        preferences: preferences,
        store: preferencesStore,
        loadFailure: preferencesLoadFailure,
        onTestVoice: { [weak self] identifier, rate in
          guard let self else { return }
          speechOutput.speak(
            EvieRichText("Oi, Matheus. É assim que eu vou falar com você."),
            using: Self.voice(for: preferences.voice),
            rate: rate
          )
          _ = identifier
        },
        onChange: { [weak self] updated in
          self?.preferencesDidChange(updated)
        }
      )
      self.preferencesViewModel = preferencesViewModel
      settingsWindowController = SettingsWindowController(
        modelViewModel: modelViewModel,
        preferencesViewModel: preferencesViewModel,
        rootsViewModel: rootsViewModel,
        preferencesPath: preferencesStore.fileURL.path,
        configurationPath: configurationStore.fileURL.path
      )
    }
    settingsWindowController?.present()
  }

  /// Routes a global shortcut to the thing it names.
  ///
  /// Every route goes through the same methods the menu bar uses, so a shortcut
  /// and a menu item can never drift into doing different things.
  fileprivate func perform(_ action: EvieShortcutAction, phase: GlobalHotKeyController.Phase) {
    switch (action, phase) {
    case (.toggleOverlay, .pressed):
      toggleQuickText()
    case (.quickText, .pressed):
      openQuickText()
    case (.newConversation, .pressed):
      newConversation()
    case (.openHistory, .pressed):
      openHistory()
    case (.openSettings, .pressed):
      openSettings()
    case (.pushToTalk, .pressed):
      isHoldingToTalk = true
      startListening()
    case (.pushToTalk, .released):
      guard isHoldingToTalk else {
        break
      }
      isHoldingToTalk = false
      stopListening()
    case (.toggleCallMode, .pressed):
      toggleCallMode()
    case (.emergencyStop, .pressed):
      stopEverything()
    default:
      break
    }
  }

  /// What pressing the mark does.
  ///
  /// With call mode on, the mark switches the whole overlay between voice and
  /// text: press once for the voice-only surface, press again to come back. With
  /// it off, the mark just opens and closes the microphone and the text stays
  /// where it is.
  fileprivate func activateVoice() {
    guard preferences.voice.callModeEnabled else {
      toggleListening()
      return
    }
    if isInCall {
      leaveCall()
    } else {
      enterCall()
    }
  }

  fileprivate func enterCall() {
    guard !isInCall else {
      return
    }
    isInCall = true
    chrome.setCallMode(true)
    viewModel.presentCallSurface()
    startListening()
  }

  fileprivate func leaveCall() {
    guard isInCall else {
      return
    }
    isInCall = false
    chrome.setCallMode(false)
    speechOutput.stop()
    viewModel.endSpeaking()
    stopListening()
    openQuickText()
  }

  /// Clicking the mark toggles; holding push-to-talk does not.
  fileprivate func toggleListening() {
    if audioCapture.isCapturing {
      stopListening()
    } else {
      startListening()
    }
  }

  /// Speaks an answer, if that is what the user asked for.
  ///
  /// Reads the text with its markup already resolved, so no asterisk or hash is
  /// ever pronounced.
  fileprivate func speak(_ answer: EvieRichText) {
    guard preferences.voice.speechOutputEnabled else {
      return
    }
    // The visual state follows `onStarted`, not this call: synthesis happens
    // first, and claiming she is speaking before any audio exists would be the
    // exact kind of dishonest indicator this project refuses.
    speechOutput.speak(
      answer,
      using: Self.voice(for: preferences.voice),
      rate: preferences.voice.resolvedSpeechRate
    )
  }

  /// A cloned voice is used when one is chosen; whether its engine is running is
  /// discovered at synthesis time, and failing there falls silent rather than
  /// pretending a system voice was what you asked for.
  fileprivate static func voice(
    for preferences: EvieVoicePreferences
  ) -> EvieSpeechOutput.Voice {
    if let cloned = preferences.clonedVoiceID, !cloned.isEmpty {
      return .cloned(profileID: cloned)
    }
    return .system(identifier: preferences.voiceIdentifier)
  }

  fileprivate func startListening() {
    guard !audioCapture.isCapturing else {
      return
    }
    // Barge-in: opening the microphone always cuts whatever she is saying. Being
    // talked over is the whole point of being able to interrupt.
    speechOutput.stop()
    viewModel.endSpeaking()
    Task { @MainActor [weak self] in
      guard let self else { return }
      do {
        let format = try await audioCapture.prepareInputFormat()
        let sink = try await startTranscription(inputFormat: format)
        // Only a call ends its own turns. Push-to-talk ends when the key is
        // released, and a click ends when it is clicked again.
        audioCapture.detectsEndOfSpeech = isInCall
        try await audioCapture.start(sink: sink)
        viewModel.beginListening()
      } catch {
        isHoldingToTalk = false
        await cancelTranscription()
        viewModel.presentVoiceUnavailable(error)
      }
    }
  }

  /// Starts the recogniser when this Mac has one, and returns the sink the audio
  /// tap should feed. Without recognition the microphone still opens; the level
  /// ring works and the transcript simply does not exist.
  fileprivate func startTranscription(
    inputFormat: AVAudioFormat
  ) async throws -> (any EvieAudioBufferSink)? {
    guard #available(macOS 26, *), EvieSpeechTranscription.isSupported else {
      return nil
    }
    let recogniser = EvieSpeechTranscription()
    recogniser.onTranscriptChanged = { [weak self] settled, volatile in
      self?.viewModel.updateTranscript(settled: settled, volatile: volatile)
    }
    let pump = try await recogniser.start(inputFormat: inputFormat)
    transcription = recogniser
    return pump
  }

  fileprivate func cancelTranscription() async {
    guard #available(macOS 26, *),
      let recogniser = transcription as? EvieSpeechTranscription
    else {
      transcription = nil
      return
    }
    transcription = nil
    await recogniser.cancel()
  }

  fileprivate func stopListening() {
    guard audioCapture.isCapturing else {
      return
    }
    audioCapture.stop()

    guard #available(macOS 26, *),
      let recogniser = transcription as? EvieSpeechTranscription
    else {
      transcription = nil
      viewModel.endListening(transcript: nil)
      return
    }
    transcription = nil
    viewModel.presentTranscribing()
    Task { @MainActor [weak self] in
      let transcript = await recogniser.finish()
      self?.viewModel.endListening(transcript: transcript)
    }
  }

  /// Cancels the running answer and puts the overlay away.
  ///
  /// Once audio exists this also closes the microphone and cuts playback; the
  /// shortcut is registered now so the reflex is already in the user's hands.
  fileprivate func stopEverything() {
    isHoldingToTalk = false
    if isInCall {
      isInCall = false
      chrome.setCallMode(false)
    }
    audioCapture.stop()
    speechOutput.stop()
    viewModel.endSpeaking()
    Task { @MainActor [weak self] in
      await self?.cancelTranscription()
    }
    viewModel.cancelCurrentInteraction()
    panelController.hide()
    updateToggleMenuTitle()
  }

  /// The shortcut does what the mark does, and switches the mode on first if it
  /// was off — a shortcut named after the mode should reach it in one press.
  fileprivate func toggleCallMode() {
    if !preferences.voice.callModeEnabled {
      var updated = preferences
      updated.voice.setCallModeEnabled(true)
      do {
        try preferencesStore.save(updated)
        preferencesDidChange(updated)
      } catch {
        viewModel.presentRuntimeError(title: "Não consegui mudar o modo", error: error)
        return
      }
      panelController.showPassive()
      enterCall()
      return
    }
    activateVoice()
  }

  fileprivate func preferencesDidChange(_ updated: EviePreferences) {
    let appearanceChanged = updated.appearance != preferences.appearance
    let shortcutsChanged = updated.shortcuts != preferences.shortcuts
    preferences = updated

    if appearanceChanged {
      panelController.applyAppearance(updated.appearance)
    }
    // Switching the mode off while a call is on screen has to end the call; the
    // surface it selected must not outlive the permission to show it.
    if !updated.voice.callModeEnabled, isInCall {
      leaveCall()
    }
    if shortcutsChanged {
      applyShortcuts()
    }
    refreshMenuShortcuts()
    preferencesViewModel?.adopt(updated)
    viewModel.applyCapabilities(
      Self.capabilities(for: updated, hasGrantedFolders: !rootsViewModel.roots.isEmpty)
    )
  }

  /// Re-registers every shortcut and reports the ones the system refused.
  ///
  /// A refusal is normal — another application already owns the combination — so
  /// it is surfaced by name rather than silently swallowed.
  fileprivate func applyShortcuts() {
    guard let hotKeyController else {
      return
    }
    let failures = hotKeyController.apply(preferences.shortcuts)
    preferencesViewModel?.reportShortcutAvailability(unavailable: Set(failures.keys))
    if let message = GlobalHotKeyController.failureMessage(
      for: failures,
      preferences: preferences.shortcuts
    ) {
      viewModel.presentRuntimeWarning(message)
    }
  }

  fileprivate func updateToggleMenuTitle() {
    visibilityMenuItem?.title = panelController.isVisible ? "Ocultar Evie" : "Mostrar Evie"
  }

  /// Only the shortcut labels change, but rebuilding is cheap and keeps one
  /// definition of the menu instead of two that can drift.
  fileprivate func refreshMenuShortcuts() {
    rebuildMenu()
    updateToggleMenuTitle()
  }
}

extension AppCoordinator: NSMenuDelegate {
  func menuWillOpen(_ menu: NSMenu) {
    updateToggleMenuTitle()
  }
}
