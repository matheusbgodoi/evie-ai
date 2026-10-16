import AppKit
import EvieCore
import SwiftUI

/// What the status pill shows. A value, so the controller can tell a real
/// change of state (announced to VoiceOver) from the same state set again.
struct PresencePillContent: Equatable {
  enum Mark: Equatable {
    case seeing, observing, acting, typing, paused, stopped, done, failed
  }

  var mark: Mark
  var title: String
  /// Where the brain runs ("no PC" / "no Mac"), when the caller knows.
  var detail: String?
  var showsStop = true
  var showsContinue = false
  /// Shown only while Esc is actually registered: a keycap that does nothing
  /// would be a lie on the one control that has to work.
  var showsEscape = false
}

/// The pill's state, observed by its SwiftUI view. An object rather than view
/// state because this toolchain has no `@State` (see `AGENTS.md`).
@MainActor
final class PresencePillModel: ObservableObject {
  @Published var content = PresencePillContent(mark: .seeing, title: ScreenPresenceCopy.seeing)
  var onStop: () -> Void = {}
  var onContinue: () -> Void = {}
}

/// The small floating status line at the top of the display Evie is working
/// on: what she is doing, Parar, and the esc keycap.
///
/// It lives in its own non-activating panel, apart from the click-through
/// glow, because it is the one part of the indicator that takes clicks — and
/// it must take them without activating Evie or taking focus from the app the
/// user is in.
@MainActor
final class PresencePillController {
  let model = PresencePillModel()
  private var panel: PillPanel?
  private var edge: Edge = .top
  private var exitWork: DispatchWorkItem?
  private var shrinkWork: DispatchWorkItem?

  private enum Edge { case top, bottom }

  /// Room around the pill for its shadow, which would otherwise be cut off by
  /// the window edge.
  private static let margin: CGFloat = 32

  /// Shows `content` on `screen`, keeping clear of `target` (display-local,
  /// top-left points). Enters the first time; afterwards only the text and
  /// the width change, and the pill moves only if the target needs it to.
  func show(_ content: PresencePillContent, on screen: NSScreen, avoiding target: CGRect? = nil) {
    exitWork?.cancel()
    exitWork = nil
    let changedState = content != model.content
    model.content = content

    let panel = self.panel ?? makePanel()
    let entering = !panel.isVisible || panel.screen != screen
    let pillSize = panel.pillSize
    let usable = Self.displayLocal(screen.visibleFrame, on: screen)
    let local = ScreenPresenceLayout.pillFrame(size: pillSize, usableArea: usable, avoiding: target)
    let newEdge: Edge = local.minY > usable.midY ? .bottom : .top
    let frame = Self.appKit(local, on: screen).insetBy(dx: -Self.margin, dy: -Self.margin)

    if entering {
      panel.setFrame(frame, display: true)
      panel.orderFrontRegardless()
      edge = newEdge
      panel.enter(fromAbove: newEdge == .top)
    } else if newEdge != edge {
      edge = newEdge
      NSAnimationContext.runAnimationGroup { context in
        context.duration = PresenceMotion.reducesMotion ? 0 : 0.35
        context.timingFunction = PresenceMotion.easeInOut
        panel.animator().setFrame(frame, display: true)
      }
    } else {
      resize(panel, to: frame)
    }
    if changedState || entering {
      Self.announce(content.title)
    }
  }

  /// Width changes are animated inside the view, so the window only has to be
  /// big enough for the wider of the two texts while that happens: it grows at
  /// once and shrinks after the 0.3 s spring has settled, instead of cutting
  /// off the ends of a pill that is still getting narrower.
  private func resize(_ panel: PillPanel, to frame: NSRect) {
    shrinkWork?.cancel()
    shrinkWork = nil
    guard frame.width < panel.frame.width else {
      panel.setFrame(frame, display: true)
      return
    }
    let wide = NSRect(
      x: frame.midX - panel.frame.width / 2, y: frame.minY, width: panel.frame.width,
      height: frame.height)
    panel.setFrame(wide, display: true)
    let work = DispatchWorkItem { [weak panel] in
      panel?.setFrame(frame, display: true)
    }
    shrinkWork = work
    DispatchQueue.main.asyncAfter(deadline: .now() + 0.4, execute: work)
  }

