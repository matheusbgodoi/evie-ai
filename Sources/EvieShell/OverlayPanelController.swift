import AppKit
import SwiftUI

@MainActor
final class OverlayPanelController {
  private let panel: EviePanel
  private let viewModel: OverlayViewModel
  private let panelWidth: CGFloat = 576

  init(viewModel: OverlayViewModel) {
    self.viewModel = viewModel
    panel = EviePanel(
      contentRect: NSRect(x: 0, y: 0, width: panelWidth, height: 104),
      styleMask: [.borderless, .nonactivatingPanel, .fullSizeContentView],
      backing: .buffered,
      defer: true
    )

    panel.backgroundColor = .clear
    panel.isOpaque = false
    panel.hasShadow = false
    panel.level = .floating
    panel.isFloatingPanel = true
    panel.hidesOnDeactivate = false
    panel.becomesKeyOnlyIfNeeded = true
    panel.animationBehavior = .none
    panel.collectionBehavior = [
      .canJoinAllSpaces,
      .fullScreenAuxiliary,
      .transient,
      .ignoresCycle,
    ]
    panel.contentViewController = NSHostingController(
      rootView: EvieOverlayView(viewModel: viewModel)
    )

    viewModel.onLayoutInvalidated = { [weak self] in
      self?.synchronizePresentation()
    }
    viewModel.onDismissRequested = { [weak self] in
      self?.hide()
    }
    updateGeometry()
  }

  var isVisible: Bool {
    panel.isVisible
  }

  func showPassive() {
    updateGeometry(reselectScreen: true)
    panel.orderFrontRegardless()
  }

  func showQuickText() {
    updateGeometry(reselectScreen: true)
    panel.makeKeyAndOrderFront(nil)
  }

  func hide() {
    panel.orderOut(nil)
  }

  func togglePassive() {
    if isVisible {
      hide()
    } else {
      viewModel.presentReadyState()
      showPassive()
    }
  }
}

extension OverlayPanelController {
  fileprivate func synchronizePresentation() {
    updateGeometry()
    if !viewModel.isQuickTextEntryPresented, panel.isKeyWindow {
      panel.resignKey()
      panel.orderFrontRegardless()
    }
  }

  fileprivate func updateGeometry(reselectScreen: Bool = false) {
    let currentScreen = panel.screen
    let screen =
      reselectScreen || currentScreen == nil
      ? screenUnderPointer() ?? NSScreen.main ?? NSScreen.screens.first
      : currentScreen
    guard let screen else {
      return
    }

    let height = desiredHeight
    let visibleFrame = screen.visibleFrame
    let origin = NSPoint(
      x: visibleFrame.midX - panelWidth / 2,
      y: visibleFrame.minY + 18
    )
    panel.setFrame(
      NSRect(x: origin.x, y: origin.y, width: panelWidth, height: height),
      display: panel.isVisible,
      animate: false
    )
  }

  fileprivate var desiredHeight: CGFloat {
    if viewModel.isQuickTextEntryPresented {
      return 104
    }

    guard !viewModel.artifacts.isEmpty else {
      return 104
    }

    let expandedCount = viewModel.artifacts.lazy.filter(\.isExpanded).count
    let estimatedCards = CGFloat(viewModel.artifacts.count * 118 + expandedCount * 92)
    return min(620, 104 + estimatedCards)
  }

  fileprivate func screenUnderPointer() -> NSScreen? {
    let pointer = NSEvent.mouseLocation
    return NSScreen.screens.first { NSMouseInRect(pointer, $0.frame, false) }
  }
}

private final class EviePanel: NSPanel {
  override var canBecomeKey: Bool { true }
  override var canBecomeMain: Bool { false }
}
