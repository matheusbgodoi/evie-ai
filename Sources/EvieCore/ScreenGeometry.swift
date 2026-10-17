import CoreGraphics
import Foundation

/// The coordinate arithmetic shared by screen capture, computer use and the
/// presence indicator.
///
/// Four spaces meet here, and mixing any two of them up puts a click or a
/// highlight in the wrong place without any error:
///
/// - **Global Core Graphics points.** Origin at the top-left of the primary
///   display, y growing downwards. `CGDisplayBounds`, `CGEvent` locations,
///   ScreenCaptureKit frames and Accessibility positions all use it, so it is
///   the space everything else is converted to and from.
/// - **Global AppKit points.** Origin at the bottom-left of the primary display,
///   y growing upwards. `NSScreen.frame` and window frames use it.
/// - **Image pixels.** The pixels of the image the model was actually sent,
///   which is downscaled and so matches neither points nor backing pixels.
/// - **The 0–1000 grid.** The coordinates Qwen-VL family models answer in,
///   relative to the observed frame, whatever its size.
///
/// The model's numbers are never trusted as screen positions: they are turned
/// into points here, by code, against the frame that was observed, and anything
/// outside that frame is refused.
public enum ScreenGeometry {
  /// The far edge of the normalized grid. A value of 1000 is the right or
  /// bottom edge of the observed frame.
  public static let normalizedGridExtent = 1_000

  /// The size an image of `source` pixels is reduced to so that its longer edge
  /// is at most `maxLongEdge`, keeping its aspect ratio.
  ///
  /// Never enlarges: upscaling adds tokens without adding anything the model can
  /// see. Each edge is rounded to whole pixels and kept at least 1, and a source
  /// with no area gives `.zero` rather than a division by zero.
  public static func downscaledSize(_ source: CGSize, maxLongEdge: Int) -> CGSize {
    guard source.width.isFinite, source.height.isFinite,
      source.width > 0, source.height > 0, maxLongEdge > 0
    else {
      return .zero
    }
    let longEdge = max(source.width, source.height)
    let scale = min(1, CGFloat(maxLongEdge) / longEdge)
    return CGSize(
      width: max(1, (source.width * scale).rounded()),
      height: max(1, (source.height * scale).rounded())
    )
  }

  /// One connected display, as Core Graphics describes it.
  public struct Display: Sendable, Equatable {
    public let id: CGDirectDisplayID
    /// `CGDisplayBounds(id)`: global Core Graphics points.
    public let frameInGlobalCG: CGRect
    /// Backing pixels per point: 2 on a Retina display, 1 on most monitors.
    public let backingScale: CGFloat

    public init(id: CGDirectDisplayID, frameInGlobalCG: CGRect, backingScale: CGFloat) {
      self.id = id
      self.frameInGlobalCG = frameInGlobalCG
      self.backingScale = backingScale
    }

    /// The display's size in backing pixels — what a native-resolution capture
    /// of it measures before any downscale.
    public var pixelSize: CGSize {
      CGSize(
        width: frameInGlobalCG.width * backingScale,
        height: frameInGlobalCG.height * backingScale
      )
    }
  }

  /// Every connected display, which is what converting between Core Graphics
  /// and AppKit needs: the two spaces flip about the primary display's height,
  /// whichever display a point is actually on.
  public struct Layout: Sendable, Equatable {
    public let displays: [Display]
    /// The display at the Core Graphics origin — the one with the menu bar, and
    /// the one `NSScreen.screens[0]` describes. Identified by its origin rather
    /// than by its position in a list, because list order is not a contract
    /// either API makes for the other.
    public let primary: Display

    /// `nil` when no display sits at the origin, which means the list is empty
    /// or was read mid-reconfiguration: there is then no primary height to flip
    /// about, and guessing one would misplace everything on every display.
    public init?(displays: [Display]) {
      guard let primary = displays.first(where: { $0.frameInGlobalCG.origin == .zero }) else {
        return nil
      }
      self.displays = displays
      self.primary = primary
    }

    private var primaryHeight: CGFloat {
      primary.frameInGlobalCG.height
    }

    public func display(id: CGDirectDisplayID) -> Display? {
      displays.first { $0.id == id }
    }

    /// The display a global Core Graphics point is on. Frames are half-open, so
    /// a point on the boundary between two displays belongs to exactly one.
    public func display(containingGlobalCG point: CGPoint) -> Display? {
      displays.first { $0.frameInGlobalCG.contains(point) }
    }

    public func appKitPoint(fromGlobalCG point: CGPoint) -> CGPoint {
      CGPoint(x: point.x, y: primaryHeight - point.y)
    }

    /// The flip is its own inverse; the separate name keeps call sites honest
    /// about which direction they are going.
    public func globalCGPoint(fromAppKit point: CGPoint) -> CGPoint {
      CGPoint(x: point.x, y: primaryHeight - point.y)
    }

    /// Flips a rect using its height: `nsMinY = primaryH − (cg.minY + cg.height)`.
    /// A rect's origin is its top-left corner in one space and its bottom-left
    /// in the other, so flipping the origin alone shifts it by its own height.
    public func appKitRect(fromGlobalCG rect: CGRect) -> CGRect {
      CGRect(
        x: rect.minX,
        y: primaryHeight - (rect.minY + rect.height),
        width: rect.width,
        height: rect.height
      )
    }

    public func globalCGRect(fromAppKit rect: CGRect) -> CGRect {
      CGRect(
        x: rect.minX,
        y: primaryHeight - (rect.minY + rect.height),
        width: rect.width,
        height: rect.height
      )
    }

