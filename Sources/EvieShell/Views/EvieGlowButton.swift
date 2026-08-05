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
      layer?.addSublayer(background)
      background.addSublayer(glyph)
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
      background.transform = CATransform3DMakeScale(
        isHovering && identity.isEnabled ? 1.09 : 1,
        isHovering && identity.isEnabled ? 1.09 : 1,
        1
      )

      let size = identity.glyphSize * 1.9
      glyph.frame = CGRect(
        x: (identity.diameter - size) / 2,
        y: (identity.diameter - size) / 2,
        width: size,
        height: size
      )
      glyph.contentsScale = scale
      glyph.contents = Self.image(
        named: identity.systemImage,
        size: identity.glyphSize,
        colour: identity.style == .filled ? .white : .secondaryLabelColor
      )

      CATransaction.commit()
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

    override func mouseDown(with event: NSEvent) {
      guard isEnabledForClicks else {
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

    private static func image(
      named name: String,
      size: CGFloat,
      colour: NSColor
    ) -> CGImage? {
      let configuration = NSImage.SymbolConfiguration(pointSize: size, weight: .semibold)
        .applying(.init(hierarchicalColor: colour))
      guard
        let image = NSImage(systemSymbolName: name, accessibilityDescription: nil)?
          .withSymbolConfiguration(configuration)
      else {
        return nil
      }
      var rect = CGRect(origin: .zero, size: image.size)
      return image.cgImage(forProposedRect: &rect, context: nil, hints: nil)
    }
  }
}
