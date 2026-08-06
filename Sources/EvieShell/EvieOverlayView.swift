import SwiftUI

struct EvieOverlayView: View {
  @ObservedObject var viewModel: OverlayViewModel
  @ObservedObject var chrome: OverlayChromeModel

  var body: some View {
    OverlayRootView(
      chrome: chrome,
      state: viewModel.visualState,
      primaryText: viewModel.primaryText,
      secondaryText: viewModel.secondaryText,
      waveformSamples: viewModel.waveformSamples,
      waveformNoiseFloor: viewModel.waveformNoiseFloor,
      artifacts: viewModel.artifacts,
      onCancel: viewModel.hasActiveRequest
        ? { viewModel.cancelCurrentInteraction() }
        : nil,
      onOpenDetails: viewModel.artifacts.isEmpty
        ? nil
        : { viewModel.expandLatestArtifact() },
      onToggleArtifact: { id in viewModel.toggleArtifact(id) },
      earlierTurnCount: viewModel.earlierTurnCount,
      onLoadEarlierTurns: { viewModel.loadEarlierTurns() },
      onDismissArtifact: { id in viewModel.dismissArtifact(id) },
      onArtifactAction: { id, action in
        viewModel.performArtifactAction(id, action: action)
      },
      quickText: viewModel.isQuickTextEntryPresented ? $viewModel.quickText : nil,
      onSubmitQuickText: viewModel.isQuickTextEntryPresented
        ? { viewModel.submitTypedText() }
        : nil,
      onCancelQuickText: viewModel.isQuickTextEntryPresented
        ? { viewModel.dismissQuickText() }
        : nil,
      isProcessing: viewModel.hasActiveRequest,
      onActivateVoice: { viewModel.requestVoiceActivation() },
      onAttachFiles: { urls in viewModel.attachFiles(at: urls) },
      onBrowseForFiles: { viewModel.browseForFiles() },
      commandSuggestions: viewModel.commandSuggestions,
      highlightedCommand: viewModel.commandHighlight,
      onMoveCommandHighlight: { viewModel.moveCommandHighlight(by: $0) },
      onCompleteCommand: { viewModel.completeCommand() },
      onDismissCommands: { viewModel.dismissCommandMenu() },
      attachments: viewModel.attachmentSlots,
      onRemoveAttachment: { viewModel.removeAttachment(id: $0) }
    )
  }
}
