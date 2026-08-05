import SwiftUI

/// The visual root for the transient overlay.
///
/// The stack sizes itself to its own content and reports that height upward, so
/// the panel is always exactly as tall as what is drawn. That is what keeps the
/// glass edges and the scroll fade from being sliced by a window that guessed
/// its own height.
struct OverlayRootView: View {
  /// Above this the artifact list scrolls instead of the window growing.
  private static let artifactViewportLimit: CGFloat = 470
  /// Transparent room kept around the content so the drop shadow and the grip
  /// are never clipped by the window frame.
  private static let outerPadding: CGFloat = 18

  @ObservedObject var chrome: OverlayChromeModel

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
  var quickText: Binding<String>? = nil
  var onSubmitQuickText: (() -> Void)? = nil
  var onCancelQuickText: (() -> Void)? = nil
  var onActivateVoice: (() -> Void)? = nil

  @Environment(\.accessibilityReduceMotion) private var reduceMotion

  var body: some View {
    VStack(spacing: 8) {
      chromeBar

      artifactStack

      bottomSurface
    }
    .frame(width: chrome.contentWidth)
    .padding(Self.outerPadding)
    .fixedSize(horizontal: false, vertical: true)
    .onHover { hovering in
      chrome.setShowingHandles(hovering)
    }
    .onGeometryChange(for: CGFloat.self) { proxy in
      proxy.size.height
    } action: { height in
      chrome.onMeasuredHeight?(height)
    }
    .animation(
      reduceMotion ? nil : .snappy(duration: 0.32, extraBounce: 0.05),
      value: artifacts.map(\.id)
    )
    .animation(reduceMotion ? nil : .smooth(duration: 0.2), value: state)
    .animation(reduceMotion ? nil : .easeOut(duration: 0.14), value: chrome.isShowingHandles)
  }

  /// Drag grip, width handles, and the reset control. It occupies a fixed height
  /// whether or not it is prominent, so revealing it never nudges the layout.
  private var chromeBar: some View {
    HStack(spacing: 10) {
      OverlayWidthHandle(
        side: .leading,
        isHighlighted: chrome.isShowingHandles,
        onDrag: { chrome.onWidthDrag?($0) },
        onCommit: { chrome.onWidthCommit?() }
      )

      Spacer(minLength: 0)

      OverlayGripHandle(isHighlighted: chrome.isShowingHandles)

      if !chrome.isUsingDefaultPlacement {
        OverlayResetPlacementButton {
          chrome.onResetPlacement?()
        }
        .transition(.opacity.combined(with: .scale(scale: 0.8)))
      }

      Spacer(minLength: 0)

      OverlayWidthHandle(
        side: .trailing,
        isHighlighted: chrome.isShowingHandles,
        onDrag: { chrome.onWidthDrag?($0) },
        onCommit: { chrome.onWidthCommit?() }
      )
    }
    .frame(height: 20)
    .opacity(chrome.isShowingHandles ? 1 : 0.26)
  }

  @ViewBuilder
  private var bottomSurface: some View {
    if let quickText,
      let onSubmitQuickText,
      let onCancelQuickText
    {
      QuickTextEntryView(
        text: quickText,
        state: state,
        waveformSamples: waveformSamples,
        isAnimating: chrome.isVisible && chrome.animatesLogo,
        onSubmit: onSubmitQuickText,
        onCancel: onCancelQuickText,
        onActivateVoice: onActivateVoice
      )
      .transition(.move(edge: .bottom).combined(with: .opacity))
    } else {
      CommandCapsule(
        state: state,
        primaryText: primaryText,
        secondaryText: secondaryText,
        waveformSamples: waveformSamples,
        isMuted: isMuted,
        isAnimating: chrome.isVisible && chrome.animatesLogo,
        onToggleMute: onToggleMute,
        onCancel: onCancel,
        onOpenDetails: onOpenDetails,
        onActivateVoice: onActivateVoice
      )
      .transition(.opacity)
    }
  }

  /// The card list. Its viewport is exactly the content height until the content
  /// exceeds the limit; only then does it scroll, and only then is the softening
  /// mask applied — a permanent mask would fade the top card for no reason.
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
        .onGeometryChange(for: CGFloat.self) { proxy in
          proxy.size.height
        } action: { height in
          chrome.setArtifactContentHeight(height)
        }
      }
      .scrollIndicators(.hidden)
      .scrollBounceBehavior(.basedOnSize)
      .defaultScrollAnchor(.bottom)
      .frame(height: artifactViewportHeight)
      .mask(scrollMask)
    }
  }

  private var artifactViewportHeight: CGFloat {
    guard chrome.artifactContentHeight > 0 else {
      return Self.artifactViewportLimit
    }
    return min(chrome.artifactContentHeight, Self.artifactViewportLimit)
  }

  private var isArtifactListOverflowing: Bool {
    chrome.artifactContentHeight > Self.artifactViewportLimit + 0.5
  }

  /// A long, symmetric fade. The previous 2.5% stop read as a hard cut because
  /// the gradient had no room to actually fade.
  @ViewBuilder
  private var scrollMask: some View {
    if isArtifactListOverflowing {
      LinearGradient(
        stops: [
          .init(color: .black.opacity(0), location: 0),
          .init(color: .black.opacity(0.35), location: 0.035),
          .init(color: .black, location: 0.13),
          .init(color: .black, location: 0.94),
          .init(color: .black.opacity(0.55), location: 0.985),
          .init(color: .black.opacity(0.2), location: 1),
        ],
        startPoint: .top,
        endPoint: .bottom
      )
    } else {
      Rectangle()
    }
  }
}