  /// Leaves over 150 ms, then closes the panel, so nothing is left on screen
  /// or in the tree.
  func hide() {
    guard let panel, exitWork == nil else {
      return
    }
    panel.exit(towardsTop: edge == .top)
    let work = DispatchWorkItem { [weak self] in
      self?.close()
    }
    exitWork = work
    DispatchQueue.main.asyncAfter(deadline: .now() + 0.15, execute: work)
  }

  /// Closes at once, without the exit animation.
  func close() {
    exitWork?.cancel()
    exitWork = nil
    shrinkWork?.cancel()
    shrinkWork = nil
    panel?.close()
    panel = nil
  }

  private func makePanel() -> PillPanel {
    let panel = PillPanel(model: model)
    self.panel = panel
    return panel
  }

  /// VoiceOver hears every change of state, not only the ones somebody is
  /// looking at: the indicator's promise does not depend on sight.
  static func announce(_ text: String) {
    NSAccessibility.post(
      element: NSApp as Any,
      notification: .announcementRequested,
      userInfo: [
        .announcement: text,
        .priority: NSAccessibilityPriorityLevel.high.rawValue,
      ]
    )
  }

  /// An AppKit rect on `screen` in that display's top-left local points.
  static func displayLocal(_ rect: NSRect, on screen: NSScreen) -> CGRect {
    CGRect(
      x: rect.minX - screen.frame.minX,
      y: screen.frame.maxY - rect.maxY,
      width: rect.width,
      height: rect.height
    )
  }

  /// The inverse: a display-local top-left rect as a global AppKit rect.
  static func appKit(_ rect: CGRect, on screen: NSScreen) -> NSRect {
    NSRect(
      x: screen.frame.minX + rect.minX,
      y: screen.frame.maxY - rect.maxY,
      width: rect.width,
      height: rect.height
    )
  }
}

/// The pill's window: borderless, non-activating, never key, above the glow.
private final class PillPanel: NSPanel {
  private let hosting: NSHostingView<PresencePillView>
  private let container = NSView()
  private static let margin: CGFloat = 32

  init(model: PresencePillModel) {
    hosting = NSHostingView(rootView: PresencePillView(model: model))
    super.init(
      contentRect: NSRect(x: 0, y: 0, width: 400, height: 100),
      styleMask: [.borderless, .nonactivatingPanel],
      backing: .buffered,
      defer: false
    )
    level = NSWindow.Level(rawValue: NSWindow.Level.screenSaver.rawValue + 1)
    collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary, .ignoresCycle]
    isOpaque = false
    backgroundColor = .clear
    hasShadow = false
    animationBehavior = .none
    isReleasedWhenClosed = false
    hidesOnDeactivate = false
    becomesKeyOnlyIfNeeded = true
    isFloatingPanel = true

