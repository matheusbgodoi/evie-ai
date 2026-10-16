import CoreGraphics
import Foundation
import Testing

@testable import EvieCore

@Suite("Screen geometry")
struct ScreenGeometryTests {
  // A 14-inch MacBook Pro at its default scaled resolution: 1512×982 points
  // backed by 3024×1964 pixels.
  private let builtIn = ScreenGeometry.Display(
    id: 1,
    frameInGlobalCG: CGRect(x: 0, y: 0, width: 1_512, height: 982),
    backingScale: 2
  )
  // A 1080p monitor placed to the left of the built-in display, top edges
  // aligned. Core Graphics gives it a negative x.
  private let leftMonitor = ScreenGeometry.Display(
    id: 2,
    frameInGlobalCG: CGRect(x: -1_920, y: 0, width: 1_920, height: 1_080),
    backingScale: 1
  )
  // The same kind of monitor placed above the built-in display. Core Graphics
  // grows y downwards, so "above" is a negative y.
  private let monitorAbove = ScreenGeometry.Display(
    id: 3,
    frameInGlobalCG: CGRect(x: 0, y: -1_080, width: 1_920, height: 1_080),
    backingScale: 1
  )

  private var layout: ScreenGeometry.Layout {
    ScreenGeometry.Layout(displays: [leftMonitor, builtIn, monitorAbove])!
  }

  // MARK: - Retina and downscaling

  @Test("a Retina display has twice as many pixels as points on each axis")
  func retinaPixelSize() {
    #expect(builtIn.pixelSize == CGSize(width: 3_024, height: 1_964))
    #expect(leftMonitor.pixelSize == CGSize(width: 1_920, height: 1_080))
  }

  @Test("a Retina capture is downscaled to a 1280 long edge with its aspect kept")
  func downscalesRetinaCapture() {
    let size = ScreenGeometry.downscaledSize(builtIn.pixelSize, maxLongEdge: 1_280)

    #expect(size == CGSize(width: 1_280, height: 831))
    let sourceAspect = builtIn.pixelSize.width / builtIn.pixelSize.height
    #expect(abs(size.width / size.height - sourceAspect) < 0.002)
  }

  @Test("a portrait capture is limited by its height, not its width")
  func downscalesPortrait() {
    let size = ScreenGeometry.downscaledSize(
      CGSize(width: 1_080, height: 1_920),
      maxLongEdge: 1_280
    )

    #expect(size == CGSize(width: 720, height: 1_280))
  }

  @Test("an image already within the limit is never enlarged")
  func neverUpscales() {
    let size = ScreenGeometry.downscaledSize(
      CGSize(width: 800, height: 600),
      maxLongEdge: 1_280
    )

    #expect(size == CGSize(width: 800, height: 600))
  }

