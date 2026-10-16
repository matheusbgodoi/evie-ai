import AppKit
import EvieCore
import QuartzCore

/// Where Evie is looking while she works out her next step: four corner
/// brackets around the region, over a faint violet fill.
///
/// Brackets rather than a box because a box reads as a selection — as
/// something already chosen — and between steps nothing has been. Each corner
/// is its own layer with its own x and y springs, so the reticle can be
/// redirected mid-flight from wherever it is, and the two axes settling at
/// slightly different rates bend its path into a natural arc.
final class ReticleLayer: CALayer {
  private enum Corner: CaseIterable {
    case topLeft, topRight, bottomRight, bottomLeft
  }

  private let fill = CALayer()
  private var brackets: [Corner: CAShapeLayer] = [:]
  private var arm: CGFloat = 0
  private var lockOn: DispatchWorkItem?
  private(set) var target: CGRect?

  /// How far outside its target the reticle travels before it locks on.
  private static let lockOnSlack: CGFloat = 10
  private static let responseX = 0.38
  private static let responseY = 0.42

  override init() {
    super.init()
    fill.cornerRadius = 4
    addSublayer(fill)
    for corner in Corner.allCases {
      let bracket = CAShapeLayer()
      bracket.fillColor = nil
      bracket.lineWidth = 2
      bracket.lineCap = .round
      bracket.lineJoin = .round
      // A dark hairline around the stroke, so it stays readable over a busy
      // or violet-ish background.
      bracket.shadowColor = NSColor.black.cgColor
      bracket.shadowOpacity = 0.3
      bracket.shadowRadius = 1
      bracket.shadowOffset = .zero
      brackets[corner] = bracket
      addSublayer(bracket)
    }
    opacity = 0
  }

  override init(layer: Any) {
    super.init(layer: layer)
  }

  @available(*, unavailable)
  required init?(coder: NSCoder) {
    fatalError("init(coder:) has not been implemented")
  }

  func setColours(in appearance: NSAppearance) {
    PresenceMotion.set {
      let tint = EviePresenceTint.seeing
      fill.backgroundColor = tint.resolved(in: appearance, alpha: 0.06)
      for bracket in brackets.values {
        bracket.strokeColor = tint.resolved(in: appearance)
      }
    }
  }

  /// Moves the reticle onto `rect`, in the panel's flipped coordinates.
  ///
  /// The first time, it appears there: slightly too large and transparent,
  /// then settling onto the target as it fades in. After that it travels
  /// from its current on-screen position at the outer size and locks on —
  /// closes onto the target — as it arrives.
  func look(at rect: CGRect) {
    lockOn?.cancel()
    let wasVisible = target != nil
    target = rect
    updateArms(for: rect.size)
    let slack = rect.insetBy(dx: -Self.lockOnSlack, dy: -Self.lockOnSlack)

    if PresenceMotion.reducesMotion {
      // No travel: a cross-fade to the new place.
      if wasVisible {
        PresenceMotion.ease(self, "opacity", to: Float(0), duration: 0.075)
        let work = DispatchWorkItem { [weak self] in
          guard let self else { return }
          PresenceMotion.set { self.place(at: rect) }
          PresenceMotion.ease(self, "opacity", to: Float(1), duration: 0.075)
        }
        lockOn = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.075, execute: work)
      } else {
        PresenceMotion.set { place(at: rect) }
        PresenceMotion.ease(self, "opacity", to: Float(1), duration: 0.15)
      }
      return
    }