    container.wantsLayer = true
    hosting.translatesAutoresizingMaskIntoConstraints = false
    container.addSubview(hosting)
    NSLayoutConstraint.activate([
      hosting.leadingAnchor.constraint(equalTo: container.leadingAnchor),
      hosting.trailingAnchor.constraint(equalTo: container.trailingAnchor),
      hosting.topAnchor.constraint(equalTo: container.topAnchor),
      hosting.bottomAnchor.constraint(equalTo: container.bottomAnchor),
    ])
    contentView = container
  }

  override var canBecomeKey: Bool { false }
  override var canBecomeMain: Bool { false }

  /// The pill's own size, without the shadow margin, for the current text.
  var pillSize: CGSize {
    let fitting = NSHostingView(rootView: PresencePillView(model: hosting.rootView.model, measuring: true))
      .fittingSize
    return CGSize(width: ceil(fitting.width), height: ceil(fitting.height))
  }

  /// Drops in 8 points from the edge it sits against while settling from
  /// 0.96 and fading in, on a critically damped spring.
  func enter(fromAbove: Bool) {
    guard let layer = container.layer else {
      return
    }
    layer.removeAllAnimations()
    PresenceMotion.set { layer.opacity = 1 }
    let fade = CABasicAnimation(keyPath: "opacity")
    fade.fromValue = 0
    fade.toValue = 1
    fade.duration = PresenceMotion.reducesMotion ? 0.15 : 0.2
    fade.timingFunction = PresenceMotion.easeOut
    layer.add(fade, forKey: "enter.opacity")
    guard !PresenceMotion.reducesMotion else {
      return
    }
    let spring = CASpringAnimation(perceptualDuration: 0.3, bounce: 0)
    spring.keyPath = "transform"
    spring.fromValue = Self.offsetTransform(in: container.bounds, dy: fromAbove ? 8 : -8, scale: 0.96)
    spring.toValue = CATransform3DIdentity
    spring.duration = spring.settlingDuration
    layer.add(spring, forKey: "enter.transform")
  }

  /// Leaves the way it came, faster than it arrived.
  func exit(towardsTop: Bool) {
    guard let layer = container.layer else {
      return
    }
    let current = layer.presentation()?.opacity ?? 1
    PresenceMotion.set { layer.opacity = 0 }
    let fade = CABasicAnimation(keyPath: "opacity")
    fade.fromValue = current
    fade.toValue = 0
    fade.duration = 0.15
    fade.timingFunction = PresenceMotion.easeOut
    layer.add(fade, forKey: "enter.opacity")
    guard !PresenceMotion.reducesMotion else {
      return
    }
    let slide = CABasicAnimation(keyPath: "transform")
    slide.fromValue = CATransform3DIdentity
    slide.toValue = Self.offsetTransform(in: container.bounds, dy: towardsTop ? 6 : -6, scale: 0.98)
    slide.duration = 0.15
    slide.timingFunction = PresenceMotion.easeOut
    slide.fillMode = .forwards
    slide.isRemovedOnCompletion = false
    layer.add(slide, forKey: "enter.transform")
  }

  /// A transform about the layer's centre. A layer-backed view's layer is
  /// anchored at its bottom-left corner, so scaling it as it is would shrink
  /// the pill towards that corner.
  private static func offsetTransform(in bounds: CGRect, dy: CGFloat, scale: CGFloat) -> CATransform3D {
    var transform = CATransform3DMakeTranslation(bounds.midX, bounds.midY + dy, 0)
    transform = CATransform3DScale(transform, scale, scale, 1)
    return CATransform3DTranslate(transform, -bounds.midX, -bounds.midY, 0)
  }
}

/// The pill itself.
struct PresencePillView: View {
  @ObservedObject var model: PresencePillModel
  /// True for the copy measured off screen to size the window, which must not
  /// carry the window's flexible frame.
  var measuring = false

  @Environment(\.accessibilityReduceMotion) private var reduceMotion
  @Environment(\.colorScheme) private var colorScheme

  private var content: PresencePillContent { model.content }

  var body: some View {
    let pill = GlassSurface(
      cornerRadius: 20,
      material: .hudWindow,
      contentPadding: EdgeInsets(top: 8, leading: 14, bottom: 8, trailing: 8),
      tint: Color(nsColor: tint)
    ) {
      HStack(spacing: 10) {
        PresenceDot(mark: content.mark)
          .frame(width: 18, height: 8)
          .accessibilityHidden(true)

        HStack(spacing: 6) {
          Text(content.title)
            .font(.system(size: 13, weight: .semibold))
            .lineLimit(1)
            .id(content.title)
            .transition(.blurReplace)
          if let detail = content.detail {
            Text(detail)
              .font(.system(size: 12))
              .foregroundStyle(.secondary)
              .lineLimit(1)
          }
        }
        .fixedSize()

        HStack(spacing: 6) {
          if content.showsContinue {
            PresencePillButton(
              title: "Continuar", systemImage: "play.fill", tint: tint, style: .filled,
              action: model.onContinue
            )
            .fixedSize()
          }
          if content.showsStop {
            PresencePillButton(
              title: "Parar", systemImage: "stop.fill", tint: tint,
              style: content.showsContinue ? .subtle : .filled, action: model.onStop
            )
            // Without this SwiftUI hands the button every spare point and the
            // capsule stretches far past its label.
            .fixedSize()
          }
          if content.showsEscape {
            EscapeKeycap()
          }
        }
      }
      .frame(height: 24)
    }
    .accessibilityElement(children: .contain)
    .accessibilityLabel(content.title)
    .animation(reduceMotion ? .easeOut(duration: 0.15) : .spring(duration: 0.3, bounce: 0), value: content)

    if measuring {
      pill.fixedSize()
    } else {
      pill.frame(maxWidth: .infinity, maxHeight: .infinity)
    }
  }

