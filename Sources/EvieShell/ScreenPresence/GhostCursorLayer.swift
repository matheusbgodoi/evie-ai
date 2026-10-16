import AppKit
import EvieCore
import QuartzCore

/// Evie's own pointer: an amber arrow that travels to what she is about to
/// click, presses, and leaves a ripple where the click landed.
///
/// It never replaces the real pointer, which stays the user's. Drawn as a
/// shape rather than from the `cursorarrow` symbol so the tip is exactly the
/// layer's anchor point — the place the click goes is the place the tip
/// touches — at any backing scale.
final class GhostCursorLayer: CALayer {
  private let arrow = CAShapeLayer()
  private var appearance = NSAppearance(named: .darkAqua)!
  private(set) var isShown = false

  /// The arrow's height in points.
  private static let height: CGFloat = 22

  override init() {
    super.init()
    let path = Self.arrowPath(height: Self.height)
    arrow.path = path
    arrow.bounds = path.boundingBoxOfPath
    // The tip of the arrow is the path's origin; anchoring there means
    // `position` is where the click goes.
    arrow.anchorPoint = .zero
    arrow.lineWidth = 1.5
    arrow.lineJoin = .round
    arrow.strokeColor = NSColor.white.cgColor
    arrow.shadowOffset = .zero
    arrow.shadowRadius = 6
    arrow.shadowOpacity = 0.7
    arrow.shadowPath = path
    arrow.opacity = 0
    addSublayer(arrow)
  }

  override init(layer: Any) {
    super.init(layer: layer)
  }

  @available(*, unavailable)
  required init?(coder: NSCoder) {
    fatalError("init(coder:) has not been implemented")
  }

  func setColours(in appearance: NSAppearance) {
    self.appearance = appearance
    PresenceMotion.set {
      arrow.fillColor = EviePresenceTint.acting.resolved(in: appearance)
      arrow.shadowColor = EviePresenceTint.actingHalo.resolved(in: appearance)
    }
  }

  /// Travels to `point`. The first trip starts at `start`; later ones from
  /// wherever the arrow is now, so a new target mid-flight bends the path
  /// instead of restarting it. Returns how long the trip takes to settle,
  /// which is when the dwell before the press may begin.
  @discardableResult
  func travel(to point: CGPoint, from start: CGPoint) -> Double {
    if PresenceMotion.reducesMotion {
      PresenceMotion.set { arrow.position = point }
      PresenceMotion.ease(arrow, "opacity", to: Float(1), duration: 0.12)
      isShown = true
      return 0.12
    }
    let origin = isShown ? (arrow.presentation()?.position ?? arrow.position) : start
    if !isShown {
      PresenceMotion.set { arrow.position = start }
      PresenceMotion.ease(arrow, "opacity", to: Float(1), duration: 0.12)
    }
    isShown = true
    let travel = ScreenPresenceLayout.cursorTravel(from: origin, to: point)
    PresenceMotion.spring(arrow, "position.x", to: point.x, response: travel.responseX)
    PresenceMotion.spring(arrow, "position.y", to: point.y, response: travel.responseY)
    return max(travel.responseX, travel.responseY)
  }

  /// The press: the arrow dips to 0.9 over 100 ms and comes back, and a ring
  /// spreads from the tip. Called on the same frame the real click is posted,
  /// so what the user sees and what happens are one event.
  func press(rippleIn host: CALayer) {
    let tip = arrow.presentation()?.position ?? arrow.position
    let dip = CAKeyframeAnimation(keyPath: "transform.scale")
    dip.values = [1, 0.9, 1]
    dip.keyTimes = [0, 0.4, 1]
    dip.duration = 0.25
    dip.timingFunctions = [PresenceMotion.easeOut, PresenceMotion.easeOut]
    arrow.add(dip, forKey: "press")
    guard !PresenceMotion.reducesMotion else {
      return
    }
    host.addSublayer(Self.ripple(at: tip, colour: EviePresenceTint.acting.resolved(in: appearance)))
  }

  func fadeOut(duration: Double) {
    guard isShown else {
      return
    }
    isShown = false
    PresenceMotion.ease(arrow, "opacity", to: Float(0), duration: duration)
  }

  /// A 44 pt ring that grows from 0.4 to full size while fading from 0.8 to
  /// nothing over 380 ms, then takes itself out of the tree.
  private static func ripple(at point: CGPoint, colour: CGColor) -> CALayer {
    let diameter: CGFloat = 44
    let ring = CAShapeLayer()
    ring.bounds = CGRect(x: 0, y: 0, width: diameter, height: diameter)
    ring.position = point
    ring.path = CGPath(ellipseIn: ring.bounds.insetBy(dx: 1, dy: 1), transform: nil)
    ring.fillColor = nil
    ring.strokeColor = colour
    ring.lineWidth = 2
    ring.opacity = 0

    let grow = CABasicAnimation(keyPath: "transform.scale")
    grow.fromValue = 0.4
    grow.toValue = 1
    let fade = CABasicAnimation(keyPath: "opacity")
    fade.fromValue = 0.8
    fade.toValue = 0
    let group = CAAnimationGroup()
    group.animations = [grow, fade]
    group.duration = 0.38
    group.timingFunction = PresenceMotion.easeOut
    CATransaction.begin()
    CATransaction.setCompletionBlock { ring.removeFromSuperlayer() }
    ring.add(group, forKey: "ripple")
    CATransaction.commit()
    return ring
  }

  /// The classic pointer silhouette, tip at the origin, pointing up-left in
  /// a flipped (y-down) space.
  private static func arrowPath(height: CGFloat) -> CGPath {
    let unit = height / 22
    let points: [CGPoint] = [
      CGPoint(x: 0, y: 0),
      CGPoint(x: 0, y: 17),
      CGPoint(x: 4.2, y: 13.2),
      CGPoint(x: 7.2, y: 20),
      CGPoint(x: 10, y: 18.8),
      CGPoint(x: 7.1, y: 12.2),
      CGPoint(x: 12.6, y: 12.2),
    ].map { CGPoint(x: $0.x * unit, y: $0.y * unit) }
    let path = CGMutablePath()
    path.addLines(between: points)
    path.closeSubpath()
    return path
  }
}
