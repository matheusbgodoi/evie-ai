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
  private let audioCapture = EvieAudioCapture()
  /// True while push-to-talk is holding the microphone open, so releasing the key
  /// stops it but a click on the mark toggles instead.
  private var isHoldingToTalk = false
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
      capabilities: Self.capabilities(for: preferencesResult.preferences)
    )
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
  }

  /// Evie only claims a capability whose code path is actually wired up. Voice
  /// preferences describe intent; they do not by themselves enable anything.
  fileprivate static func capabilities(
    for preferences: EviePreferences
  ) -> EvieCapabilitySnapshot {
    _ = preferences
    return .textOnly
  }

  func start() {
    NSApp.setActivationPolicy(.accessory)
    configureStatusItem()

    audioCapture.onLevels = { [weak self] levels in
      self?.viewModel.updateInputLevels(levels)
    }
    viewModel.onVoiceActivationRequested = { [weak self] in
      self?.toggleListening()
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

  func stop() {
    audioCapture.stop()
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
    item.button?.toolTip = "Evie · IA pessoal local"

    let menu = NSMenu()
    menu.delegate = self
    let toggleItem = NSMenuItem(
      title: "Conversar com a Evie…",
      action: #selector(openQuickText),
      keyEquivalent: ""
    )
    toggleItem.target = self
    menu.addItem(toggleItem)

    let newConversationItem = NSMenuItem(
      title: "Nova conversa",
      action: #selector(newConversation),
      keyEquivalent: ""
    )
    newConversationItem.target = self
    menu.addItem(newConversationItem)

    let historyItem = NSMenuItem(
      title: "Histórico…",
      action: #selector(openHistory),
      keyEquivalent: ""
    )
    historyItem.target = self
    menu.addItem(historyItem)

    let hideItem = NSMenuItem(
      title: "Ocultar Evie",
      action: #selector(toggleOverlay),
      keyEquivalent: ""
    )
    hideItem.target = self
    menu.addItem(hideItem)
    visibilityMenuItem = hideItem

    menu.addItem(.separator())

    let identityItem = NSMenuItem(
      title: "Evie · assistente pessoal",
      action: nil,
      keyEquivalent: ""
    )
    identityItem.isEnabled = false
    menu.addItem(identityItem)

    let settingsItem = NSMenuItem(
      title: "Configurações…",
      action: #selector(openSettings),
      keyEquivalent: ""
    )
    settingsItem.target = self
    menu.addItem(settingsItem)

    menu.addItem(.separator())

    let quitItem = NSMenuItem(
      title: "Encerrar Evie",
      action: #selector(quit),
      keyEquivalent: "q"
    )
    quitItem.target = self
    menu.addItem(quitItem)

    item.menu = menu
    statusItem = item
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
        loadFailure: preferencesLoadFailure
      ) { [weak self] updated in
        self?.preferencesDidChange(updated)
      }
      self.preferencesViewModel = preferencesViewModel
      settingsWindowController = SettingsWindowController(
        modelViewModel: modelViewModel,
        preferencesViewModel: preferencesViewModel,
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

  /// Clicking the mark toggles; holding push-to-talk does not.
  fileprivate func toggleListening() {
    if audioCapture.isCapturing {
      stopListening()
    } else {
      startListening()
    }
  }

  fileprivate func startListening() {
    guard !audioCapture.isCapturing else {
      return
    }
    Task { @MainActor [weak self] in
      guard let self else { return }
      do {
        try await audioCapture.start()
        viewModel.beginListening()
      } catch {
        isHoldingToTalk = false
        viewModel.presentVoiceUnavailable(error)
      }
    }
  }

  fileprivate func stopListening() {
    guard audioCapture.isCapturing else {
      return
    }
    audioCapture.stop()
    // Speech recognition is not wired yet, so there is no transcript to hand
    // back. The view model says exactly that rather than inventing one.
    viewModel.endListening(transcript: nil)
  }

  /// Cancels the running answer and puts the overlay away.
  ///
  /// Once audio exists this also closes the microphone and cuts playback; the
  /// shortcut is registered now so the reflex is already in the user's hands.
  fileprivate func stopEverything() {
    isHoldingToTalk = false
    audioCapture.stop()
    viewModel.cancelCurrentInteraction()
    panelController.hide()
    updateToggleMenuTitle()
  }

  fileprivate func toggleCallMode() {
    var updated = preferences
    updated.voice.setCallModeEnabled(!updated.voice.callModeEnabled)
    do {
      try preferencesStore.save(updated)
      preferencesDidChange(updated)
      // The preference is real and saved; the behaviour it selects is not built
      // yet. Saying so is better than flipping a switch that appears to do
      // nothing.
      viewModel.presentRuntimeWarning(
        updated.voice.callModeEnabled
          ? "Modo ligação guardado. Ele passa a valer quando a voz estiver ligada."
          : "Modo ligação desligado."
      )
    } catch {
      viewModel.presentRuntimeError(title: "Não consegui mudar o modo", error: error)
    }
  }

  fileprivate func preferencesDidChange(_ updated: EviePreferences) {
    let appearanceChanged = updated.appearance != preferences.appearance
    let shortcutsChanged = updated.shortcuts != preferences.shortcuts
    preferences = updated

    if appearanceChanged {
      panelController.applyAppearance(updated.appearance)
    }
    if shortcutsChanged {
      applyShortcuts()
    }
    preferencesViewModel?.adopt(updated)
    viewModel.applyCapabilities(Self.capabilities(for: updated))
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
}

extension AppCoordinator: NSMenuDelegate {
  func menuWillOpen(_ menu: NSMenu) {
    updateToggleMenuTitle()
  }
}