    /// Where AppKit places this display's `NSScreen.frame`.
    public func appKitFrame(of display: Display) -> CGRect {
      appKitRect(fromGlobalCG: display.frameInGlobalCG)
    }

    /// A global rect in the coordinates of a borderless panel that exactly
    /// covers `display`: AppKit orientation, origin at the screen's bottom-left
    /// corner. This is where the presence layers draw.
    public func panelRect(fromGlobalCG rect: CGRect, on display: Display) -> CGRect {
      let screen = appKitFrame(of: display)
      return appKitRect(fromGlobalCG: rect).offsetBy(dx: -screen.minX, dy: -screen.minY)
    }
  }

  /// What the model was shown: a region of the screen in global Core Graphics
  /// points — a whole display or one window — and the size of the image it
  /// was sent as. Every coordinate the model gives back is relative to this.
  public struct ObservedFrame: Sendable, Equatable {
    public let frameInGlobalCG: CGRect
    public let imageSize: CGSize

    /// How far a window may differ from where it was observed and still be
    /// treated as unmoved. The window server and Accessibility both report
    /// whole points but can disagree by rounding; less than a point cannot put
    /// a click on a different control.
    public static let movementTolerance: CGFloat = 1

    public init(frameInGlobalCG: CGRect, imageSize: CGSize) {
      self.frameInGlobalCG = frameInGlobalCG
      self.imageSize = imageSize
    }

    /// The global point for a model answer on the 0–1000 grid, or `nil` when
    /// the answer lies outside the grid and so outside what was observed.
    ///
    /// Out-of-range values are refused rather than clamped: a model that names
    /// a point beyond the edge was not looking at the screen it was given, and
    /// moving its click onto the nearest edge would act on something it never
    /// chose. Values on the grid are clamped onto the frame's last point,
    /// because 1000 is the far edge itself, which belongs to the next display.
    public func globalPoint(normalizedX x: Int, normalizedY y: Int) -> CGPoint? {
      let extent = ScreenGeometry.normalizedGridExtent
      guard (0...extent).contains(x), (0...extent).contains(y) else {
        return nil
      }
      return point(
        at: CGPoint(x: x, y: y),
        across: CGSize(width: extent, height: extent)
      )
    }

    /// The global point for a model answer in pixels of the image it was sent,
    /// for models that answer in pixels rather than on the grid. Dividing by the
    /// image size accounts for both the backing scale and the downscale at once.
    public func globalPoint(imagePixel pixel: CGPoint) -> CGPoint? {
      guard pixel.x.isFinite, pixel.y.isFinite,
        imageSize.width > 0, imageSize.height > 0,
        (0...imageSize.width).contains(pixel.x),
        (0...imageSize.height).contains(pixel.y)
      else {
        return nil
      }
      return point(at: pixel, across: imageSize)
    }

    /// An element's global frame as a whole-number box on the 0–1000 grid of
    /// this observation, or `nil` when no part of it is inside the frame — such
    /// an element is dropped, since the model cannot see it and must not be
    /// offered it. An element cut by the edge keeps only its visible part, so
    /// the centre of its box is always on screen.
    public func normalizedBox(forGlobalCG rect: CGRect) -> CGRect? {
      guard frameInGlobalCG.width > 0, frameInGlobalCG.height > 0 else {
        return nil
      }
      let visible = frameInGlobalCG.intersection(rect)
      guard !visible.isNull, !visible.isEmpty else {
        return nil
      }
      let extent = CGFloat(ScreenGeometry.normalizedGridExtent)
      func gridX(_ value: CGFloat) -> CGFloat {
        ((value - frameInGlobalCG.minX) * extent / frameInGlobalCG.width).rounded()
      }
      func gridY(_ value: CGFloat) -> CGFloat {
        ((value - frameInGlobalCG.minY) * extent / frameInGlobalCG.height).rounded()
      }
      let minX = gridX(visible.minX)
      let minY = gridY(visible.minY)
      return CGRect(
        x: minX,
        y: minY,
        width: gridX(visible.maxX) - minX,
        height: gridY(visible.maxY) - minY
      )
    }

    /// Whether a window read again just before acting is somewhere other than
    /// where it was observed. A moved or resized window means every grid
    /// coordinate the model gave now points at something else, so the action
    /// is refused rather than corrected.
    public func hasMoved(comparedTo current: CGRect) -> Bool {
      guard !current.isNull else {
        return true
      }
      let tolerance = Self.movementTolerance
      return abs(current.minX - frameInGlobalCG.minX) > tolerance
        || abs(current.minY - frameInGlobalCG.minY) > tolerance
        || abs(current.width - frameInGlobalCG.width) > tolerance
        || abs(current.height - frameInGlobalCG.height) > tolerance
    }

    /// The global point that `value` is within a space of size `extent` laid
    /// over the frame, kept on the frame's last addressable point. One point in
    /// from the far edge rather than a hair: the edge itself is the
    /// neighbouring display's first column, and a whole point stays clear of it
    /// at any backing scale.
    ///
    /// Multiplies before dividing so that grid values such as 100 of 1000 land
    /// on whole points exactly instead of on 0.1 × width.
    private func point(at value: CGPoint, across extent: CGSize) -> CGPoint? {
      let frame = frameInGlobalCG
      guard frame.width > 0, frame.height > 0 else {
        return nil
      }
      let x = frame.minX + value.x * frame.width / extent.width
      let y = frame.minY + value.y * frame.height / extent.height
      return CGPoint(
        x: min(max(x, frame.minX), max(frame.minX, frame.maxX - 1)),
        y: min(max(y, frame.minY), max(frame.minY, frame.maxY - 1))
      )
    }
  }
}
