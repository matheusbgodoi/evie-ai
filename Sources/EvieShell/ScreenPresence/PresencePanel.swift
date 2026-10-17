import AppKit
import QuartzCore

/// A transparent, click-through window that covers one display and carries
/// the presence layers drawn on it.
///
/// It never takes a click, a key or focus: everything under it keeps working
/// exactly as if it were not there, which is the only way an indicator can be
/// on screen while Evie — or the user — clicks through it. It sits at the
/// screen-saver level, above full-screen apps, and joins every Space, so the
/// glow cannot be left behind on a Space the user switched away from.
///
/// One exists per display only while the indicator is up. Hiding the
/// indicator closes the panel, which takes its whole layer tree with it: idle
/// means no windows and nothing for the render server to composite.
final class PresencePanel: NSPanel {
  let displayID: CGDirectDisplayID
  let glow = GlowLayer()
  let reticle = ReticleLayer()
  let highlight = HighlightLayer()
  let cursor = GhostCursorLayer()
  /// The flipped root every layer above draws in, so a display-local point
  /// with a top-left origin can be used as it comes.
  let root = CALayer()
  private let host = PresenceHostView()

  init(screen: NSScreen, displayID: CGDirectDisplayID) {
    self.displayID = displayID
    super.init(
      contentRect: screen.frame,
      styleMask: [.borderless, .nonactivatingPanel],
      backing: .buffered,
      defer: false
    )
    level = .screenSaver
    collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary, .ignoresCycle]
    ignoresMouseEvents = true
    isOpaque = false
    backgroundColor = .clear
    hasShadow = false
    animationBehavior = .none
    isReleasedWhenClosed = false
    hidesOnDeactivate = false

    // Layer-hosting rather than layer-backed: the view owns no drawing of its
    // own, and AppKit leaves a hosted layer tree alone.
    root.isGeometryFlipped = true
    host.layer = root
    host.wantsLayer = true
    contentView = host
    setFrame(screen.frame, display: false)

    root.frame = CGRect(origin: .zero, size: screen.frame.size)
    for layer in [glow, reticle, highlight, cursor] as [CALayer] {
      layer.frame = root.bounds
      root.addSublayer(layer)
    }
    let appearance = host.effectiveAppearance
    let radius = CGDisplayIsBuiltin(displayID) != 0 ? Self.builtInCornerRadius : 0
    glow.layOut(in: root.bounds, cornerRadius: radius, appearance: appearance)
    reticle.setColours(in: appearance)
    highlight.setColours(in: appearance)
    cursor.setColours(in: appearance)
  }

  override var canBecomeKey: Bool { false }
  override var canBecomeMain: Bool { false }

  /// The corner radius of the built-in panel's glass. An estimate, chosen by
  /// eye against screenshots of this Mac's display (Mac17,2, 2026-10-16): no
  /// API reports it. External displays have square corners.
  private static let builtInCornerRadius: CGFloat = 10

  var appearanceForLayers: NSAppearance {
    host.effectiveAppearance
  }

  /// Calls back once the layers added so far have been on screen for two
  /// display refreshes — the evidence that the render server has composited
  /// them, not merely accepted them — or with `false` when the display does
  /// not refresh within `timeout` (asleep, or mid-reconfiguration).
  func waitForComposite(timeout: Duration = .milliseconds(500)) async -> Bool {
    CATransaction.flush()
    return await host.waitForTicks(2, timeout: timeout)
  }
}

/// The panel's content view: a bare layer host that counts display refreshes.
private final class PresenceHostView: NSView {
  private var link: CADisplayLink?
  private var ticksLeft = 0
  private var waiter: CheckedContinuation<Bool, Never>?
  /// Which wait a timeout belongs to, so the timeout of a wait that already
  /// finished cannot end a later one.
  private var generation = 0

  override var isFlipped: Bool { true }

  /// Never the target of a click, even if the window were to accept one.
  override func hitTest(_ point: NSPoint) -> NSView? { nil }

  func waitForTicks(_ count: Int, timeout: Duration) async -> Bool {
    finish(false)
    generation += 1
    let current = generation
    return await withCheckedContinuation { continuation in
      waiter = continuation
      ticksLeft = count
      let link = displayLink(target: self, selector: #selector(tick))
      link.add(to: .main, forMode: .common)
      self.link = link
      Task { @MainActor [weak self] in
        try? await Task.sleep(for: timeout)
        guard let self, self.generation == current else { return }
        self.finish(false)
      }
    }
  }

  @objc private func tick(_ link: CADisplayLink) {
    ticksLeft -= 1
    if ticksLeft <= 0 {
      finish(true)
    }
  }

  private func finish(_ composited: Bool) {
    link?.invalidate()
    link = nil
    waiter?.resume(returning: composited)
    waiter = nil
  }
}