  private var tint: NSColor {
    switch content.mark {
    case .seeing, .observing: EviePresenceTint.seeing
    case .acting, .typing: EviePresenceTint.acting
    case .paused, .stopped, .failed: EviePresenceTint.paused
    case .done: EviePresenceTint.seeing
    }
  }
}

/// The esc keycap beside Parar.
private struct EscapeKeycap: View {
  var body: some View {
    Text("esc")
      .font(.system(size: 11, weight: .medium))
      .foregroundStyle(.secondary)
      .padding(.horizontal, 5)
      .padding(.vertical, 1)
      .overlay {
        RoundedRectangle(cornerRadius: 4, style: .continuous)
          .strokeBorder(Color.secondary.opacity(0.5), lineWidth: 0.75)
      }
      .accessibilityLabel("Esc também para")
  }
}

/// The 8-point state mark at the start of the pill. Its shape changes with
/// the state as well as its colour: a dot while looking, three travelling
/// dots while working, a solid dot with a ring while acting, two bars when
/// paused, a square when stopped, a tick when done.
private struct PresenceDot: NSViewRepresentable {
  var mark: PresencePillContent.Mark

  func makeNSView(context: Context) -> DotView { DotView() }

  func updateNSView(_ view: DotView, context: Context) {
    view.show(mark)
  }

  final class DotView: NSView {
    private let container = CALayer()
    private var mark: PresencePillContent.Mark?
    private var dots: [CALayer] = []

    override init(frame: NSRect) {
      super.init(frame: frame)
      layer = CALayer()
      wantsLayer = true
      layer?.addSublayer(container)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
      fatalError("init(coder:) has not been implemented")
    }

    override var isFlipped: Bool { true }
    override var intrinsicContentSize: NSSize { NSSize(width: 18, height: 8) }

    override func viewDidChangeEffectiveAppearance() {
      super.viewDidChangeEffectiveAppearance()
      if let mark {
        self.mark = nil
        show(mark)
      }
    }

    func show(_ mark: PresencePillContent.Mark) {
      guard mark != self.mark else {
        return
      }
      self.mark = mark
      PresenceWave.stop(on: dots)
      dots = []
      container.sublayers?.forEach { $0.removeFromSuperlayer() }
      let appearance = effectiveAppearance
      PresenceMotion.set {
        container.frame = CGRect(x: 0, y: 0, width: 18, height: 8)
        switch mark {
        case .seeing:
          container.addSublayer(Self.circle(x: 5, diameter: 8, colour: EviePresenceTint.seeing.resolved(in: appearance)))
        case .observing, .typing:
          let tint = mark == .observing ? EviePresenceTint.seeing : EviePresenceTint.acting
          dots = (0..<3).map { index in
            Self.circle(x: 0.75 + CGFloat(index) * 6, diameter: 4.5, colour: tint.resolved(in: appearance), y: 1.75)
          }
          dots.forEach(container.addSublayer)
        case .acting:
          let ring = CAShapeLayer()
          ring.path = CGPath(ellipseIn: CGRect(x: 5.5, y: 0.5, width: 7, height: 7), transform: nil)
          ring.fillColor = EviePresenceTint.acting.resolved(in: appearance)
          ring.strokeColor = EviePresenceTint.actingHalo.resolved(in: appearance, alpha: 0.5)
          ring.lineWidth = 3
          container.addSublayer(ring)
        case .paused:
          for x in [CGFloat(5), 10.5] {
            let bar = CALayer()
            bar.frame = CGRect(x: x, y: 0, width: 2.5, height: 8)
            bar.cornerRadius = 1
            bar.backgroundColor = EviePresenceTint.paused.resolved(in: appearance)
            container.addSublayer(bar)
          }
        case .stopped, .failed:
          let square = CALayer()
          square.frame = CGRect(x: 5.5, y: 0.5, width: 7, height: 7)
          square.cornerRadius = 1.5
          square.backgroundColor = EviePresenceTint.paused.resolved(in: appearance)
          container.addSublayer(square)
        case .done:
          let tick = CAShapeLayer()
          let path = CGMutablePath()
          path.move(to: CGPoint(x: 5, y: 4.2))
          path.addLine(to: CGPoint(x: 7.5, y: 6.8))
          path.addLine(to: CGPoint(x: 12.5, y: 1))
          tick.path = path
          tick.fillColor = nil
          tick.strokeColor = EviePresenceTint.seeing.resolved(in: appearance)
          tick.lineWidth = 1.8
          tick.lineCap = .round
          tick.lineJoin = .round
          container.addSublayer(tick)
        }
      }
      PresenceWave.start(on: dots)
    }

