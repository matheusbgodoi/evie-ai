import EvieCore
import SwiftUI

/// The settings window.
///
/// Six tabs, not eight. macOS gives a tab bar a fixed amount of room and folds
/// whatever does not fit into an overflow menu, so growing the window one tab at
/// a time silently replaced the bar with a chevron and a list — every pane one
/// click further away than it had been. Panes that answer the same question now
/// share a tab and are separated inside it.
///
/// "Cérebro" is the sixth, moved out of Avançado: with the PC as the default
/// brain, its key is the first thing a fresh install needs, and every "O PC não
/// respondeu" points there. Not verified on screen that six fit at the minimum
/// width without the overflow chevron; the labels are short for that reason.
struct SettingsView: View {
  @ObservedObject var modelViewModel: ModelSettingsViewModel
  @ObservedObject var preferencesViewModel: EviePreferencesViewModel
  @ObservedObject var rootsViewModel: EvieRootsViewModel
  @ObservedObject var voiceLibraryViewModel: EvieVoiceLibraryViewModel
  @ObservedObject var memoryViewModel: EvieMemoryViewModel
  @ObservedObject var skillsViewModel: EvieSkillsViewModel
  @ObservedObject var updater: EvieUpdater
  @ObservedObject var wakeListener: EvieWakeListener
  @ObservedObject var schedulesViewModel: EvieSchedulesViewModel
  @ObservedObject var permissionGuide: PermissionGuideViewModel
  var preferencesPath: String = EviePreferencesStore.defaultFileURL.path
  var configurationPath: String = EvieConfigurationLoader.defaultFileURL.path

  var body: some View {
    TabView {
      ShortcutSettingsView(viewModel: preferencesViewModel)
        .tabItem { Label("Atalhos", systemImage: "keyboard") }

      VoiceTabView(
        wakeListener: wakeListener,
        preferencesViewModel: preferencesViewModel,
        libraryViewModel: voiceLibraryViewModel
      )
      .tabItem { Label("Voz", systemImage: "waveform") }

      KnowledgeTabView(
        preferencesViewModel: preferencesViewModel,
        schedulesViewModel: schedulesViewModel,
        rootsViewModel: rootsViewModel,
        memoryViewModel: memoryViewModel,
        skillsViewModel: skillsViewModel
      )
      .tabItem { Label("O que ela sabe", systemImage: "books.vertical") }

      ModelSettingsView(viewModel: modelViewModel)
        .tabItem { Label("Cérebro", systemImage: "brain") }

      AppearanceSettingsView(viewModel: preferencesViewModel)
        .tabItem { Label("Aparência", systemImage: "macwindow") }

      AdvancedTabView(
        updater: updater,
        modelViewModel: modelViewModel,
        preferencesViewModel: preferencesViewModel,
        permissionGuide: permissionGuide,
        preferencesPath: preferencesPath,
        configurationPath: configurationPath
      )
      .tabItem { Label("Avançado", systemImage: "gearshape.2") }
    }
    .frame(minWidth: 680, minHeight: 600)
    .settingsFeedback(
      preferencesViewModel.feedback?.message,
      isError: preferencesViewModel.feedback?.isError == true
    )
  }
}

/// One pane per question, chosen with a segmented control rather than a second
/// row of tabs, which macOS would draw as a second chrome bar.
private struct PaneSelector: View {
  var titles: [String]
  @Binding var selection: Int

  var body: some View {
    // The label is empty on screen because the tab above already names the
    // subject, but a picker with no label at all is an unnamed control to
    // VoiceOver, so the name is given and then hidden rather than omitted.
    Picker("Seção", selection: $selection) {
      ForEach(Array(titles.enumerated()), id: \.offset) { index, title in
        Text(title).tag(index)
      }
    }
    .pickerStyle(.segmented)
    .labelsHidden()
    .accessibilityLabel("Seção")
    .padding(.horizontal, 20)
    .padding(.top, 12)
  }
}

/// How she speaks, and which voices she has. One question, so one tab.
private struct VoiceTabView: View {
  @ObservedObject var wakeListener: EvieWakeListener
  @ObservedObject var preferencesViewModel: EviePreferencesViewModel
  @ObservedObject var libraryViewModel: EvieVoiceLibraryViewModel

  var body: some View {
    VStack(spacing: 0) {
      PaneSelector(
        titles: ["Como ela fala", "Vozes"],
        selection: $preferencesViewModel.voicePane
      )
      if preferencesViewModel.voicePane == 0 {
        VoiceSettingsView(viewModel: preferencesViewModel, wakeListener: wakeListener)
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
  @ObservedObject var preferencesViewModel: EviePreferencesViewModel
  @ObservedObject var schedulesViewModel: EvieSchedulesViewModel
  @ObservedObject var rootsViewModel: EvieRootsViewModel
  @ObservedObject var memoryViewModel: EvieMemoryViewModel
  @ObservedObject var skillsViewModel: EvieSkillsViewModel

  var body: some View {
    VStack(spacing: 0) {
      PaneSelector(
        titles: ["Pastas", "Memória", "Habilidades", "Mail e agenda", "Agendamentos"],
        selection: $memoryViewModel.knowledgePane
      )
      switch memoryViewModel.knowledgePane {
      case 0:
        RootsSettingsView(viewModel: rootsViewModel)
      case 1:
        MemorySettingsView(viewModel: memoryViewModel)
      case 2:
        SkillsSettingsView(viewModel: skillsViewModel)
      case 3:
        MailCalendarSettingsView(
          viewModel: preferencesViewModel,
          setEnabled: preferencesViewModel.setMailAndCalendarEnabled
        )
      default:
        SchedulesSettingsView(viewModel: schedulesViewModel)
      }
    }
  }
}

/// The panes nobody opens until something is wrong.
///
/// "Permissões" is here rather than in a tab of its own: after the first-run
/// window has been closed, the checklist is something you come back to when a
/// feature stops working, which is what this tab is for. "Controle do Mac"
/// sits beside it: the agent-mode switch comes on, so this is where it is
/// turned off, next to the Accessibility grant it depends on.
private struct AdvancedTabView: View {
  @ObservedObject var updater: EvieUpdater
  @ObservedObject var modelViewModel: ModelSettingsViewModel
  @ObservedObject var preferencesViewModel: EviePreferencesViewModel
  @ObservedObject var permissionGuide: PermissionGuideViewModel
  var preferencesPath: String
  var configurationPath: String

  var body: some View {
    VStack(spacing: 0) {
      PaneSelector(
        titles: ["Diagnóstico", "Atualizar", "Permissões", "Controle do Mac"],
        selection: $modelViewModel.advancedPane
      )
      switch modelViewModel.advancedPane {
      case 1:
        UpdateSettingsView(updater: updater)
      case 2:
        PermissionGuideView(viewModel: permissionGuide)
      case 3:
        ComputerUseSettingsView(
          viewModel: preferencesViewModel,
          setEnabled: preferencesViewModel.setComputerUseEnabled
        )
      default:
        DiagnosticsSettingsView(
          profile: modelViewModel.activeProfile,
          preferencesPath: preferencesPath,
          configurationPath: configurationPath
        )
      }
    }
  }
}
