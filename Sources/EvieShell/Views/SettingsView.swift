import EvieCore
import SwiftUI

/// The settings window.
///
/// Tabs rather than one long form: shortcuts, voice, and appearance are things
/// the user changes deliberately and separately, and burying them under model
/// sampling is what made them unreachable before.
struct SettingsView: View {
  @ObservedObject var modelViewModel: ModelSettingsViewModel
  @ObservedObject var preferencesViewModel: EviePreferencesViewModel
  @ObservedObject var rootsViewModel: EvieRootsViewModel
  @ObservedObject var voiceLibraryViewModel: EvieVoiceLibraryViewModel
  @ObservedObject var memoryViewModel: EvieMemoryViewModel
  var preferencesPath: String = EviePreferencesStore.defaultFileURL.path
  var configurationPath: String = EvieConfigurationLoader.defaultFileURL.path

  var body: some View {
    TabView {
      ShortcutSettingsView(viewModel: preferencesViewModel)
        .tabItem { Label("Atalhos", systemImage: "keyboard") }

      RootsSettingsView(viewModel: rootsViewModel)
        .tabItem { Label("Pastas", systemImage: "folder") }

      VoiceSettingsView(viewModel: preferencesViewModel)
        .tabItem { Label("Voz", systemImage: "waveform") }

      VoiceLibraryView(
        viewModel: voiceLibraryViewModel,
        onPreview: { preferencesViewModel.testVoice() }
      )
      .tabItem { Label("Vozes", systemImage: "person.wave.2") }

      MemorySettingsView(viewModel: memoryViewModel)
        .tabItem { Label("Memória", systemImage: "brain") }

      AppearanceSettingsView(viewModel: preferencesViewModel)
        .tabItem { Label("Aparência", systemImage: "macwindow") }

      ModelSettingsView(viewModel: modelViewModel)
        .tabItem { Label("Modelo", systemImage: "cpu") }

      DiagnosticsSettingsView(
        modelName: modelViewModel.model,
        endpoint: modelViewModel.endpoint,
        contextWindowTokens: modelViewModel.contextWindowTokens,
        preferencesPath: preferencesPath,
        configurationPath: configurationPath
      )
      .tabItem { Label("Diagnóstico", systemImage: "stethoscope") }
    }
    .frame(minWidth: 660, minHeight: 560)
    .safeAreaInset(edge: .bottom) {
      if let feedback = preferencesViewModel.feedback {
        Label(
          feedback.message,
          systemImage: feedback.isError
            ? "exclamationmark.triangle.fill"
            : "checkmark.circle.fill"
        )
        .font(.callout)
        .foregroundStyle(feedback.isError ? .red : .secondary)
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, 16)
        .padding(.vertical, 9)
        .background(.bar)
      }
    }
  }
}