  @Test("a degenerate source size gives an empty image size instead of a division by zero")
  func degenerateSource() {
    #expect(ScreenGeometry.downscaledSize(.zero, maxLongEdge: 1_280) == .zero)
    #expect(
      ScreenGeometry.downscaledSize(CGSize(width: CGFloat.nan, height: 10), maxLongEdge: 1_280)
        == .zero
    )
  }

  @Test("a pixel in a native-resolution Retina capture maps back to the right point")
  func retinaPixelMapsToPoint() {
    let observed = ScreenGeometry.ObservedFrame(
      frameInGlobalCG: builtIn.frameInGlobalCG,
      imageSize: builtIn.pixelSize
    )

    #expect(observed.globalPoint(imagePixel: CGPoint(x: 1_512, y: 982)) == CGPoint(x: 756, y: 491))
  }

  @Test("a pixel in the 1280 downscale maps back through both the scale and the downscale")
  func downscaledPixelMapsToPoint() {
    let observed = ScreenGeometry.ObservedFrame(
      frameInGlobalCG: builtIn.frameInGlobalCG,
      imageSize: ScreenGeometry.downscaledSize(builtIn.pixelSize, maxLongEdge: 1_280)
    )

    let point = observed.globalPoint(imagePixel: CGPoint(x: 640, y: 415.5))

    #expect(point.map { abs($0.x - 756) < 0.01 } == true)
    #expect(point.map { abs($0.y - 491) < 0.01 } == true)
  }

  // MARK: - The 0–1000 grid

  @Test("the 0–1000 grid spans the observed frame, origin at its top-left")
  func gridSpansFrame() {
    let observed = ScreenGeometry.ObservedFrame(
      frameInGlobalCG: builtIn.frameInGlobalCG,
      imageSize: CGSize(width: 1_280, height: 831)
    )

    #expect(observed.globalPoint(normalizedX: 0, normalizedY: 0) == CGPoint(x: 0, y: 0))
    #expect(observed.globalPoint(normalizedX: 500, normalizedY: 500) == CGPoint(x: 756, y: 491))
    #expect(observed.globalPoint(normalizedX: 250, normalizedY: 750) == CGPoint(x: 378, y: 736.5))
  }

  @Test("the grid is relative to a window frame, not to the display it sits on")
  func gridIsRelativeToWindow() {
    let window = CGRect(x: 200, y: 100, width: 800, height: 600)
    let observed = ScreenGeometry.ObservedFrame(
      frameInGlobalCG: window,
      imageSize: CGSize(width: 800, height: 600)
    )

    #expect(observed.globalPoint(normalizedX: 500, normalizedY: 500) == CGPoint(x: 600, y: 400))
  }

  @Test("the grid reaches a display on the left, at negative x")
  func gridOnLeftDisplay() {
    let observed = ScreenGeometry.ObservedFrame(
      frameInGlobalCG: leftMonitor.frameInGlobalCG,
      imageSize: CGSize(width: 1_280, height: 720)
    )

    let point = observed.globalPoint(normalizedX: 500, normalizedY: 500)

    #expect(point == CGPoint(x: -960, y: 540))
    #expect(point.flatMap(layout.display(containingGlobalCG:))?.id == leftMonitor.id)
  }

  @Test("the grid reaches a display above the primary, at negative y")
  func gridOnDisplayAbove() {
    let observed = ScreenGeometry.ObservedFrame(
      frameInGlobalCG: monitorAbove.frameInGlobalCG,
      imageSize: CGSize(width: 1_280, height: 720)
    )

    let point = observed.globalPoint(normalizedX: 100, normalizedY: 0)

    #expect(point == CGPoint(x: 192, y: -1_080))
    #expect(point.flatMap(layout.display(containingGlobalCG:))?.id == monitorAbove.id)
  }

  @Test("the far edge of the grid is clamped onto the last point inside the frame")
  func clampsFarEdge() {
    let observed = ScreenGeometry.ObservedFrame(
      frameInGlobalCG: leftMonitor.frameInGlobalCG,
      imageSize: CGSize(width: 1_280, height: 720)
    )

    let corner = observed.globalPoint(normalizedX: 1_000, normalizedY: 1_000)

    // 1000/1000 of the width is the right edge itself, which belongs to the
    // next display over. The click has to stay on the one that was observed.
    #expect(corner == CGPoint(x: -1, y: 1_079))
    #expect(corner.flatMap(layout.display(containingGlobalCG:))?.id == leftMonitor.id)
  }

  @Test("a grid value outside 0–1000 is refused rather than clamped")
  func refusesOutsideGrid() {
    let observed = ScreenGeometry.ObservedFrame(
      frameInGlobalCG: builtIn.frameInGlobalCG,
      imageSize: CGSize(width: 1_280, height: 831)
    )

    #expect(observed.globalPoint(normalizedX: -1, normalizedY: 500) == nil)
    #expect(observed.globalPoint(normalizedX: 500, normalizedY: 1_001) == nil)
    #expect(observed.globalPoint(normalizedX: 1_512, normalizedY: 491) == nil)
  }

  @Test("a pixel outside the image that was sent is refused")
  func refusesOutsideImage() {
    let observed = ScreenGeometry.ObservedFrame(
      frameInGlobalCG: builtIn.frameInGlobalCG,
      imageSize: CGSize(width: 1_280, height: 831)
    )

    #expect(observed.globalPoint(imagePixel: CGPoint(x: 1_281, y: 10)) == nil)
    #expect(observed.globalPoint(imagePixel: CGPoint(x: 10, y: -0.5)) == nil)
    #expect(observed.globalPoint(imagePixel: CGPoint(x: CGFloat.nan, y: 10)) == nil)
    #expect(observed.globalPoint(imagePixel: CGPoint(x: 1_280, y: 831)) == CGPoint(x: 1_511, y: 981))
  }

  @Test("an observation with no area maps nothing")
  func emptyObservation() {
    let observed = ScreenGeometry.ObservedFrame(
      frameInGlobalCG: CGRect(x: 10, y: 10, width: 0, height: 0),
      imageSize: .zero
    )

    #expect(observed.globalPoint(normalizedX: 500, normalizedY: 500) == nil)
    #expect(observed.globalPoint(imagePixel: .zero) == nil)
    #expect(observed.normalizedBox(forGlobalCG: CGRect(x: 10, y: 10, width: 5, height: 5)) == nil)
  }

  // MARK: - Element boxes

  @Test("an element's global box becomes a 0–1000 box relative to the observed frame")
  func elementBoxIsNormalized() {
    let window = CGRect(x: 200, y: 100, width: 800, height: 600)
    let observed = ScreenGeometry.ObservedFrame(
      frameInGlobalCG: window,
      imageSize: CGSize(width: 800, height: 600)
    )

    let box = observed.normalizedBox(forGlobalCG: CGRect(x: 600, y: 400, width: 80, height: 30))

    #expect(box == CGRect(x: 500, y: 500, width: 100, height: 50))
  }

  @Test("an element entirely outside the observed frame is dropped")
  func dropsElementOutsideFrame() {
    let observed = ScreenGeometry.ObservedFrame(
      frameInGlobalCG: CGRect(x: 200, y: 100, width: 800, height: 600),
      imageSize: CGSize(width: 800, height: 600)
    )

    #expect(observed.normalizedBox(forGlobalCG: CGRect(x: 1_100, y: 400, width: 80, height: 30)) == nil)
    // Touching the edge is not overlapping it.
    #expect(observed.normalizedBox(forGlobalCG: CGRect(x: 1_000, y: 400, width: 80, height: 30)) == nil)
    #expect(observed.normalizedBox(forGlobalCG: .null) == nil)
  }

  @Test("an element cut by the frame edge keeps only its visible part")
  func clipsPartlyVisibleElement() {
    let observed = ScreenGeometry.ObservedFrame(
      frameInGlobalCG: CGRect(x: 200, y: 100, width: 800, height: 600),
      imageSize: CGSize(width: 800, height: 600)
    )

    let box = observed.normalizedBox(forGlobalCG: CGRect(x: 960, y: 100, width: 80, height: 30))

    #expect(box == CGRect(x: 950, y: 0, width: 50, height: 50))
  }

  @Test("the centre of a normalized element box maps back onto the element")
  func elementBoxRoundTrip() {
    let observed = ScreenGeometry.ObservedFrame(
      frameInGlobalCG: leftMonitor.frameInGlobalCG,
      imageSize: CGSize(width: 1_280, height: 720)
    )
    let element = CGRect(x: -1_500, y: 300, width: 120, height: 40)

    let box = observed.normalizedBox(forGlobalCG: element)
    let centre = box.flatMap {
      observed.globalPoint(normalizedX: Int($0.midX), normalizedY: Int($0.midY))
    }

    #expect(centre.map(element.contains) == true)
  }

  // MARK: - A window that moved

  @Test("a window read again in the same place is accepted")
  func unmovedWindowAccepted() {
    let observed = ScreenGeometry.ObservedFrame(
      frameInGlobalCG: CGRect(x: 200, y: 100, width: 800, height: 600),
      imageSize: CGSize(width: 800, height: 600)
    )

    #expect(!observed.hasMoved(comparedTo: CGRect(x: 200, y: 100, width: 800, height: 600)))
    #expect(!observed.hasMoved(comparedTo: CGRect(x: 200.5, y: 99.5, width: 800, height: 600)))
  }

  @Test("a window that moved or was resized since the observation is refused")
  func movedWindowRefused() {
    let observed = ScreenGeometry.ObservedFrame(
      frameInGlobalCG: CGRect(x: 200, y: 100, width: 800, height: 600),
      imageSize: CGSize(width: 800, height: 600)
    )

    #expect(observed.hasMoved(comparedTo: CGRect(x: 240, y: 100, width: 800, height: 600)))
    #expect(observed.hasMoved(comparedTo: CGRect(x: 200, y: 100, width: 640, height: 600)))
    #expect(observed.hasMoved(comparedTo: .null))
  }

  // MARK: - Core Graphics and AppKit

  @Test("the primary display is the one at the Core Graphics origin, whatever its order")
  func findsPrimary() {
    #expect(layout.primary.id == builtIn.id)
    #expect(ScreenGeometry.Layout(displays: [leftMonitor, monitorAbove]) == nil)
    #expect(ScreenGeometry.Layout(displays: []) == nil)
  }

  @Test("a point flips about the primary display's height")
  func flipsPoint() {
    #expect(layout.appKitPoint(fromGlobalCG: CGPoint(x: 100, y: 0)) == CGPoint(x: 100, y: 982))
    #expect(layout.appKitPoint(fromGlobalCG: CGPoint(x: -960, y: 540)) == CGPoint(x: -960, y: 442))
    #expect(layout.globalCGPoint(fromAppKit: CGPoint(x: -960, y: 442)) == CGPoint(x: -960, y: 540))
  }

  @Test("a rect flips using its height, so its top edge stays where it was")
  func flipsRectWithHeight() {
    let element = CGRect(x: 100, y: 200, width: 80, height: 30)

    let flipped = layout.appKitRect(fromGlobalCG: element)

    // nsMinY = primaryH − (cg.minY + cg.height) = 982 − 230. Flipping only the
    // origin would give 782 and draw the highlight 30 points too high.
    #expect(flipped == CGRect(x: 100, y: 752, width: 80, height: 30))
    #expect(layout.globalCGRect(fromAppKit: flipped) == element)
  }

  @Test("each display lands where AppKit puts its screen")
  func displayFramesInAppKit() {
    #expect(layout.appKitFrame(of: builtIn) == CGRect(x: 0, y: 0, width: 1_512, height: 982))
    // Top-aligned with the built-in display, so it hangs 98 points below it.
    #expect(layout.appKitFrame(of: leftMonitor) == CGRect(x: -1_920, y: -98, width: 1_920, height: 1_080))
    // Above the primary: AppKit's origin is the primary's top edge.
    #expect(layout.appKitFrame(of: monitorAbove) == CGRect(x: 0, y: 982, width: 1_920, height: 1_080))
  }

  @Test("a global rect is placed inside the panel that covers its display")
  func panelLocalRect() {
    // Near the top-left corner of the monitor on the left.
    let element = CGRect(x: -1_900, y: 10, width: 100, height: 40)

    let local = layout.panelRect(fromGlobalCG: element, on: leftMonitor)

    // Panel coordinates have their origin at the screen's bottom-left corner,
    // so a box 10 points from the top of a 1080-point screen starts at 1030.
    #expect(local == CGRect(x: 20, y: 1_030, width: 100, height: 40))
  }

  @Test("a panel rect on the display above is local to that display")
  func panelLocalRectAbove() {
    let element = CGRect(x: 960, y: -540, width: 100, height: 40)

    let local = layout.panelRect(fromGlobalCG: element, on: monitorAbove)

    #expect(local == CGRect(x: 960, y: 500, width: 100, height: 40))
  }

  @Test("a point is matched to the display that contains it, edges included once")
  func displayContainingPoint() {
    #expect(layout.display(containingGlobalCG: CGPoint(x: 0, y: 0))?.id == builtIn.id)
    #expect(layout.display(containingGlobalCG: CGPoint(x: -0.5, y: 0))?.id == leftMonitor.id)
    #expect(layout.display(containingGlobalCG: CGPoint(x: 10, y: -1))?.id == monitorAbove.id)
    #expect(layout.display(containingGlobalCG: CGPoint(x: 1_600, y: 500)) == nil)
    #expect(layout.display(id: 3)?.frameInGlobalCG == monitorAbove.frameInGlobalCG)
    #expect(layout.display(id: 99) == nil)
  }
}