    override func removeFromSuperview() {
      PresenceWave.stop(on: dots)
      super.removeFromSuperview()
    }

    private static func circle(x: CGFloat, diameter: CGFloat, colour: CGColor, y: CGFloat = 0) -> CALayer {
      let dot = CALayer()
      dot.frame = CGRect(x: x, y: y, width: diameter, height: diameter)
      dot.cornerRadius = diameter / 2
      dot.backgroundColor = colour
      return dot
    }
  }
}

/// A capsule button for the pill, built in AppKit for what SwiftUI's `Button`
/// cannot give here: it takes the first click in a window that is never key,
/// without activating Evie, and it can see the event behind the click — so a
/// click that Evie herself posted (tagged `ScreenPresence.syntheticEventTag`)
/// is refused, and the agent can never press its own Parar or Continuar.
private struct PresencePillButton: NSViewRepresentable {
  enum Style { case filled, subtle }

  var title: String
  var systemImage: String
  var tint: NSColor
  var style: Style
  var action: () -> Void

  func makeNSView(context: Context) -> ButtonView { ButtonView() }

  func updateNSView(_ view: ButtonView, context: Context) {
    view.configure(title: title, systemImage: systemImage, tint: tint, style: style, action: action)
  }

  final class ButtonView: NSView {
    private let body = CALayer()
    private let glyph = CALayer()
    private let label = CATextLayer()
    private var action: () -> Void = {}
    private var configuration: (String, String, NSColor, Style)?
    private var isPressed = false
    private var isHovering = false
    private var trackingArea: NSTrackingArea?
    nonisolated(unsafe) private static let font = NSFont.systemFont(ofSize: 12, weight: .semibold)

    override init(frame: NSRect) {
      super.init(frame: frame)
      layer = CALayer()
      wantsLayer = true
      layer?.addSublayer(body)
      body.addSublayer(glyph)
      body.addSublayer(label)
      label.font = Self.font
      label.fontSize = Self.font.pointSize
      setAccessibilityElement(true)
      setAccessibilityRole(.button)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
      fatalError("init(coder:) has not been implemented")
    }

    override var isFlipped: Bool { true }

    override var intrinsicContentSize: NSSize {
      NSSize(width: 10 + 9 + 5 + textWidth + 11, height: 24)
    }

    private var textWidth: CGFloat {
      ceil(((configuration?.0 ?? "") as NSString).size(withAttributes: [.font: Self.font]).width)
    }

    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    override func updateTrackingAreas() {
      super.updateTrackingAreas()
      if let trackingArea {
        removeTrackingArea(trackingArea)
      }
      let area = NSTrackingArea(
        rect: bounds, options: [.mouseEnteredAndExited, .activeAlways, .inVisibleRect], owner: self)
      addTrackingArea(area)
      trackingArea = area
    }

    func configure(title: String, systemImage: String, tint: NSColor, style: Style, action: @escaping () -> Void) {
      self.action = action
      setAccessibilityLabel(title)
      let changed = configuration.map { $0.0 != title || $0.1 != systemImage || $0.2 != tint || $0.3 != style } ?? true
      guard changed else {
        return
      }
      configuration = (title, systemImage, tint, style)
      invalidateIntrinsicContentSize()
      needsLayout = true
    }

