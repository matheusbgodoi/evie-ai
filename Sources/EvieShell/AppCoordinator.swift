import AppKit
import EvieCore

@MainActor
final class AppCoordinator: NSObject {
  private let conversationStore: EvieConversationStore
  private let configurationLoader: EvieConfigurationLoader
  private let configurationStore: EvieConfigurationStore
  private let configurationEnvironment: [String: String]
  private let viewModel: OverlayViewModel
  private let panelController: OverlayPanelController
  private let startupConfigurationError: (any Error)?
  private var hotKeyController: GlobalHotKeyController?
  private var statusItem: NSStatusItem?
  private var settingsWindowController: SettingsWindowController?
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
    let viewModel = OverlayViewModel(
      agentClient: TurboFieldfareClient(configuration: loadResult.configuration),
      conversationStore: conversationStore
    )
    self.conversationStore = conversationStore
    self.configurationLoader = configurationLoader
    configurationStore = EvieConfigurationStore(fileURL: loadResult.fileURL)
    self.configurationEnvironment = configurationEnvironment
    self.viewModel = viewModel
    startupConfigurationError = loadResult.error
    panelController = OverlayPanelController(viewModel: viewModel)
    super.init()
  }

  func start() {
    NSApp.setActivationPolicy(.accessory)
    configureStatusItem()

    do {
      let controller = try GlobalHotKeyController()
      controller.onSummonPressed = { [weak self] in
        self?.toggleQuickText()
      }
      controller.onSummonReleased = {}
      controller.onQuickText = { [weak self] in
        self?.openQuickText()
      }
      hotKeyController = controller
    } catch {
      viewModel.presentRuntimeError(title: "Atalho global indisponível", error: error)
      panelController.showPassive()
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
      keyEquivalent: "n"
    )
    newConversationItem.keyEquivalentModifierMask = [.command]
    newConversationItem.target = self
    menu.addItem(newConversationItem)

    let historyItem = NSMenuItem(
      title: "Histórico…",
      action: #selector(openHistory),
      keyEquivalent: "h"
    )
    historyItem.keyEquivalentModifierMask = [.command, .shift]
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

    let endpointItem = NSMenuItem(
      title: "Gemma local · \(viewModel.endpointDescription)",
      action: nil,
      keyEquivalent: ""
    )
    endpointItem.isEnabled = false
    menu.addItem(endpointItem)

    let settingsItem = NSMenuItem(
      title: "Configurações…",
      action: #selector(openSettings),
      keyEquivalent: ","
    )
    settingsItem.keyEquivalentModifierMask = [.command]
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
      let settingsViewModel = ModelSettingsViewModel(
        configuration: viewModel.configuration,
        store: configurationStore,
        loader: configurationLoader,
        environment: configurationEnvironment
      ) { [weak self] configuration in
        self?.viewModel.applyConfiguration(configuration)
      }
      settingsWindowController = SettingsWindowController(viewModel: settingsViewModel)
    }
    settingsWindowController?.present()
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
