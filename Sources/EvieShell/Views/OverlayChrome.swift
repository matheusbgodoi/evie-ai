import AppKit
import SwiftUI

/// A transparent strip that hands the mouse straight to AppKit's own window
/// drag. Using `performDrag(with:)` keeps multi-display behaviour, momentum, and
/// Spaces handling identical to a normal titlebar without making the panel key.
struct WindowDragArea: NSViewRepresentable {
  func makeNSView(context: Context) -> NSView {
    DragCatchingView()
  }

  func updateNSView(_ nsView: NSView, context: Context) {}
}

private final class DragCatchingView: NSView {
  override var mouseDownCanMoveWindow: Bool { true }

  override func mouseDown(with event: NSEvent) {
    window?.performDrag(with: event)
  }

  override func resetCursorRects() {
    addCursorRect(bounds, cursor: .openHand)
  }
}

/// The grip shown at the top of the overlay, and the only window control that
/// draws anything at all.
struct OverlayGripHandle: View {
  var isHighlighted: Bool

  var body: some View {
    // Draws nothing at all. The cursor turning into an open hand over the top
    // margin is the affordance; a grey dash floating above the capsule was just
    // debris on screen.
    Color.clear
      .frame(width: 96, height: 16)
      .overlay {
        WindowDragArea()
          .frame(width: 96, height: 18)
      }
      .help("Arraste para mover a Evie")
      .accessibilityLabel("Mover a janela da Evie")
  }
}

/// An invisible strip down each side of the overlay. Dragging it widens or
/// narrows the panel around its own centre.
///
/// Deliberately draws nothing. A visible bar on each edge of a floating HUD reads
/// as two stray white lines; the pointer changing to a resize cursor is the whole
/// affordance, and it is the one macOS uses for window edges anyway.
///
/// The gesture reports the total travel since it began; the controller keeps the
/// starting width, which leaves this view free of local state.
struct OverlayWidthHandle: View {
  enum Side {
    case leading
    case trailing

    var sign: CGFloat {
      switch self {
      case .leading: -1
      case .trailing: 1
      }
    }
  }

  var side: Side
  var onDrag: (CGFloat) -> Void
  var onCommit: () -> Void

  var body: some View {
    Color.clear
      .frame(width: 10, height: 44)
      .contentShape(Rectangle())
      .gesture(
        DragGesture(minimumDistance: 1)
          .onChanged { value in
            // Both edges move away from the centre, so one point of pointer
            // travel is two points of width.
            onDrag(side.sign * value.translation.width * 2)
          }
          .onEnded { _ in
            onCommit()
          }
      )
      .onHover { hovering in
        if hovering {
          NSCursor.resizeLeftRight.push()
        } else {
          NSCursor.pop()
        }
      }
      .help("Arraste para mudar a largura")
      .accessibilityLabel("Ajustar a largura da Evie")
  }
}

/// Restores the anchored bottom-centre position and the original width. It only
/// appears once the window has actually been moved or resized.
struct OverlayResetPlacementButton: View {
  var action: () -> Void

  var body: some View {
    Button(action: action) {
      Image(systemName: "arrow.counterclockwise")
        .font(.system(size: 9, weight: .bold))
        .frame(width: 20, height: 20)
        .contentShape(Circle())
    }
    .buttonStyle(.plain)
    .foregroundStyle(.secondary)
    .background(.white.opacity(0.07), in: Circle())
    .help("Voltar para a posição e a largura padrão")
    .accessibilityLabel("Voltar ao tamanho e posição padrão")
  }
}
