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
  @Environment(\.colorSchemeContrast) private var contrast

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
    surface
      // Keep the shadow inside the overlay's existing transparent margin.
      .shadow(color: .black.opacity(colorScheme == .dark ? 0.24 : 0.12), radius: 14, y: 6)
  }

  /// Glass belongs to the floating controls, while reading surfaces retain a
  /// thicker popover material. One native effect per surface, no animated blur,
  /// shaders, timers, or nested glass layers.
  @ViewBuilder
  private var surface: some View {
    if material == .hudWindow, !requiresSolidSurface {
      content
        .padding(contentPadding)
        .glassEffect(.regular.tint(tint.opacity(0.08)), in: surfaceShape)
    } else {
      content
        .padding(contentPadding)
        .background {
          ZStack {
            if requiresSolidSurface {
              Color(nsColor: .windowBackgroundColor)
            } else {
              GlassVisualEffectView(material: material)
              // Answers need a quiet, legible field even over a busy desktop.
              Color(nsColor: .windowBackgroundColor).opacity(0.42)
              tint.opacity(colorScheme == .dark ? 0.045 : 0.025)
            }
          }
          .clipShape(surfaceShape)
        }
        .overlay {
          surfaceShape.strokeBorder(
            requiresSolidSurface
              ? Color.primary.opacity(0.35)
              : Color.primary.opacity(colorScheme == .dark ? 0.13 : 0.10),
            lineWidth: requiresSolidSurface ? 1 : 0.75
          )
        }
        .clipShape(surfaceShape)
    }
  }

  private var requiresSolidSurface: Bool {
    reduceTransparency || contrast == .increased
  }

  private var surfaceShape: RoundedRectangle {
    RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
  }
}
