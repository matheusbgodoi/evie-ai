import AppKit
import SwiftUI

/// A lightweight bridge to AppKit vibrancy. Keeping this view separate makes it
/// possible to use native macOS material without coupling the overlay to a
/// particular window implementation.
struct GlassVisualEffectView: NSViewRepresentable {
  var material: NSVisualEffectView.Material = .hudWindow
  var blendingMode: NSVisualEffectView.BlendingMode = .behindWindow
  var state: NSVisualEffectView.State = .active
  var isEmphasized = false

  func makeNSView(context: Context) -> NSVisualEffectView {
    let view = NSVisualEffectView()
    configure(view)
    return view
  }

  func updateNSView(_ view: NSVisualEffectView, context: Context) {
    configure(view)
  }

  private func configure(_ view: NSVisualEffectView) {
    view.material = material
    view.blendingMode = blendingMode
    view.state = state
    view.isEmphasized = isEmphasized
  }
}

/// A native glass container shared by the capsule and transient artifact cards.
/// It deliberately falls back to an opaque system color when Reduce Transparency
/// is enabled so content remains legible in every accessibility configuration.
struct GlassSurface<Content: View>: View {
  private let cornerRadius: CGFloat
  private let material: NSVisualEffectView.Material
  private let contentPadding: EdgeInsets
  private let tint: Color
  private let content: Content

  @Environment(\.accessibilityReduceTransparency) private var reduceTransparency
  @Environment(\.colorScheme) private var colorScheme

  init(
    cornerRadius: CGFloat = 22,
    material: NSVisualEffectView.Material = .hudWindow,
    contentPadding: EdgeInsets = EdgeInsets(
      top: 12,
      leading: 14,
      bottom: 12,
      trailing: 14
    ),
    tint: Color = .clear,
    @ViewBuilder content: () -> Content
  ) {
    self.cornerRadius = cornerRadius
    self.material = material
    self.contentPadding = contentPadding
    self.tint = tint
    self.content = content()
  }

  var body: some View {
    content
      .padding(contentPadding)
      .background {
        ZStack {
          if reduceTransparency {
            Color(nsColor: .windowBackgroundColor)
              .opacity(0.98)
          } else {
            GlassVisualEffectView(material: material)
          }

          LinearGradient(
            colors: [
              Color.white.opacity(colorScheme == .dark ? 0.055 : 0.16),
              tint.opacity(colorScheme == .dark ? 0.11 : 0.075),
              Color.black.opacity(colorScheme == .dark ? 0.065 : 0.018),
            ],
            startPoint: .topLeading,
            endPoint: .bottomTrailing
          )
        }
        .clipShape(surfaceShape)
      }
      .overlay {
        surfaceShape
          .strokeBorder(
            LinearGradient(
              colors: [
                Color.white.opacity(colorScheme == .dark ? 0.20 : 0.46),
                Color.white.opacity(0.055),
              ],
              startPoint: .topLeading,
              endPoint: .bottomTrailing
            ),
            lineWidth: 0.75
          )
      }
      .clipShape(surfaceShape)
      // Radius plus offset stays under the overlay's transparent margin, so the
      // shadow fades out instead of being sliced off at the window edge.
      .shadow(color: .black.opacity(colorScheme == .dark ? 0.30 : 0.15), radius: 16, y: 7)
  }

  private var surfaceShape: RoundedRectangle {
    RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
  }
}