    override func layout() {
      super.layout()
      redraw()
    }

    override func viewDidChangeEffectiveAppearance() {
      super.viewDidChangeEffectiveAppearance()
      redraw()
    }

    private func redraw() {
      guard let (title, systemImage, tint, style) = configuration else {
        return
      }
      let appearance = effectiveAppearance
      let scale = window?.backingScaleFactor ?? 2
      let isDark = appearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua
      let fill = tint.resolved(in: appearance)
      // Dark ink on a light tint, white on a dark one: the bright dark-mode
      // amber cannot carry white text.
      let ink: NSColor =
        style == .filled
        ? (Self.isLight(fill) ? NSColor(white: 0.08, alpha: 0.92) : .white)
        : .labelColor
      PresenceMotion.set {
        body.frame = bounds
        body.cornerRadius = bounds.height / 2
        switch style {
        case .filled:
          body.backgroundColor = fill
        case .subtle:
          body.backgroundColor =
            (isDark ? NSColor.white : NSColor.black).withAlphaComponent(isHovering ? 0.16 : 0.09).cgColor
        }
        body.opacity = isHovering && style == .filled ? 0.9 : 1

        let symbolConfiguration = NSImage.SymbolConfiguration(pointSize: 8, weight: .bold)
          .applying(.init(hierarchicalColor: ink))
        if let image = NSImage(systemSymbolName: systemImage, accessibilityDescription: nil)?
          .withSymbolConfiguration(symbolConfiguration)
        {
          var rect = CGRect(origin: .zero, size: image.size)
          glyph.contents = image.cgImage(forProposedRect: &rect, context: nil, hints: nil)
          glyph.frame = CGRect(
            x: 10, y: ((bounds.height - image.size.height) / 2).rounded(), width: image.size.width,
            height: image.size.height)
        }
        glyph.contentsScale = scale
        label.string = title
        label.contentsScale = scale
        appearance.performAsCurrentDrawingAppearance {
          label.foregroundColor = ink.cgColor
        }
        let textHeight = ceil(Self.font.ascender - Self.font.descender)
        label.frame = CGRect(
          x: 10 + 9 + 5, y: ((bounds.height - textHeight) / 2).rounded(), width: textWidth + 2,
          height: textHeight)
      }
    }

    private static func isLight(_ colour: CGColor) -> Bool {
      guard let rgb = NSColor(cgColor: colour)?.usingColorSpace(.sRGB) else {
        return false
      }
      let luminance = 0.2126 * rgb.redComponent + 0.7152 * rgb.greenComponent + 0.0722 * rgb.blueComponent
      return luminance > 0.55
    }

    /// Whether Evie posted this event herself.
    private static func isSynthetic(_ event: NSEvent) -> Bool {
      event.cgEvent?.getIntegerValueField(.eventSourceUserData) == ScreenPresence.syntheticEventTag
    }

    override func mouseEntered(with event: NSEvent) {
      isHovering = true
      redraw()
    }

    override func mouseExited(with event: NSEvent) {
      isHovering = false
      redraw()
    }

    /// Pressed on the way down — the scale dip is the acknowledgement — and
    /// fired on the way up inside the button, so dragging off cancels.
    override func mouseDown(with event: NSEvent) {
      guard !Self.isSynthetic(event) else {
        return
      }
      isPressed = true
      setPressed(true)
    }

    override func mouseUp(with event: NSEvent) {
      guard isPressed else {
        return
      }
      isPressed = false
      setPressed(false)
      guard !Self.isSynthetic(event), bounds.contains(convert(event.locationInWindow, from: nil)) else {
        return
      }
      action()
    }

    override func accessibilityPerformPress() -> Bool {
      action()
      return true
    }

    private func setPressed(_ pressed: Bool) {
      let scale: CGFloat = pressed ? 0.95 : 1
      var transform = CATransform3DMakeTranslation(bounds.midX, bounds.midY, 0)
      transform = CATransform3DScale(transform, scale, scale, 1)
      transform = CATransform3DTranslate(transform, -bounds.midX, -bounds.midY, 0)
      PresenceMotion.ease(body, "transform", to: transform, duration: 0.1)
    }
  }
}
