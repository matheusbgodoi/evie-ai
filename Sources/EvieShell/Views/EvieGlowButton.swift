import AppKit
import SwiftUI

/// A round icon button that lights up under the pointer.
///
/// Built in AppKit for two reasons. Hover state needs somewhere to live, and this
/// toolchain has no `@State`; and the glow is a layer shadow, which Core Animation
/// fades for free while SwiftUI would re-render the button on every frame of the
/// transition.
struct EvieGlowButton: NSViewRepresentable {
  enum Style: Equatable {
    /// A quiet button on glass.
    case subtle
    /// The primary action, filled with the tint.
    case filled
  }

  var systemImage: String
  var label: String
  var tint: Color
  var style: Style = .subtle
  var diameter: CGFloat = 27
  var glyphSize: CGFloat = 10
  var isEnabled = true
  var action: () -> Void

  func makeNSView(context: Context) -> GlowButtonView {
    GlowButtonView()
  }

  func updateNSView(_ view: GlowButtonView, context: Context) {
    view.configure(
      systemImage: systemImage,
      label: label,
      tint: NSColor(tint),
      style: style,
      diameter: diameter,
      glyphSize: glyphSize,
      isEnabled: isEnabled,
      action: action
    )
  }

  final class GlowButtonView: NSView {
    private let background = CALayer()
    private let glyph = CALayer()
    private var action: (() -> Void)?
    private var isEnabledForClicks = true
    private var isHovering = false
    private var isPressed = false
    private var trackingArea: NSTrackingArea?
    private var identity: Identity?

    private struct Identity: Equatable {
      let systemImage: String
      let tint: NSColor
      let style: Style
      let diameter: CGFloat
      let glyphSize: CGFloat
      let isEnabled: Bool
    }

    override init(frame: NSRect) {
      super.init(frame: frame)
      wantsLayer = true
      layer = CALayer()
      // Siblings, not parent and child. The glyph used to live inside the
      // background, which meant the hover transform applied to one of them
      // reached the other through the hierarchy instead of by intent. Both hang
      // off the root now and the root is what moves, so they cannot drift apart.
      layer?.addSublayer(background)
      layer?.addSublayer(glyph)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
      fatalError("init(coder:) has not been implemented")
    }

    override var isFlipped: Bool { true }

    /// Without this the view has no size of its own and SwiftUI hands it every
    /// point available, which turned three small icon buttons into three huge
    /// circles spread across the card.
    override var intrinsicContentSize: NSSize {
      guard let identity else {
        return NSSize(width: 24, height: 24)
      }
      return NSSize(width: identity.diameter, height: identity.diameter)
    }

    override func updateTrackingAreas() {
      super.updateTrackingAreas()
      if let trackingArea {
        removeTrackingArea(trackingArea)
      }
      let area = NSTrackingArea(
        rect: bounds,
        options: [.mouseEnteredAndExited, .activeAlways, .inVisibleRect],
        owner: self
      )
      addTrackingArea(area)
      trackingArea = area
    }

    override func viewDidChangeEffectiveAppearance() {
      super.viewDidChangeEffectiveAppearance()
      guard let identity else {
        return
      }
      self.identity = nil
      configure(
        systemImage: identity.systemImage,
        label: toolTip ?? "",
        tint: identity.tint,
        style: identity.style,
        diameter: identity.diameter,
        glyphSize: identity.glyphSize,
        isEnabled: identity.isEnabled,
        action: action ?? {}
      )
    }

    // swift-format-ignore: AlwaysUseLowerCamelCase
    func configure(
      systemImage: String,
      label: String,
      tint: NSColor,
      style: Style,
      diameter: CGFloat,
      glyphSize: CGFloat,
      isEnabled: Bool,
      action: @escaping () -> Void
    ) {
      self.action = action
      isEnabledForClicks = isEnabled
      toolTip = label
      setAccessibilityLabel(label)
      setAccessibilityRole(.button)

      let requested = Identity(
        systemImage: systemImage,
        tint: tint,
        style: style,
        diameter: diameter,
        glyphSize: glyphSize,
        isEnabled: isEnabled
      )
      guard identity != requested else {
        return
      }
      identity = requested
      invalidateIntrinsicContentSize()
      effectiveAppearance.performAsCurrentDrawingAppearance {
        layOut(requested)
      }
    }

