import EvieCore
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
  /// Room kept *inside* the scrolling area so a card's shadow has somewhere to
  /// fall.
  ///
  /// A `ScrollView` clips its content, and a clipped shadow ends on a straight
  /// line — which is why the cards had a hard dark edge while the text field,
  /// which is not inside a scroller, faded out properly. The content is inset by
  /// this much and the scroller is pulled back out by the same amount, so the
  /// cards sit exactly where they did and the shadow is no longer sliced.
  ///
  /// Sized from what the shadow actually reaches: radius 16 plus a 7pt vertical
  /// offset is 23 downwards. It has to stay under `outerPadding`, or the problem
  /// simply moves to the window edge.
  private static let artifactShadowMargin: CGFloat = 24

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
  var commandSuggestions: [EvieCommand] = []
  var highlightedCommand = 0
  var onMoveCommandHighlight: ((Int) -> Void)? = nil
  var onCompleteCommand: (() -> Void)? = nil
  var onDismissCommands: (() -> Void)? = nil

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

  /// The drag grip, invisible until the pointer is over the overlay. It still
  /// responds to the mouse while invisible, which is what makes the whole top
  /// margin a drag area.
  ///
  /// It used to sit next to a button that restored the default size and
  /// position, which appeared the moment the overlay was resized — so making the
  /// window the shape you wanted was rewarded with a permanent control offering
  /// to undo it. The same thing lives in Settings › Aparência, where undoing a
  /// deliberate change belongs.
  private var gripControls: some View {
    OverlayGripHandle(isHighlighted: chrome.isShowingHandles)
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
        onBrowseForFiles: onBrowseForFiles,
        commandSuggestions: commandSuggestions,
        highlightedCommand: highlightedCommand,
        onMoveCommandHighlight: onMoveCommandHighlight,
        onCompleteCommand: onCompleteCommand,
        onDismissCommands: onDismissCommands
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
        // Measured before the padding is applied, so the viewport height stays
        // the height of the cards rather than the cards plus their breathing
        // room.
        .onGeometryChange(for: CGFloat.self) { proxy in
          proxy.size.height
        } action: { height in
          chrome.setArtifactContentHeight(height)
        }
        .padding(Self.artifactShadowMargin)
      }
      .scrollIndicators(.hidden)
      .scrollBounceBehavior(.basedOnSize)
      .defaultScrollAnchor(.bottom)
      .frame(height: artifactViewportHeight + Self.artifactShadowMargin * 2)
      .padding(-Self.artifactShadowMargin)
      // Laid over the cards rather than stacked above them. In the flow it would
      // push every card down the instant the pointer arrived, which moves the
      // card out from under the pointer, which ends the hover, which puts it
      // back — a flicker loop. Floating it costs nothing and cannot do that.
      .overlay(alignment: .top) { earlierTurnsControl }
      .onHover { chrome.isPointerOverArtifacts = $0 }
    }
  }

  /// The way back to what was said before.
  ///
  /// Hidden until the pointer is over the answer, because asking something new
  /// is meant to leave that one answer on screen and nothing else. The history is
  /// not gone; it has stopped being furniture.
  @ViewBuilder
  private var earlierTurnsControl: some View {
    if earlierTurnCount > 0, let onLoadEarlierTurns, chrome.isPointerOverArtifacts {
      Button(action: onLoadEarlierTurns) {
        Label(
          earlierTurnCount == 1
            ? "Ver 1 mensagem anterior"
            : "Ver \(min(earlierTurnCount, OverlayViewModel.artifactPageSize)) mensagens anteriores",
          systemImage: "arrow.up"
        )
        .font(.system(size: 11, weight: .medium))
        .foregroundStyle(.secondary)
        .padding(.horizontal, 12)
        .padding(.vertical, 6)
      }
      .buttonStyle(.plain)
      .background(.ultraThinMaterial, in: Capsule())
      .overlay(Capsule().strokeBorder(.white.opacity(0.10), lineWidth: 0.75))
      .transition(.opacity)
      .padding(.top, 2)
    }
  }

  private var artifactViewportHeight: CGFloat {
    guard chrome.artifactContentHeight > 0 else {
      return Self.artifactViewportLimit
    }
    return min(chrome.artifactContentHeight, Self.artifactViewportLimit)
  }
}
