import CoreGraphics
import Foundation

/// Turns the saved appearance preferences plus the current displays into the
/// exact rectangle the overlay panel should occupy.
///
/// The maths lives here, away from AppKit, so display disconnection, clamping,
/// and resize behaviour are covered by deterministic tests instead of being
/// discovered by dragging a window around at runtime.
public enum EvieOverlayGeometry {
  /// Gap between the bottom of the display's usable area and the capsule.
  public static let bottomMargin: CGFloat = 18
  /// The capsule alone is never shorter than this.
  public static let minimumHeight: CGFloat = 72
  /// Beyond this the artifact list scrolls instead of the window growing.
  public static let maximumHeight: CGFloat = 720
  /// A saved position is only reused when at least this much of the window is
  /// still reachable on some connected display.
  public static let minimumVisibleSize = CGSize(width: 160, height: 48)

  /// The frame for the given content height, honouring a saved position when it
  /// is still reachable and falling back to the bottom-centred anchor when it is
  /// not.
  public static func resolveFrame(
    preferences: EvieAppearancePreferences,
    contentHeight: CGFloat,
    screens: [CGRect],
    pointerScreen: CGRect?
  ) -> CGRect {
    let anchorScreen = pointerScreen ?? screens.first ?? .zero
    let width = min(preferences.resolvedOverlayWidth, max(anchorScreen.width, 1))
    let height = clampedHeight(contentHeight, in: anchorScreen)

    if let origin = preferences.overlayOrigin {
      let candidate = CGRect(
        x: origin.x,
        y: origin.y,
        width: min(preferences.resolvedOverlayWidth, 1e6),
        height: height
      )
      if let host = hostScreen(for: candidate, in: screens) {
        let hostWidth = min(preferences.resolvedOverlayWidth, max(host.width, 1))
        let hostHeight = clampedHeight(contentHeight, in: host)
        return clamp(
          CGRect(x: origin.x, y: origin.y, width: hostWidth, height: hostHeight),
          into: host
        )
      }
    }

    return clamp(
      CGRect(
        x: anchorScreen.midX - width / 2,
        y: anchorScreen.minY + bottomMargin,
        width: width,
        height: height
      ),
      into: anchorScreen
    )
  }

  /// A new frame for a width change that keeps the window where the user was
  /// already looking: same centre, same bottom edge, still fully on screen.
  public static func resizedFrame(
    current: CGRect,
    width: CGFloat,
    screen: CGRect
  ) -> CGRect {
    let resolvedWidth = min(
      max(width, EvieAppearancePreferences.minimumOverlayWidth),
      min(EvieAppearancePreferences.maximumOverlayWidth, max(screen.width, 1))
    )
    return clamp(
      CGRect(
        x: current.midX - resolvedWidth / 2,
        y: current.minY,
        width: resolvedWidth,
        height: current.height
      ),
      into: screen
    )
  }

  /// The display a rectangle mostly belongs to, or `nil` when the saved position
  /// no longer lands on any connected display.
  public static func hostScreen(for frame: CGRect, in screens: [CGRect]) -> CGRect? {
    var best: (screen: CGRect, area: CGFloat)?
    for screen in screens {
      let overlap = screen.intersection(frame)
      guard !overlap.isNull,
        overlap.width >= minimumVisibleSize.width,
        overlap.height >= minimumVisibleSize.height
      else {
        continue
      }
      let area = overlap.width * overlap.height
      if best == nil || area > best!.area {
        best = (screen, area)
      }
    }
    return best?.screen
  }

  public static func clamp(_ frame: CGRect, into screen: CGRect) -> CGRect {
    guard !screen.isEmpty else {
      return frame
    }
    let width = min(frame.width, screen.width)
    let height = min(frame.height, screen.height)
    let x = min(max(frame.minX, screen.minX), screen.maxX - width)
    let y = min(max(frame.minY, screen.minY), screen.maxY - height)
    return CGRect(x: x, y: y, width: width, height: height)
  }

  fileprivate static func clampedHeight(_ requested: CGFloat, in screen: CGRect) -> CGFloat {
    let ceiling = screen.isEmpty ? maximumHeight : min(maximumHeight, screen.height)
    guard requested.isFinite else {
      return minimumHeight
    }
    return min(max(requested, minimumHeight), max(ceiling, minimumHeight))
  }
}

extension EvieAppearancePreferences {
  /// Records where the user dropped the window. Once a custom position exists
  /// the overlay stops re-centring itself on every summon.
  public mutating func captureOrigin(of frame: CGRect) {
    overlayOrigin = EvieOverlayOrigin(x: frame.origin.x, y: frame.origin.y)
  }
}