    private func layOut(_ identity: Identity) {
      let scale = window?.backingScaleFactor ?? 2
      let bounds = CGRect(x: 0, y: 0, width: identity.diameter, height: identity.diameter)

      CATransaction.begin()
      CATransaction.setDisableActions(true)

      layer?.frame = bounds
      background.frame = bounds
      background.cornerRadius = identity.diameter / 2
      background.contentsScale = scale
      background.shadowColor = identity.tint.cgColor
      background.shadowRadius = 7
      background.shadowOffset = .zero
      background.shadowOpacity = isHovering && identity.isEnabled ? 0.65 : 0

      switch identity.style {
      case .subtle:
        background.backgroundColor =
          NSColor.white.withAlphaComponent(isHovering ? 0.14 : 0.06).cgColor
      case .filled:
        background.backgroundColor = identity.tint.cgColor
      }
      background.opacity = identity.isEnabled ? 1 : 0.42

      // One transform, on the root, so the circle and the mark inside it are
      // always the same size and always concentric.
      let emphasis: CGFloat
      if !identity.isEnabled {
        emphasis = 1
      } else if isPressed {
        // Pressing pushes in. Without it a click has no acknowledgement at all
        // until whatever it triggered finishes, which for anything slow reads
        // as a button that did not take the press.
        emphasis = 0.92
      } else if isHovering {
        emphasis = 1.09
      } else {
        emphasis = 1
      }
      layer?.anchorPoint = CGPoint(x: 0.5, y: 0.5)
      layer?.frame = bounds
      layer?.transform = CATransform3DMakeScale(emphasis, emphasis, 1)

      // The glyph is centred on its *ink*, not on its image.
      //
      // An SF Symbol's image is a canvas with the mark somewhere inside it, and
      // where inside is not the middle: `chevron.up` sits high in its box and
      // `chevron.down` sits low. Centring the box therefore puts the visible
      // mark off-centre, in opposite directions for the two halves of the same
      // toggle — which is why the arrow looked crooked, and why it looked more
      // crooked the moment the circle grew under it on hover.
      //
      // The opaque bounds are measured once per appearance and cached, so this
      // costs nothing on the hover redraws that call this method.
      let drawn = Self.image(
        named: identity.systemImage,
        size: identity.glyphSize,
        colour: identity.style == .filled ? .white : .secondaryLabelColor
      )
      let glyphSize = drawn?.size ?? CGSize(width: identity.glyphSize, height: identity.glyphSize)
      let offset = drawn?.inkOffset ?? .zero
      glyph.frame = CGRect(
        x: Self.snap((identity.diameter - glyphSize.width) / 2 - offset.width, to: scale),
        y: Self.snap((identity.diameter - glyphSize.height) / 2 - offset.height, to: scale),
        width: Self.snap(glyphSize.width, to: scale),
        height: Self.snap(glyphSize.height, to: scale)
      )
      glyph.contentsScale = scale
      glyph.contentsGravity = .resizeAspect
      glyph.contents = drawn?.image

      CATransaction.commit()
    }

    /// The nearest position that lands on a whole device pixel.
    static func snap(_ value: CGFloat, to scale: CGFloat) -> CGFloat {
      guard scale > 0 else {
        return value.rounded()
      }
      return (value * scale).rounded() / scale
    }

    override func mouseEntered(with event: NSEvent) {
      guard isEnabledForClicks else {
        return
      }
      isHovering = true
      animateHover()
      NSCursor.pointingHand.push()
    }

    override func mouseExited(with event: NSEvent) {
      guard isHovering else {
        return
      }
      isHovering = false
      animateHover()
      NSCursor.pop()
    }

    /// A short, explicit transition. Core Animation's implicit actions are
    /// disabled during layout, so the two properties that carry the glow are
    /// animated by hand.
    private func animateHover() {
      guard let identity else {
        return
      }
      let duration = 0.16
      let targetScale: CGFloat = isHovering ? 1.09 : 1
      let targetShadow: Float = isHovering ? 0.65 : 0
      let targetBackground: CGColor =
        identity.style == .filled
        ? identity.tint.cgColor
        : NSColor.white.withAlphaComponent(isHovering ? 0.14 : 0.06).cgColor

      CATransaction.begin()
      CATransaction.setAnimationDuration(duration)
      CATransaction.setAnimationTimingFunction(
        CAMediaTimingFunction(name: .easeOut)
      )
      background.transform = CATransform3DMakeScale(targetScale, targetScale, 1)
      background.shadowOpacity = targetShadow
      background.backgroundColor = targetBackground
      CATransaction.commit()
    }

