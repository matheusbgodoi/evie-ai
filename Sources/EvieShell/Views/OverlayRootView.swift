import SwiftUI

/// The visual root for the transient overlay. It is bottom anchored so artifact
/// cards grow upward while the command capsule stays in a predictable position.
struct OverlayRootView: View {
  var state: EvieVisualState
  var primaryText: String
  var secondaryText: String? = nil
  var waveformSamples: [CGFloat] = []
  var artifacts: [ArtifactCardModel] = []
  var isMuted = false
  var onToggleMute: (() -> Void)? = nil
  var onCancel: (() -> Void)? = nil
  var onOpenDetails: (() -> Void)? = nil
  var onToggleArtifact: ((UUID) -> Void)? = nil
  var onDismissArtifact: ((UUID) -> Void)? = nil
  var onArtifactAction: ((UUID, ArtifactActionModel) -> Void)? = nil

  @Environment(\.accessibilityReduceMotion) private var reduceMotion

  var body: some View {
    VStack(spacing: 10) {
      Spacer(minLength: 0)

      artifactStack

      CommandCapsule(
        state: state,
        primaryText: primaryText,
        secondaryText: secondaryText,
        waveformSamples: waveformSamples,
        isMuted: isMuted,
        onToggleMute: onToggleMute,
        onCancel: onCancel,
        onOpenDetails: onOpenDetails
      )
    }
    .frame(maxWidth: 540, maxHeight: .infinity, alignment: .bottom)
    .padding(18)
    .animation(
      reduceMotion ? nil : .snappy(duration: 0.32, extraBounce: 0.05),
      value: artifacts.map(\.id)
    )
    .animation(reduceMotion ? nil : .smooth(duration: 0.2), value: state)
  }

  @ViewBuilder
  private var artifactStack: some View {
    if !artifacts.isEmpty {
      ScrollView(.vertical) {
        LazyVStack(spacing: 9) {
          ForEach(artifacts) { artifact in
            ArtifactCardView(
              artifact: artifact,
              onToggleExpanded: onToggleArtifact.map { handler in
                { handler(artifact.id) }
              },
              onDismiss: onDismissArtifact.map { handler in
                { handler(artifact.id) }
              },
              onAction: onArtifactAction.map { handler in
                { action in handler(artifact.id, action) }
              }
            )
            .transition(
              reduceMotion
                ? .opacity
                : .move(edge: .bottom).combined(with: .opacity)
            )
          }
        }
      }
      .scrollIndicators(.hidden)
      .defaultScrollAnchor(.bottom)
      .frame(maxHeight: 470)
      .mask {
        LinearGradient(
          stops: [
            .init(color: .clear, location: 0),
            .init(color: .black, location: 0.025),
            .init(color: .black, location: 1),
          ],
          startPoint: .top,
          endPoint: .bottom
        )
      }
    }
  }
}
