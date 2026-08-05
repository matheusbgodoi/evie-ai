import AppKit
import EvieCore
import SwiftUI

@MainActor
final class OverlayPanelController: NSObject {
  private let panel: EviePanel
  private let viewModel: OverlayViewModel
  private let chrome: OverlayChromeModel
  private let preferencesStore: EviePreferencesStore
  private var appearance: EvieAppearancePreferences
  private var measuredContentHeight: CGFloat = EvieOverlayGeometry.minimumHeight
  private var widthAtDragStart: CGFloat?
  private var isApplyingGeometry = false

  init(
    viewModel: OverlayViewModel,
    chrome: OverlayChromeModel,
    appearance: EvieAppearancePreferences,
    preferencesStore: EviePreferencesStore
  ) {
    self.viewModel = viewModel
    self.chrome = chrome
    self.appearance = appearance
    self.preferencesStore = preferencesStore

    panel = EviePanel(
      contentRect: NSRect(
        x: 0,
        y: 0,
        width: appearance.resolvedOverlayWidth,
        height: EvieOverlayGeometry.minimumHeight
      ),
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
    panel.isMovableByWindowBackground = false
    panel.collectionBehavior = [
      .canJoinAllSpaces,
      .fullScreenAuxiliary,
      .transient,
      .ignoresCycle,
    ]
    panel.contentViewController = NSHostingController(
      rootView: EvieOverlayView(viewModel: viewModel, chrome: chrome)
    )

    super.init()
    panel.delegate = self

    viewModel.onLayoutInvalidated = { [weak self] in
      self?.synchronizePresentation()
    }
    viewModel.onDismissRequested = { [weak self] in
      self?.hide()
    }
    chrome.onMeasuredHeight = { [weak self] height in
      self?.applyMeasuredHeight(height)
    }
    chrome.onWidthDrag = { [weak self] travel in
      self?.dragWidth(totalTravel: travel)
    }
    chrome.onWidthCommit = { [weak self] in
      self?.finishWidthDrag()
    }
    chrome.onResetPlacement = { [weak self] in
      self?.resetPlacement()
    }

    updateGeometry()
  }

  var isVisible: Bool {
    panel.isVisible
  }

  func showPassive() {
    updateGeometry(reselectScreen: true)
    chrome.setVisible(true)
    panel.orderFrontRegardless()
  }

  func showQuickText() {
    updateGeometry(reselectScreen: true)
    chrome.setVisible(true)
    panel.makeKeyAndOrderFront(nil)
  }

  /// The motion gate is lowered *before* the window leaves the screen.
  ///
  /// Ordering a window out does not stop a SwiftUI timeline: measured on this
  /// Mac, an overlay hidden with `orderOut` kept redrawing at 55 frames per
  /// second and burned 2.5% of a core invisibly. Only removing the timeline from
  /// the view tree actually stops it.
  func hide() {
    chrome.setVisible(false)
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

  /// Adopts an appearance edited elsewhere, typically the settings window.
  ///
  /// The panel is repositioned immediately so a width change is visible while the
  /// slider is still moving.
  func applyAppearance(_ appearance: EvieAppearancePreferences) {
    guard appearance != self.appearance else {
      return
    }
    self.appearance = appearance
    chrome.apply(appearance)
    updateGeometry()
  }

  /// Puts the overlay back where it started: bottom centre, original width.
  func resetPlacement() {
    appearance.resetPlacement()
    chrome.apply(appearance)
    persistAppearance()
    updateGeometry(reselectScreen: true)
  }
}

extension OverlayPanelController {
  fileprivate func synchronizePresentation() {
    updateGeometry()
    if viewModel.isQuickTextEntryPresented, panel.isVisible, !panel.isKeyWindow {
      panel.makeKeyAndOrderFront(nil)
    } else if !viewModel.isQuickTextEntryPresented, panel.isKeyWindow {
      panel.resignKey()
      panel.orderFrontRegardless()
    }
  }

  /// The SwiftUI content reports the height it actually drew. The window follows
  /// that number instead of estimating, which is what stops the glass edge and
  /// the scroll fade from being clipped mid-gradient.
  fileprivate func applyMeasuredHeight(_ height: CGFloat) {
    guard height.isFinite, height > 0 else {
      return
    }
    guard abs(height - measuredContentHeight) > 0.5 else {
      return
    }
    measuredContentHeight = height
    updateGeometry()
  }

  /// The handle reports total travel since the gesture began, so the starting
  /// width is captured here on the first change and released on commit.
  fileprivate func dragWidth(totalTravel: CGFloat) {
    guard let screen = currentScreenFrame() else {
      return
    }
    let baseWidth = widthAtDragStart ?? appearance.resolvedOverlayWidth
    widthAtDragStart = baseWidth

    let resized = EvieOverlayGeometry.resizedFrame(
      current: panel.frame,
      width: baseWidth + totalTravel,
      screen: screen
    )
    guard resized != panel.frame else {
      return
    }

    appearance.overlayWidth = resized.width
    // Resizing pins the window in place: it would be surprising for the overlay
    // to jump back to the centre the next time it is summoned.
    appearance.captureOrigin(of: resized)
    chrome.apply(appearance)
    setFrame(resized)
  }

  fileprivate func finishWidthDrag() {
    widthAtDragStart = nil
    persistAppearance()
  }

  fileprivate func recordMovedFrame() {
    guard !isApplyingGeometry, panel.isVisible else {
      return
    }
    appearance.captureOrigin(of: panel.frame)
    chrome.apply(appearance)
    persistAppearance()
  }

  fileprivate func persistAppearance() {
    var preferences = preferencesStore.load()
    preferences.appearance = appearance
    do {
      try preferencesStore.save(preferences)
    } catch {
      // Geometry is a convenience: failing to record it must never interrupt a
      // conversation, and the window on screen is already correct.
      NSLog("Evie: could not save the overlay placement (%@)", String(describing: error))
    }
  }

  fileprivate func updateGeometry(reselectScreen: Bool = false) {
    let screens = NSScreen.screens.map(\.visibleFrame)
    guard !screens.isEmpty else {
      return
    }
    let pointerScreen =
      reselectScreen || panel.screen == nil
      ? screenUnderPointer()?.visibleFrame ?? NSScreen.main?.visibleFrame
      : panel.screen?.visibleFrame

    let frame = EvieOverlayGeometry.resolveFrame(
      preferences: appearance,
      contentHeight: measuredContentHeight,
      screens: screens,
      pointerScreen: pointerScreen
    )
    setFrame(frame)
  }

  fileprivate func setFrame(_ frame: CGRect) {
    guard frame != panel.frame else {
      return
    }
    isApplyingGeometry = true
    panel.setFrame(frame, display: panel.isVisible, animate: false)
    isApplyingGeometry = false
  }

  fileprivate func currentScreenFrame() -> CGRect? {
    panel.screen?.visibleFrame
      ?? screenUnderPointer()?.visibleFrame
      ?? NSScreen.main?.visibleFrame
  }

  fileprivate func screenUnderPointer() -> NSScreen? {
    let pointer = NSEvent.mouseLocation
    return NSScreen.screens.first { NSMouseInRect(pointer, $0.frame, false) }
  }
}

extension OverlayPanelController: NSWindowDelegate {
  /// Another window covered the overlay. Same reasoning as `hide()`: what is not
  /// on screen must not be animating.
  func windowDidChangeOcclusionState(_ notification: Notification) {
    chrome.setVisible(panel.isVisible && panel.occlusionState.contains(.visible))
  }

  /// AppKit finished a `performDrag`. Whatever the user pointed at is now the
  /// saved position; a programmatic reposition is ignored so resetting the
  /// placement cannot immediately re-save itself as custom.
  func windowDidMove(_ notification: Notification) {
    recordMovedFrame()
  }
}

private final class EviePanel: NSPanel {
  override var canBecomeKey: Bool { true }
  override var canBecomeMain: Bool { false }
}
