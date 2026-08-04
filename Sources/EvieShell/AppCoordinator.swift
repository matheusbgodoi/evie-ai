import AppKit
import EvieCore

@MainActor
final class AppCoordinator: NSObject {
  private let viewModel: OverlayViewModel
  private let panelController: OverlayPanelController
  private var hotKeyController: GlobalHotKeyController?
  private var statusItem: NSStatusItem?
  private weak var toggleMenuItem: NSMenuItem?

  override init() {
    let viewModel = OverlayViewModel(agentClient: TurboFieldfareClient())
    self.viewModel = viewModel
    panelController = OverlayPanelController(viewModel: viewModel)
    super.init()
  }

  func start() {
    NSApp.setActivationPolicy(.accessory)
    configureStatusItem()

    do {
      let controller = try GlobalHotKeyController()
      controller.onSummonPressed = { [weak self] in
        self?.toggleOverlay()
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
  }

  func stop() {
    viewModel.cancelCurrentInteraction()
    hotKeyController = nil
    if let statusItem {
      NSStatusBar.system.removeStatusItem(statusItem)
    }
    statusItem = nil
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
      title: "Mostrar Evie",
      action: #selector(toggleOverlay),
      keyEquivalent: ""
    )
    toggleItem.target = self
    menu.addItem(toggleItem)
    self.toggleMenuItem = toggleItem

    let quickTextItem = NSMenuItem(
      title: "Comando rápido…",
      action: #selector(openQuickText),
      keyEquivalent: ""
    )
    quickTextItem.target = self
    menu.addItem(quickTextItem)

    menu.addItem(.separator())

    let endpointItem = NSMenuItem(
      title: "Gemma local · \(viewModel.endpointDescription)",
      action: nil,
      keyEquivalent: ""
    )
    endpointItem.isEnabled = false
    menu.addItem(endpointItem)

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
    panelController.togglePassive()
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

  @objc fileprivate func quit() {
    NSApp.terminate(nil)
  }

  fileprivate func updateToggleMenuTitle() {
    toggleMenuItem?.title = panelController.isVisible ? "Ocultar Evie" : "Mostrar Evie"
  }
}

extension AppCoordinator: NSMenuDelegate {
  func menuWillOpen(_ menu: NSMenu) {
    updateToggleMenuTitle()
  }
}
