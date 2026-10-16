import AppKit
import QuartzCore

/// The light around the edge of a display that says Evie is looking at it, or
/// acting on it.
///
/// Three parts: a 2 pt core stroke just inside the edge, a soft halo made from
/// a layer shadow cast by a wider, fainter stroke, and — once, when a capture
/// starts — a brighter band that sweeps around the edge like a shutter. The
/// halo is a shadow with an explicit `shadowPath` so the render server never
/// has to derive it from the layer's pixels.
final class GlowLayer: CALayer {
  /// What the edge is saying. Each style has its own shape as well as its own
  /// colour, so the state reads without colour.
  enum Style: Equatable {
    /// Full glow: a capture is happening now.
    case seeing
    /// Quiet glow at 35%: the agent can see this display between steps.
    case observing
    /// Solid amber line with a tight halo: Evie has the mouse or keyboard.
    case acting
    /// Gray, at half width: the user took over.
    case paused
  }

  private let halo = CAShapeLayer()
  private let core = CAShapeLayer()
  private let sweepMask = CAShapeLayer()
  private let sweepClip = CALayer()
  private var appearance = NSAppearance(named: .darkAqua)!
  private(set) var currentStyle: Style?

  /// How far the core stroke's centre sits inside the display edge: the 1.5 pt
  /// inset plus half the 2 pt line, so the whole line is on screen.
  private static let inset: CGFloat = 2.5

  override init() {
    super.init()
    for shape in [halo, core, sweepMask] {
      shape.fillColor = nil
      shape.lineJoin = .round
    }
    halo.shadowOffset = .zero
    sweepMask.strokeColor = NSColor.black.cgColor
    sweepMask.lineWidth = 7
    sweepClip.mask = sweepMask
    addSublayer(halo)
    addSublayer(core)
    addSublayer(sweepClip)
    opacity = 0
  }

  override init(layer: Any) {
    super.init(layer: layer)
  }

  @available(*, unavailable)
  required init?(coder: NSCoder) {
    fatalError("init(coder:) has not been implemented")
  }

  /// Sizes the glow to a display. `cornerRadius` follows the display's own
  /// rounded corners on the built-in panel, so the line runs parallel to the
  /// glass instead of being clipped by it.
  func layOut(in bounds: CGRect, cornerRadius: CGFloat, appearance: NSAppearance) {
    self.appearance = appearance
    PresenceMotion.set {
      frame = bounds
      let edge = bounds.insetBy(dx: Self.inset, dy: Self.inset)
      let path = CGPath(
        roundedRect: edge,
        cornerWidth: max(0, cornerRadius - Self.inset),
        cornerHeight: max(0, cornerRadius - Self.inset),
        transform: nil
      )
      for shape in [halo, core, sweepMask] {
        shape.frame = bounds
        shape.path = path
      }
      halo.shadowPath = path.copy(strokingWithWidth: 8, lineCap: .round, lineJoin: .round, miterLimit: 1)
      sweepClip.frame = bounds
    }
  }

  /// Moves to `style`. The first call fades the glow in; later calls
  /// cross-fade colour, width and opacity from wherever they are.
  func apply(_ style: Style, entering: Bool) {
    let previous = currentStyle
    currentStyle = style
    let look = Look(style, appearance: appearance)
    let duration = entering ? 0.12 : 0.16

    if entering || previous == nil {
      // Colour and width are set before the glow is visible, so the fade-in
      // is the only thing that moves.
      PresenceMotion.set { look.apply(core: core, halo: halo) }
      let fade = PresenceMotion.reducesMotion ? 0.15 : duration
      PresenceMotion.ease(self, "opacity", to: look.opacity, duration: fade)
      return
    }
    PresenceMotion.ease(core, "strokeColor", to: look.coreColour, duration: duration)
    PresenceMotion.ease(core, "lineWidth", to: look.coreWidth, duration: duration)
    PresenceMotion.ease(halo, "strokeColor", to: look.haloColour, duration: duration)
    PresenceMotion.ease(halo, "lineWidth", to: look.haloWidth, duration: duration)
    PresenceMotion.ease(halo, "shadowColor", to: look.shadowColour, duration: duration)
    PresenceMotion.ease(halo, "shadowRadius", to: look.shadowRadius, duration: duration)
    PresenceMotion.ease(halo, "shadowOpacity", to: look.shadowOpacity, duration: duration)
    PresenceMotion.ease(self, "opacity", to: look.opacity, duration: duration)
  }

