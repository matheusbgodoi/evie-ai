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
      onArtifactHandAction: { id, action, press in
        viewModel.performArtifactPress(id, action: action, press: press)
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
      onRemoveAttachment: { viewModel.removeAttachment(id: $0) },
      onPasteAttachment: { viewModel.pasteAttachment() },
      brainChip: brainChip
    )
  }

  private var brainChip: BrainChipModel {
    BrainChipModel(
      chip: viewModel.brainChip,
      menu: viewModel.brainMenu,
      onChoose: { viewModel.chooseBrain($0) },
      onTestConnection: { viewModel.testBrainConnection() },
      onNewConversation: { viewModel.startNewConversation() },
      onSetAgentMode: viewModel.onSetAgentMode.map { set in { set($0) } },
      onOpenSettings: viewModel.onOpenSettingsSection.map { open in { open($0) } },
      onSetReasoning: { viewModel.onSetBrainReasoning?(viewModel.brainChip.profile.id, $0) },
      webEnabled: viewModel.isWebSearchEnabled(),
      onSetWebSearch: viewModel.onSetWebSearch.map { set in { set($0) } },
      isBusy: viewModel.hasActiveRequest || viewModel.isResearchBusy(),
      contextUsage: viewModel.contextUsageDescription,
      isCompacting: viewModel.isCompactingConversation
    )
  }
}