    if !wasVisible {
      PresenceMotion.set { place(at: slack) }
      PresenceMotion.ease(self, "opacity", to: Float(1), duration: 0.2)
      spring(to: rect, responseX: 0.3, responseY: 0.32)
      return
    }
    spring(to: slack, responseX: Self.responseX, responseY: Self.responseY)
    // The lock-on starts as the travel is settling, from wherever the corners
    // then are, so the two read as one movement rather than two.
    let work = DispatchWorkItem { [weak self] in
      self?.spring(to: rect, responseX: 0.22, responseY: 0.22)
    }
    lockOn = work
    DispatchQueue.main.asyncAfter(deadline: .now() + Self.responseY * 0.8, execute: work)
  }

  /// Appears directly at `rect`, scaling down from 1.06 — how the reticle
  /// arrives on a display it was not on. Nothing travels between screens.
  func appear(at rect: CGRect) {
    lockOn?.cancel()
    target = rect
    updateArms(for: rect.size)
    PresenceMotion.set { place(at: rect) }
    PresenceMotion.ease(self, "opacity", to: Float(1), duration: 0.2)
    guard !PresenceMotion.reducesMotion else {
      return
    }
    let grow = CABasicAnimation(keyPath: "transform.scale")
    grow.fromValue = 1.06
    grow.toValue = 1
    grow.duration = 0.2
    grow.timingFunction = PresenceMotion.easeOut
    // Scaled about the target's centre, not the panel's.
    PresenceMotion.set {
      anchorPoint = CGPoint(x: rect.midX / max(bounds.width, 1), y: rect.midY / max(bounds.height, 1))
      position = CGPoint(x: rect.midX, y: rect.midY)
    }
    add(grow, forKey: "appear")
  }

  func fadeOut(duration: Double) {
    lockOn?.cancel()
    target = nil
    PresenceMotion.ease(self, "opacity", to: Float(0), duration: duration)
  }

  private func spring(to rect: CGRect, responseX: Double, responseY: Double) {
    for (corner, bracket) in brackets {
      let point = Self.point(of: corner, in: rect)
      PresenceMotion.spring(bracket, "position.x", to: point.x, response: responseX)
      PresenceMotion.spring(bracket, "position.y", to: point.y, response: responseY)
    }
    PresenceMotion.spring(fill, "position.x", to: rect.midX, response: responseX)
    PresenceMotion.spring(fill, "position.y", to: rect.midY, response: responseY)
    PresenceMotion.spring(fill, "bounds.size.width", to: rect.width, response: responseX)
    PresenceMotion.spring(fill, "bounds.size.height", to: rect.height, response: responseY)
  }

  private func place(at rect: CGRect) {
    for (corner, bracket) in brackets {
      bracket.position = Self.point(of: corner, in: rect)
    }
    fill.bounds = CGRect(origin: .zero, size: rect.size)
    fill.position = CGPoint(x: rect.midX, y: rect.midY)
  }

  /// Redraws the L of each bracket when the target is small enough to need
  /// shorter arms. The path is drawn around the layer's own origin, which
  /// sits on the corner, so moving the corner is only a position change.
  private func updateArms(for size: CGSize) {
    let arm = ScreenPresenceLayout.reticleArm(for: size)
    guard arm != self.arm else {
      return
    }
    self.arm = arm
    PresenceMotion.set {
      for (corner, bracket) in brackets {
        let path = CGMutablePath()
        let (dx, dy): (CGFloat, CGFloat) =
          switch corner {
          case .topLeft: (1, 1)
          case .topRight: (-1, 1)
          case .bottomRight: (-1, -1)
          case .bottomLeft: (1, -1)
          }
        path.move(to: CGPoint(x: 0, y: dy * arm))
        path.addLine(to: .zero)
        path.addLine(to: CGPoint(x: dx * arm, y: 0))
        bracket.path = path
      }
    }
  }

  private static func point(of corner: Corner, in rect: CGRect) -> CGPoint {
    switch corner {
    case .topLeft: CGPoint(x: rect.minX, y: rect.minY)
    case .topRight: CGPoint(x: rect.maxX, y: rect.minY)
    case .bottomRight: CGPoint(x: rect.maxX, y: rect.maxY)
    case .bottomLeft: CGPoint(x: rect.minX, y: rect.maxY)
    }
  }
}