    /// Pressed on the way down, fired on the way up inside the button.
    ///
    /// Firing on `mouseDown` gave the click no acknowledgement and no way out:
    /// there was nothing to see and, once started, nothing to cancel by dragging
    /// off — which is what every other button on this system does.
    override func mouseDown(with event: NSEvent) {
      guard isEnabledForClicks else {
        return
      }
      isPressed = true
      animateHover()
    }

    override func mouseUp(with event: NSEvent) {
      guard isPressed else {
        return
      }
      isPressed = false
      animateHover()
      guard isEnabledForClicks,
        bounds.contains(convert(event.locationInWindow, from: nil))
      else {
        return
      }
      action?()
    }

    override func accessibilityPerformPress() -> Bool {
      guard isEnabledForClicks else {
        return false
      }
      action?()
      return true
    }

    /// A rendered symbol together with the size it wants to be drawn at.
    ///
    /// The size travels with the image because a symbol's natural box is not
    /// square, and laying it out without that is what made the controls look
    /// stretched.
    private struct DrawnGlyph {
      let image: CGImage
      let size: CGSize
      /// How far the visible mark sits from the middle of its own image, in
      /// points. Subtracting it centres the mark rather than the canvas.
      let inkOffset: CGSize
    }

    /// Drawn symbols, kept because `layOut` runs on every hover and measuring
    /// the ink means reading the pixels.
    private static var glyphCache: [String: DrawnGlyph] = [:]

    private static func image(
      named name: String,
      size: CGFloat,
      colour: NSColor
    ) -> DrawnGlyph? {
      let key = "\(name)|\(size)|\(colour.description)"
      if let cached = glyphCache[key] {
        return cached
      }
      let configuration = NSImage.SymbolConfiguration(pointSize: size, weight: .semibold)
        .applying(.init(hierarchicalColor: colour))
      guard
        let image = NSImage(systemSymbolName: name, accessibilityDescription: nil)?
          .withSymbolConfiguration(configuration)
      else {
        return nil
      }
      var rect = CGRect(origin: .zero, size: image.size)
      guard let cgImage = image.cgImage(forProposedRect: &rect, context: nil, hints: nil) else {
        return nil
      }
      let drawn = DrawnGlyph(
        image: cgImage,
        size: image.size,
        inkOffset: inkOffset(of: cgImage, drawnAt: image.size)
      )
      glyphCache[key] = drawn
      return drawn
    }

    /// Where the opaque pixels sit relative to the middle of the image.
    ///
    /// Read from the alpha channel, because a symbol's canvas is not its mark:
    /// `chevron.up` occupies the upper part of its box and `chevron.down` the
    /// lower, so centring the box tilts the two halves of one toggle in
    /// opposite directions.
    private static func inkOffset(of image: CGImage, drawnAt size: CGSize) -> CGSize {
      let width = image.width
      let height = image.height
      guard width > 0, height > 0 else {
        return .zero
      }
      var alpha = [UInt8](repeating: 0, count: width * height)
      guard
        let context = CGContext(
          data: &alpha,
          width: width,
          height: height,
          bitsPerComponent: 8,
          bytesPerRow: width,
          space: CGColorSpaceCreateDeviceGray(),
          bitmapInfo: CGImageAlphaInfo.alphaOnly.rawValue
        )
      else {
        return .zero
      }
      context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))

      var minX = width, maxX = -1, minY = height, maxY = -1
      for y in 0..<height {
        for x in 0..<width where alpha[y * width + x] > 8 {
          minX = min(minX, x)
          maxX = max(maxX, x)
          minY = min(minY, y)
          maxY = max(maxY, y)
        }
      }
      guard maxX >= minX, maxY >= minY else {
        return .zero
      }
      // In pixels, then converted to the points the layer is laid out in.
      let inkCentreX = (CGFloat(minX) + CGFloat(maxX) + 1) / 2
      let inkCentreY = (CGFloat(minY) + CGFloat(maxY) + 1) / 2
      let offsetX = (inkCentreX - CGFloat(width) / 2) * (size.width / CGFloat(width))
      // Core Graphics draws top-down here while the layer is laid out
      // bottom-up, so the vertical offset changes sign.
      let offsetY = -(inkCentreY - CGFloat(height) / 2) * (size.height / CGFloat(height))
      return CGSize(width: offsetX, height: offsetY)
    }
  }
}
