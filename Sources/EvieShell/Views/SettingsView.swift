import EvieCore
import SwiftUI

/// The settings window.
///
/// Five tabs, not eight. macOS gives a tab bar a fixed amount of room and folds
/// whatever does not fit into an overflow menu, so growing the window one tab at
/// a time silently replaced the bar with a chevron and a list — every pane one
/// click further away than it had been. Panes that answer the same question now
/// share a tab and are separated inside it.
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

      VoiceTabView(
        preferencesViewModel: preferencesViewModel,
        libraryViewModel: voiceLibraryViewModel
      )
      .tabItem { Label("Voz", systemImage: "waveform") }

      KnowledgeTabView(
        rootsViewModel: rootsViewModel,
        memoryViewModel: memoryViewModel
      )
      .tabItem { Label("O que ela sabe", systemImage: "books.vertical") }

      AppearanceSettingsView(viewModel: preferencesViewModel)
        .tabItem { Label("Aparência", systemImage: "macwindow") }

      AdvancedTabView(
        modelViewModel: modelViewModel,
        preferencesPath: preferencesPath,
        configurationPath: configurationPath
      )
      .tabItem { Label("Avançado", systemImage: "gearshape.2") }
    }
    .frame(minWidth: 680, minHeight: 600)
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

/// One pane per question, chosen with a segmented control rather than a second
/// row of tabs, which macOS would draw as a second chrome bar.
private struct PaneSelector: View {
  var titles: [String]
  @Binding var selection: Int

  var body: some View {
    Picker("", selection: $selection) {
      ForEach(Array(titles.enumerated()), id: \.offset) { index, title in
        Text(title).tag(index)
      }
    }
    .pickerStyle(.segmented)
    .labelsHidden()
    .padding(.horizontal, 20)
    .padding(.top, 12)
  }
}

/// How she speaks, and which voices she has. One question, so one tab.
private struct VoiceTabView: View {
  @ObservedObject var preferencesViewModel: EviePreferencesViewModel
  @ObservedObject var libraryViewModel: EvieVoiceLibraryViewModel

  var body: some View {
    VStack(spacing: 0) {
      PaneSelector(
        titles: ["Como ela fala", "Vozes"],
        selection: $preferencesViewModel.voicePane
      )
      if preferencesViewModel.voicePane == 0 {
        VoiceSettingsView(viewModel: preferencesViewModel)
      } else {
        VoiceLibraryView(
          viewModel: libraryViewModel,
          onPreview: { preferencesViewModel.testVoice() }
        )
      }
    }
  }
}

/// What she can reach, and what she has been allowed to keep.
private struct KnowledgeTabView: View {
  @ObservedObject var rootsViewModel: EvieRootsViewModel
  @ObservedObject var memoryViewModel: EvieMemoryViewModel

  var body: some View {
    VStack(spacing: 0) {
      PaneSelector(
        titles: ["Pastas", "Memória"],
        selection: $memoryViewModel.knowledgePane
      )
      if memoryViewModel.knowledgePane == 0 {
        RootsSettingsView(viewModel: rootsViewModel)
      } else {
        MemorySettingsView(viewModel: memoryViewModel)
      }
    }
  }
}

/// The two panes nobody opens until something is wrong.
private struct AdvancedTabView: View {
  @ObservedObject var modelViewModel: ModelSettingsViewModel
  var preferencesPath: String
  var configurationPath: String

  var body: some View {
    VStack(spacing: 0) {
      PaneSelector(
        titles: ["Modelo", "Diagnóstico"],
        selection: $modelViewModel.advancedPane
      )
      if modelViewModel.advancedPane == 0 {
        ModelSettingsView(viewModel: modelViewModel)
      } else {
        DiagnosticsSettingsView(
          modelName: modelViewModel.model,
          endpoint: modelViewModel.endpoint,
          contextWindowTokens: modelViewModel.contextWindowTokens,
          preferencesPath: preferencesPath,
          configurationPath: configurationPath
        )
      }
    }
  }
}
