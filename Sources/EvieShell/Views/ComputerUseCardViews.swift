import AppKit
import EvieCore
import SwiftUI

/// The clickable surface of a card button that only a hand may press
/// (`ArtifactActionModel.needsHand`), laid over the button's label.
///
/// AppKit, for what SwiftUI's `Button` cannot give: it sees the event behind
/// the click, so a click Evie posted herself (tagged `EvieSyntheticInput.tag`)
/// is reported as hers and `ComputerConfirmationDesk` ignores it; it never
/// becomes first responder, so no key presses it; it takes the first click
/// in the overlay, which is not the key window while Evie acts. Every press
/// is reported with how it was made, and EvieCore decides what it may do.
struct HandPressCatcher: NSViewRepresentable {
  var title: String
  var onPress: (ComputerUserPress) -> Void

  func makeNSView(context: Context) -> CatcherView {
    CatcherView()
  }

  func updateNSView(_ view: CatcherView, context: Context) {
    view.onPress = onPress
    view.setAccessibilityLabel(title)
  }

  final class CatcherView: NSView {
    var onPress: (ComputerUserPress) -> Void = { _ in }
    private var pressedBy: Int64?

    override init(frame: NSRect) {
      super.init(frame: frame)
      setAccessibilityElement(true)
      setAccessibilityRole(.button)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
      fatalError("init(coder:) has not been implemented")
    }

    override var acceptsFirstResponder: Bool { false }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    override func mouseDown(with event: NSEvent) {
      pressedBy = Self.userData(of: event)
    }

    /// Fired on the way up inside the button, so dragging off cancels. Both
    /// halves of the click must be the person's.
    override func mouseUp(with event: NSEvent) {
      guard let down = pressedBy else {
        return
      }
      pressedBy = nil
      guard bounds.contains(convert(event.locationInWindow, from: nil)) else {
        return
      }
      let up = Self.userData(of: event)
      onPress(.click(eventUserData: EvieSyntheticInput.isEvies(userData: down) ? down : up))
    }

    override func accessibilityPerformPress() -> Bool {
      onPress(.accessibility)
      return true
    }

    private static func userData(of event: NSEvent) -> Int64 {
      event.cgEvent?.getIntegerValueField(.eventSourceUserData) ?? 0
    }
  }
}

/// The confirmation card's picture: the newest screen of the session, with
/// an amber reticle where the action would land.
struct ComputerActionThumbnailView: View {
  var thumbnail: ArtifactThumbnail
  var tint: Color

  var body: some View {
    Image(nsImage: thumbnail.image)
      .resizable()
      .interpolation(.medium)
      .aspectRatio(contentMode: .fit)
      .frame(maxWidth: .infinity, maxHeight: 180)
      .overlay {
        GeometryReader { proxy in
          if let mark = thumbnail.mark {
            Reticle()
              .stroke(tint, style: StrokeStyle(lineWidth: 2, lineCap: .round))
              .shadow(color: tint.opacity(0.6), radius: 3)
              .frame(
                width: max(14, mark.width * proxy.size.width + 8),
                height: max(14, mark.height * proxy.size.height + 8)
              )
              .position(
                x: mark.midX * proxy.size.width,
                y: mark.midY * proxy.size.height
              )
          }
        }
      }
      .clipShape(RoundedRectangle(cornerRadius: 10))
      .overlay {
        RoundedRectangle(cornerRadius: 10)
          .strokeBorder(.white.opacity(0.12), lineWidth: 0.6)
      }
      .accessibilityLabel("Captura da tela, com o alvo da ação marcado")
  }

  /// Four corner brackets, the presence's reticle in miniature.
  private struct Reticle: Shape {
    func path(in rect: CGRect) -> Path {
      let arm = min(rect.width, rect.height) * 0.3
      var path = Path()
      for (corner, dx, dy) in [
        (CGPoint(x: rect.minX, y: rect.minY), 1.0, 1.0),
        (CGPoint(x: rect.maxX, y: rect.minY), -1.0, 1.0),
        (CGPoint(x: rect.minX, y: rect.maxY), 1.0, -1.0),
        (CGPoint(x: rect.maxX, y: rect.maxY), -1.0, -1.0),
      ] {
        path.move(to: CGPoint(x: corner.x + dx * arm, y: corner.y))
        path.addLine(to: corner)
        path.addLine(to: CGPoint(x: corner.x, y: corner.y + dy * arm))
      }
      return path
    }
  }
}
