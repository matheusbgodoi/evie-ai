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
  private var isDismissing = false

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
    // The presentation animates this layer's opacity and scale, so it has to be
    // layer-backed and has to scale about its own centre.
    panel.contentView?.wantsLayer = true
    panel.contentView?.layer?.anchorPoint = CGPoint(x: 0.5, y: 0.5)

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

  /// What state the window and its animated layer are actually in.
  var diagnostics: String {
    let layer = contentLayer
    return String(
      format: "visível=%@ alpha=%.2f opacidade da camada=%.2f escala=%.2f animando=%@",
      panel.isVisible ? "sim" : "não",
      panel.alphaValue,
      Double(layer?.opacity ?? -1),
      Double((layer?.value(forKeyPath: "transform.scale") as? CGFloat) ?? -1),
      (layer?.animation(forKey: Self.transitionKey) != nil) ? "sim" : "não"
    )
  }

  func showPassive() {
    present(makingKey: false)
  }

  func showQuickText() {
    present(makingKey: true)
  }

  /// Arrives the way Spotlight does: a short scale from just under full size,
  /// carried by a fade, easing out. The whole thing is under two tenths of a
  /// second — long enough to read as motion, short enough never to be in the way
  /// of typing.
  private func present(makingKey: Bool) {
    cancelDismissal()
    let wasVisible = panel.isVisible
    updateGeometry(reselectScreen: true)
    chrome.setVisible(true)

    guard let layer = contentLayer, Self.prefersMotion, !wasVisible else {
      panel.alphaValue = 1
      order(makingKey: makingKey)
      return
    }

    CATransaction.begin()
    CATransaction.setDisableActions(true)
    layer.opacity = 0
    layer.transform = CATransform3DMakeScale(Self.entryScale, Self.entryScale, 1)
    CATransaction.commit()

    panel.alphaValue = 1
    order(makingKey: makingKey)
    animate(layer: layer, toOpacity: 1, scale: 1, duration: 0.17, easeOut: true)
  }

  /// Leaves faster than it arrives, which is what makes a dismissal feel like a
  /// dismissal rather than a delay.
  ///
  /// The motion gate is lowered first. Ordering a window out does not stop a
  /// SwiftUI timeline — measured on this Mac, an overlay hidden with `orderOut`
  /// kept redrawing at 55 frames per second and burned 2.5% of a core invisibly.
  func hide() {
    chrome.setVisible(false)

    guard let layer = contentLayer, Self.prefersMotion, panel.isVisible else {
      cancelDismissal()
      panel.orderOut(nil)
      return
    }

    isDismissing = true
    CATransaction.begin()
    CATransaction.setCompletionBlock { [weak self] in
      MainActor.assumeIsolated {
        guard let self, self.isDismissing else {
          return
        }
        self.isDismissing = false
        self.panel.orderOut(nil)
        self.resetContentLayer()
      }
    }
    animate(layer: layer, toOpacity: 0, scale: Self.exitScale, duration: 0.11, easeOut: false)
    CATransaction.commit()
  }

  private func order(makingKey: Bool) {
    if makingKey {
      panel.makeKeyAndOrderFront(nil)
    } else {
      panel.orderFrontRegardless()
    }
  }

  /// A dismissal in flight is abandoned the moment the overlay is summoned again,
  /// so a quick hide-then-show never leaves the window half faded or ordered out
  /// underneath a fresh presentation.
  private func cancelDismissal() {
    guard isDismissing else {
      return
    }
    isDismissing = false
    resetContentLayer()
  }

  private func resetContentLayer() {
    guard let layer = contentLayer else {
      return
    }
    layer.removeAnimation(forKey: Self.transitionKey)
    CATransaction.begin()
    CATransaction.setDisableActions(true)
    layer.opacity = 1
    layer.transform = CATransform3DIdentity
    CATransaction.commit()
  }

  private func animate(
    layer: CALayer,
    toOpacity opacity: Float,
    scale: CGFloat,
    duration: CFTimeInterval,
    easeOut: Bool
  ) {
    let group = CAAnimationGroup()
    let fade = CABasicAnimation(keyPath: "opacity")
    fade.fromValue = layer.opacity
    fade.toValue = opacity
    let zoom = CABasicAnimation(keyPath: "transform.scale")
    zoom.fromValue = (layer.value(forKeyPath: "transform.scale") as? CGFloat) ?? 1
    zoom.toValue = scale
    group.animations = [fade, zoom]
    group.duration = duration
    group.timingFunction = CAMediaTimingFunction(name: easeOut ? .easeOut : .easeIn)
    group.fillMode = .forwards

    CATransaction.begin()
    CATransaction.setDisableActions(true)
    layer.opacity = opacity
    layer.transform = CATransform3DMakeScale(scale, scale, 1)
    CATransaction.commit()
    layer.add(group, forKey: Self.transitionKey)
  }

  private var contentLayer: CALayer? {
    panel.contentView?.layer
  }

  /// Reduce Motion removes the movement but keeps the window; a preference about
  /// animation must never cost someone the feature.
  private static var prefersMotion: Bool {
    !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
  }

  private static let entryScale: CGFloat = 0.93
  private static let exitScale: CGFloat = 0.97
  private static let transitionKey = "evie.presentation"

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
