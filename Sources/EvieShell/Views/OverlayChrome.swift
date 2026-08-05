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

/// The grip shown at the top of the overlay. It only becomes prominent on hover
/// so the resting HUD stays free of chrome.
struct OverlayGripHandle: View {
  var isHighlighted: Bool

  var body: some View {
    Capsule(style: .continuous)
      .fill(.secondary.opacity(isHighlighted ? 0.55 : 0.22))
      .frame(width: 38, height: 4)
      .overlay {
        WindowDragArea()
          .frame(width: 96, height: 18)
      }
      .help("Arraste para mover a Evie")
      .accessibilityLabel("Mover a janela da Evie")
  }
}

/// A thin vertical handle on one side of the overlay. Dragging it widens or
/// narrows the panel around its own centre.
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
  var isHighlighted: Bool
  var onDrag: (CGFloat) -> Void
  var onCommit: () -> Void

  var body: some View {
    Capsule(style: .continuous)
      .fill(.secondary.opacity(isHighlighted ? 0.5 : 0.16))
      .frame(width: 3, height: 30)
      .contentShape(Rectangle().inset(by: -7))
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
