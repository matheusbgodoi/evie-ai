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
      artifacts: viewModel.artifacts,
      onCancel: viewModel.hasActiveRequest
        ? { viewModel.cancelCurrentInteraction() }
        : nil,
      onOpenDetails: viewModel.artifacts.isEmpty
        ? nil
        : { viewModel.expandLatestArtifact() },
      onToggleArtifact: { id in viewModel.toggleArtifact(id) },
      onDismissArtifact: { id in viewModel.dismissArtifact(id) },
      onArtifactAction: { id, action in
        viewModel.performArtifactAction(id, action: action)
      },
      quickText: viewModel.isQuickTextEntryPresented ? $viewModel.quickText : nil,
      onSubmitQuickText: viewModel.isQuickTextEntryPresented
        ? { viewModel.submitQuickText() }
        : nil,
      onCancelQuickText: viewModel.isQuickTextEntryPresented
        ? { viewModel.dismissQuickText() }
        : nil,
      onActivateVoice: { viewModel.requestVoiceActivation() },
      onAttachFiles: { urls in viewModel.attachFiles(at: urls) },
      onBrowseForFiles: { viewModel.browseForFiles() }
    )
  }
}