  /// The one-time shutter: a bright band that travels once around the edge
  /// from top centre, next to the pill, in `duration`. Skipped under Reduce
  /// Motion, where the steady glow says the same thing without movement.
  func sweep(duration: Double) {
    guard !PresenceMotion.reducesMotion else {
      return
    }
    let gradient = CAGradientLayer()
    gradient.type = .conic
    // A square the size of the display's diagonal, centred on it, so rotating
    // it never brings a corner of the gradient into view.
    let side = hypot(bounds.width, bounds.height)
    gradient.bounds = CGRect(x: 0, y: 0, width: side, height: side)
    gradient.position = CGPoint(x: bounds.midX, y: bounds.midY)
    gradient.startPoint = CGPoint(x: 0.5, y: 0.5)
    // The band's head starts at the top edge; the layer is flipped, so up is
    // y = 0.
    gradient.endPoint = CGPoint(x: 0.5, y: 0)
    let head = NSColor.white.resolved(in: appearance, alpha: 0.95)
    let body = EviePresenceTint.seeing.resolved(in: appearance)
    let clear = EviePresenceTint.seeing.resolved(in: appearance, alpha: 0)
    // About 15% of the way round, fading in towards the head like a comet.
    gradient.colors = [clear, clear, body, head]
    gradient.locations = [0, 0.85, 0.985, 1]
    sweepClip.addSublayer(gradient)

    let turn = CABasicAnimation(keyPath: "transform.rotation.z")
    turn.fromValue = 0
    turn.toValue = 2 * Double.pi
    turn.duration = duration
    turn.timingFunction = PresenceMotion.easeInOut
    let fade = CABasicAnimation(keyPath: "opacity")
    fade.fromValue = 1
    fade.toValue = 0
    fade.beginTime = duration * 0.75
    fade.duration = duration * 0.25
    fade.fillMode = .forwards
    let group = CAAnimationGroup()
    group.animations = [turn, fade]
    group.duration = duration
    group.isRemovedOnCompletion = false
    group.fillMode = .forwards
    CATransaction.begin()
    // The band is removed once it has gone round, so nothing is left in the
    // tree for the render server to keep compositing.
    CATransaction.setCompletionBlock { gradient.removeFromSuperlayer() }
    gradient.add(group, forKey: "sweep")
    CATransaction.commit()
  }

  /// The success exit: the glow brightens for 150 ms, then fades over 300 ms.
  func flareAndFade() -> Double {
    let up = CABasicAnimation(keyPath: "opacity")
    up.fromValue = presentation()?.opacity ?? opacity
    up.toValue = 1
    up.duration = 0.15
    up.timingFunction = PresenceMotion.easeOut
    let down = CABasicAnimation(keyPath: "opacity")
    down.fromValue = 1
    down.toValue = 0
    down.beginTime = 0.15
    down.duration = 0.3
    down.timingFunction = PresenceMotion.easeOut
    let group = CAAnimationGroup()
    group.animations = [up, down]
    group.duration = 0.45
    PresenceMotion.set { opacity = 0 }
    add(group, forKey: "opacity")
    return group.duration
  }

  /// The stopped exit: gray, and gone in 200 ms. Exits are faster than
  /// entrances; once the user said stop, the indicator gets out of the way.
  func grayAndFade() -> Double {
    let gray = EviePresenceTint.paused.resolved(in: appearance)
    PresenceMotion.ease(core, "strokeColor", to: gray, duration: 0.12)
    PresenceMotion.ease(halo, "shadowColor", to: gray, duration: 0.12)
    PresenceMotion.ease(halo, "strokeColor", to: gray, duration: 0.12)
    PresenceMotion.ease(self, "opacity", to: Float(0), duration: 0.2)
    return 0.2
  }

  func fade(duration: Double) -> Double {
    PresenceMotion.ease(self, "opacity", to: Float(0), duration: duration)
    return duration
  }

  /// The values each style resolves to.
  private struct Look {
    let coreColour: CGColor
    let coreWidth: CGFloat
    let haloColour: CGColor
    let haloWidth: CGFloat
    let shadowColour: CGColor
    let shadowRadius: CGFloat
    let shadowOpacity: Float
    let opacity: Float

    init(_ style: Style, appearance: NSAppearance) {
      switch style {
      case .seeing, .observing:
        coreColour = EviePresenceTint.seeing.resolved(in: appearance)
        coreWidth = 2
        haloColour = EviePresenceTint.seeingDeep.resolved(in: appearance, alpha: 0.6)
        haloWidth = 8
        shadowColour = EviePresenceTint.seeing.resolved(in: appearance)
        shadowRadius = 18
        // Full strength: half the shadow falls off the display, and at the
        // spec's 0.8 the half that remains barely read over a light desktop
        // (seen in --presence-demo screenshots on 2026-10-16).
        shadowOpacity = 1
        // Static, never breathing: a slow oscillation over the whole edge of
        // the screen is a vestibular trigger, and between steps there is
        // nothing new to draw attention to.
        opacity = style == .seeing ? 1 : 0.35
      case .acting:
        coreColour = EviePresenceTint.acting.resolved(in: appearance)
        coreWidth = 2.5
        haloColour = EviePresenceTint.actingHalo.resolved(in: appearance, alpha: 0.4)
        haloWidth = 4
        shadowColour = EviePresenceTint.actingHalo.resolved(in: appearance)
        shadowRadius = 10
        shadowOpacity = 0.7
        opacity = 1
      case .paused:
        coreColour = EviePresenceTint.paused.resolved(in: appearance)
        coreWidth = 1
        haloColour = EviePresenceTint.paused.resolved(in: appearance, alpha: 0.3)
        haloWidth = 3
        shadowColour = EviePresenceTint.paused.resolved(in: appearance)
        shadowRadius = 8
        shadowOpacity = 0.5
        opacity = 0.8
      }
    }

    func apply(core: CAShapeLayer, halo: CAShapeLayer) {
      core.strokeColor = coreColour
      core.lineWidth = coreWidth
      halo.strokeColor = haloColour
      halo.lineWidth = haloWidth
      halo.shadowColor = shadowColour
      halo.shadowRadius = shadowRadius
      halo.shadowOpacity = shadowOpacity
    }
  }
}
