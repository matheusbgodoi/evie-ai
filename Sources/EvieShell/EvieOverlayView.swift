import SwiftUI

struct EvieOverlayView: View {
  @ObservedObject var viewModel: OverlayViewModel

  var body: some View {
    content
  }

  @ViewBuilder
  private var content: some View {
    if viewModel.isQuickTextEntryPresented {
      VStack {
        Spacer(minLength: 0)
        QuickTextEntryView(
          text: $viewModel.quickText,
          endpointDescription: viewModel.endpointDescription,
          onSubmit: { viewModel.submitQuickText() },
          onCancel: { viewModel.dismissQuickText() }
        )
      }
      .frame(maxWidth: 540, maxHeight: .infinity)
      .padding(18)
    } else {
      OverlayRootView(
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
        }
      )
    }
  }
}
