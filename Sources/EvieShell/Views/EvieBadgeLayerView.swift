import AppKit
import SwiftUI

/// Evie's badge, drawn in Core Animation layers instead of SwiftUI.
///
/// This exists for one measured reason. A breathing badge built the SwiftUI way —
/// a `TimelineView` flipping a value with an implicit animation on `scaleEffect` —
/// cost 8% of a core for a single circle, and 10% before the content was
/// rasterised, and 22% when the shadow radius animated too. SwiftUI re-renders
/// the gradient, the rim, and the symbol on every frame of the breath.
///
/// A `CABasicAnimation` on `transform.scale` is interpolated by the render server
/// with no work in this process at all. The overlay is resident all day; that
/// difference is the whole argument.
struct EvieBadgeLayerView: NSViewRepresentable {
  var symbolName: String
  var tint: Color
  var diameter: CGFloat
  var isAnimating: Bool

  func makeNSView(context: Context) -> BadgeView {
    BadgeView()
  }

  func updateNSView(_ view: BadgeView, context: Context) {
    view.configure(
      symbolName: symbolName,
      tint: NSColor(tint),
      diameter: diameter,
      isAnimating: isAnimating
    )
  }

  final class BadgeView: NSView {
    private let circle = CAGradientLayer()
    private let rim = CAShapeLayer()
    private let symbol = CALayer()
    private var configuration: (String, NSColor, CGFloat, Bool)?

    override init(frame: NSRect) {
      super.init(frame: frame)
      wantsLayer = true
      layer = CALayer()
      layer?.addSublayer(circle)
      circle.addSublayer(rim)
      circle.addSublayer(symbol)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
      fatalError("init(coder:) has not been implemented")
    }

    override var isFlipped: Bool { true }

    /// Layers do not participate in AppKit's automatic appearance updates, so the
    /// colour is resolved again whenever the system switches between light and
    /// dark.
    override func viewDidChangeEffectiveAppearance() {
      super.viewDidChangeEffectiveAppearance()
      guard let configuration else {
        return
      }
      self.configuration = nil
      configure(
        symbolName: configuration.0,
        tint: configuration.1,
        diameter: configuration.2,
        isAnimating: configuration.3
      )
    }

    func configure(symbolName: String, tint: NSColor, diameter: CGFloat, isAnimating: Bool) {
      let requested = (symbolName, tint, diameter, isAnimating)
      guard configuration.map({ $0 != requested }) ?? true else {
        return
      }
      configuration = requested

      effectiveAppearance.performAsCurrentDrawingAppearance {
        layOut(symbolName: symbolName, tint: tint, diameter: diameter)
      }
      apply(isAnimating: isAnimating)
    }

    private func layOut(symbolName: String, tint: NSColor, diameter: CGFloat) {
      let scale = window?.backingScaleFactor ?? 2
      let bounds = CGRect(x: 0, y: 0, width: diameter, height: diameter)

      CATransaction.begin()
      CATransaction.setDisableActions(true)

      layer?.frame = bounds
      circle.frame = bounds
      circle.cornerRadius = diameter / 2
      circle.contentsScale = scale
      // The same diagonal lift the badge always had.
      circle.startPoint = CGPoint(x: 0, y: 0)
      circle.endPoint = CGPoint(x: 1, y: 1)
      circle.colors = [
        tint.withAlphaComponent(0.82).cgColor,
        tint.cgColor,
      ]
      circle.shadowColor = tint.cgColor
      circle.shadowOpacity = 0.38
      circle.shadowRadius = 7
      circle.shadowOffset = .zero

      rim.frame = bounds
      rim.path = CGPath(ellipseIn: bounds.insetBy(dx: 0.3, dy: 0.3), transform: nil)
      rim.fillColor = nil
      rim.strokeColor = NSColor.white.withAlphaComponent(0.22).cgColor
      rim.lineWidth = 0.6
      rim.contentsScale = scale

      let glyphSize = diameter * 0.44
      symbol.frame = CGRect(
        x: (diameter - glyphSize) / 2,
        y: (diameter - glyphSize) / 2,
        width: glyphSize,
        height: glyphSize
      )
      symbol.contentsScale = scale
      symbol.contents = Self.glyph(named: symbolName, size: glyphSize)

      CATransaction.commit()
    }

    private func apply(isAnimating: Bool) {
      let key = "evie.breath"
      guard isAnimating else {
        circle.removeAnimation(forKey: key)
        return
      }
      guard circle.animation(forKey: key) == nil else {
        return
      }

      let breath = CABasicAnimation(keyPath: "transform.scale")
      breath.fromValue = 0.94
      breath.toValue = 1
      breath.duration = 2.6
      breath.autoreverses = true
      breath.repeatCount = .infinity
      breath.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
      // Keeps running while the app is not frontmost; the overlay is a HUD and is
      // routinely looked at without being focused.
      breath.isRemovedOnCompletion = false
      circle.add(breath, forKey: key)
    }

    private static func glyph(named name: String, size: CGFloat) -> CGImage? {
      let configuration = NSImage.SymbolConfiguration(
        pointSize: size,
        weight: .bold
      )
      .applying(.init(hierarchicalColor: .white))

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
