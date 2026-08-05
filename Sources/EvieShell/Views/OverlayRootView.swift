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
  /// Transparent room kept around the content so the rounded corners, the
  /// hairline border, and the drop shadow of the glass all have somewhere to go.
  ///
  /// It has to exceed the shadow's reach — radius plus vertical offset — or the
  /// shadow ends on a hard line at the window edge instead of fading out.
  private static let outerPadding: CGFloat = 30

  @ObservedObject var chrome: OverlayChromeModel

  var state: EvieVisualState
  var primaryText: String
  var secondaryText: String? = nil
  var waveformSamples: [CGFloat] = []
  var waveformNoiseFloor: CGFloat = 0
  var artifacts: [ArtifactCardModel] = []
  var isMuted = false
  var onToggleMute: (() -> Void)? = nil
  var onCancel: (() -> Void)? = nil
  var onOpenDetails: (() -> Void)? = nil
  var onToggleArtifact: ((UUID) -> Void)? = nil
  /// How many earlier turns of this conversation exist but are not drawn.
  var earlierTurnCount: Int = 0
  var onLoadEarlierTurns: (() -> Void)? = nil
  var onDismissArtifact: ((UUID) -> Void)? = nil
  var onArtifactAction: ((UUID, ArtifactActionModel) -> Void)? = nil
  var quickText: Binding<String>? = nil
  var onSubmitQuickText: (() -> Void)? = nil
  var onCancelQuickText: (() -> Void)? = nil
  var isProcessing = false
  var onActivateVoice: (() -> Void)? = nil
  var onAttachFiles: (([URL]) -> Void)? = nil
  var onBrowseForFiles: (() -> Void)? = nil

  @Environment(\.accessibilityReduceMotion) private var reduceMotion

  /// The glass is inset by the padding on both sides. Setting the frame to the
  /// full window width and *then* padding made the content 36 points wider than
  /// the window, so the card's corners, border, and side shadow were clipped away
  /// — which is what made the glass stop looking like glass.
  private var contentWidth: CGFloat {
    max(chrome.contentWidth - Self.outerPadding * 2, 120)
  }

  var body: some View {
    Group {
      if chrome.isCallMode {
        callSurface
      } else {
        writtenSurface
      }
    }
    .fixedSize(horizontal: false, vertical: true)
    // The window controls live in the transparent margin as overlays, so they
    // take no layout space and the resting overlay is exactly what it was before
    // they existed.
    .overlay(alignment: .top) { gripControls }
    .overlay(alignment: .leading) { widthHandle(.leading) }
    .overlay(alignment: .trailing) { widthHandle(.trailing) }
    .onHover { hovering in
      chrome.setShowingHandles(hovering)
    }
    .onGeometryChange(for: CGFloat.self) { proxy in
      proxy.size.height
    } action: { height in
      chrome.onMeasuredHeight?(height)
    }
    .dropDestination(for: URL.self) { urls, _ in
      guard let onAttachFiles, !urls.isEmpty else {
        return false
      }
      onAttachFiles(urls)
      return true
    }
    .animation(
      reduceMotion ? nil : .snappy(duration: 0.32, extraBounce: 0.05),
      value: artifacts.map(\.id)
    )
    .animation(reduceMotion ? nil : .smooth(duration: 0.2), value: state)
    .animation(reduceMotion ? nil : .easeOut(duration: 0.16), value: chrome.isShowingHandles)
    .animation(reduceMotion ? nil : .smooth(duration: 0.28), value: chrome.isCallMode)
  }

  /// A call: her mark and the waves around it, and nothing else on screen. No
  /// transcript, no cards, no field — which is the entire point of the mode.
  private var callSurface: some View {
    EvieMarkView(
      state: state,
      waveformSamples: waveformSamples,
      diameter: 92,
      isAnimating: chrome.isVisible && chrome.animatesLogo,
      onActivate: onActivateVoice
    )
    .frame(width: contentWidth, height: 150)
    .padding(Self.outerPadding)
    .transition(.scale(scale: 0.9).combined(with: .opacity))
  }

  private var writtenSurface: some View {
    VStack(spacing: 10) {
      artifactStack

      bottomSurface
    }
    .frame(width: contentWidth)
    .padding(Self.outerPadding)
    .fixedSize(horizontal: false, vertical: true)
    // The window controls live in the transparent margin as overlays, so they
    // take no layout space and the resting overlay is exactly what it was before
    // they existed.
    .overlay(alignment: .top) { gripControls }
    .overlay(alignment: .leading) { widthHandle(.leading) }
    .overlay(alignment: .trailing) { widthHandle(.trailing) }
    .onHover { hovering in
      chrome.setShowingHandles(hovering)
    }
    .dropDestination(for: URL.self) { urls, _ in
      guard let onAttachFiles, !urls.isEmpty else {
        return false
      }
      onAttachFiles(urls)
      return true
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
    .animation(reduceMotion ? nil : .easeOut(duration: 0.16), value: chrome.isShowingHandles)
  }

  /// Drag grip and the reset control, invisible until the pointer is over the
  /// overlay. They still respond to the mouse while invisible, which is what
  /// makes the whole top margin a drag area.
  private var gripControls: some View {
    HStack(spacing: 8) {
      OverlayGripHandle(isHighlighted: chrome.isShowingHandles)

      if !chrome.isUsingDefaultPlacement {
        OverlayResetPlacementButton {
          chrome.onResetPlacement?()
        }
        .transition(.opacity.combined(with: .scale(scale: 0.8)))
      }
    }
    .padding(.top, 5)
    .opacity(chrome.isShowingHandles ? 1 : 0)
  }

  private func widthHandle(_ side: OverlayWidthHandle.Side) -> some View {
    OverlayWidthHandle(
      side: side,
      onDrag: { chrome.onWidthDrag?($0) },
      onCommit: { chrome.onWidthCommit?() }
    )
    .padding(side == .leading ? .leading : .trailing, 5)
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
        isProcessing: isProcessing,
        onSubmit: onSubmitQuickText,
        onCancel: onCancelQuickText,
        onStop: onCancel,
        onActivateVoice: onActivateVoice,
        onBrowseForFiles: onBrowseForFiles
      )
      .transition(.move(edge: .bottom).combined(with: .opacity))
    } else {
      CommandCapsule(
        state: state,
        primaryText: primaryText,
        secondaryText: secondaryText,
        waveformSamples: waveformSamples,
        waveformNoiseFloor: waveformNoiseFloor,
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
          // At the top of the list rather than in a menu: scrolling up to look
          // for what was said earlier is the gesture that means "show me more",
          // and this is where that gesture ends.
          if earlierTurnCount > 0, let onLoadEarlierTurns {
            Button(action: onLoadEarlierTurns) {
              Label(
                earlierTurnCount == 1
                  ? "Ver 1 mensagem anterior"
                  : "Ver \(min(earlierTurnCount, OverlayViewModel.artifactPageSize)) mensagens anteriores",
                systemImage: "arrow.up"
              )
              .font(.system(size: 11, weight: .medium))
              .foregroundStyle(.secondary)
              .frame(maxWidth: .infinity)
              .padding(.vertical, 7)
            }
            .buttonStyle(.plain)
            .background(.quaternary.opacity(0.28), in: Capsule())
          }

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
    }
  }

  private var artifactViewportHeight: CGFloat {
    guard chrome.artifactContentHeight > 0 else {
      return Self.artifactViewportLimit
    }
    return min(chrome.artifactContentHeight, Self.artifactViewportLimit)
  }
}
