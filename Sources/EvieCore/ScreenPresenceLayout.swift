import CoreGraphics
import Foundation

/// Where the presence indicator puts things on a display, and how its ghost
/// cursor travels.
///
/// Every value is in display-local points with the origin at the display's
/// top-left corner — the space the presence layers draw in — so none of this
/// needs to know which display it is on or how the displays are arranged.
/// `ScreenGeometry` is what gets a point into this space.
public enum ScreenPresenceLayout {
  /// The gap between the pill and the edge of the usable area it sits against.
  public static let pillMargin: CGFloat = 8
  /// How close a target may come to the pill before the pill gets out of its
  /// way. The ghost cursor and the highlight both reach a little beyond the
  /// element itself, and the pill must never cover what Evie is about to press.
  public static let pillClearance: CGFloat = 24

  /// The pill's frame: centred at the top of `usableArea` (the visible frame,
  /// already below the menu bar and the notch), or at the bottom when the top
  /// would put it within `pillClearance` of `target`.
  ///
  /// When the target is so tall that it would be crowded at either edge, the
  /// pill stays at the top: moving it would cost the user the one place they
  /// look for it and buy nothing.
  public static func pillFrame(size: CGSize, usableArea: CGRect, avoiding target: CGRect?) -> CGRect {
    let x = (usableArea.midX - size.width / 2).rounded()
    let top = CGRect(
      x: x, y: usableArea.minY + pillMargin, width: size.width, height: size.height)
    guard let target else {
      return top
    }
    let crowded = target.insetBy(dx: -pillClearance, dy: -pillClearance)
    guard crowded.intersects(top) else {
      return top
    }
    let bottom = CGRect(
      x: x, y: usableArea.maxY - pillMargin - size.height, width: size.width, height: size.height)
    return crowded.intersects(bottom) ? top : bottom
  }

  /// The spring responses, in seconds, for the ghost cursor's trip between two
  /// points.
  ///
  /// Longer trips take longer, as a hand's would — `0.25 + distance / 3000` —
  /// bounded so a short hop is still seen to move and a cross-screen trip does
  /// not keep the click waiting. The vertical spring runs 10% slower than the
  /// horizontal one, which bends the straight line into the slight arc a real
  /// pointer makes.
  public static func cursorTravel(from start: CGPoint, to end: CGPoint) -> (responseX: Double, responseY: Double) {
    let distance = hypot(end.x - start.x, end.y - start.y)
    let response = min(max(0.25 + Double(distance) / 3_000, 0.3), 0.6)
    return (response, response * 1.1)
  }

  /// Where the ghost cursor appears before it travels to `target`.
  ///
  /// From the real pointer when it is on the same display, so the user sees
  /// Evie's cursor leave from where their own is; otherwise from just below
  /// and left of the target, which is where a pointer coming from nowhere in
  /// particular reads as approaching from. Kept on the display either way.
  public static func cursorStart(target: CGPoint, pointer: CGPoint?, displaySize: CGSize) -> CGPoint {
    let start = pointer ?? CGPoint(x: target.x - 60, y: target.y + 60)
    return CGPoint(
      x: min(max(start.x, 0), displaySize.width),
      y: min(max(start.y, 0), displaySize.height)
    )
  }

  /// The length of each arm of the gaze reticle's corner brackets: 16 points,
  /// or a quarter of the shorter side of a target too small for that, so the
  /// four brackets never meet and turn into a box.
  public static func reticleArm(for size: CGSize) -> CGFloat {
    max(0, min(16, min(size.width, size.height) * 0.25))
  }
}
