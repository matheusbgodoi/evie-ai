import EvieCore
import SwiftUI

/// Which section the settings window shows, kept outside the view so the
/// overlay's chip and the menu bar can open the window on a section.
@MainActor
final class SettingsNavigation: ObservableObject {
  @Published var section: EvieSettingsSection = .general
}

/// The settings window: a sidebar of sections, in the style of System
/// Settings, and the section's panes beside it.
///
/// It was six tabs with segmented panes inside them, and the agent-mode switch
/// was the fourth pane of Avançado — the owner looked for it and did not find
/// it (2026-10-16). A sidebar has room for one row per question
/// (`EvieSettingsSection`), so the switch got a section of its own and the
/// folders left "O que ela sabe" for "Arquivos e pastas". Every pane that
/// existed is still here; only where it lives changed.
struct SettingsView: View {
  @ObservedObject var navigation: SettingsNavigation
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
    SettingsSplitView(selection: $navigation.section) { section in
      detail(for: section)
    }
    .settingsFeedback(
      preferencesViewModel.feedback?.message,
      isError: preferencesViewModel.feedback?.isError == true
    )
  }

  @ViewBuilder
  private func detail(for section: EvieSettingsSection) -> some View {
    switch section {
    case .general:
      GeneralSettingsView(
        updater: updater,
        brain: modelViewModel.activeProfile,
        isAgentModeOn: preferencesViewModel.preferences.computerUseEnabled,
        open: { navigation.section = $0 }
      )
    case .brain:
      ModelSettingsView(viewModel: modelViewModel)
    case .screenAndAgent:
      ScreenAndAgentSettingsView(
        viewModel: preferencesViewModel,
        permissionGuide: permissionGuide,
        setEnabled: preferencesViewModel.setComputerUseEnabled
      )
    case .filesAndFolders:
      FilesAndFoldersSettingsView(rootsViewModel: rootsViewModel)
    case .voice:
      VoiceTabView(
        wakeListener: wakeListener,
        preferencesViewModel: preferencesViewModel,
        libraryViewModel: voiceLibraryViewModel
      )
    case .shortcuts:
      ShortcutSettingsView(viewModel: preferencesViewModel)
    case .knowledge:
      KnowledgeTabView(
        preferencesViewModel: preferencesViewModel,
        schedulesViewModel: schedulesViewModel,
        memoryViewModel: memoryViewModel,
        skillsViewModel: skillsViewModel
      )
    case .appearance:
      AppearanceSettingsView(viewModel: preferencesViewModel)
    case .permissions:
      PermissionGuideView(viewModel: permissionGuide)
    case .advanced:
      DiagnosticsSettingsView(
        profile: modelViewModel.activeProfile,
        preferencesPath: preferencesPath,
        configurationPath: configurationPath
      )
    }
  }
}

/// The sidebar and the detail column, with no knowledge of any pane: the
/// detail is whatever `detail` draws for the selected section.
struct SettingsSplitView<Detail: View>: View {
  /// The window's minimum: the sidebar at its narrowest beside a grouped form
  /// that still fits its longest labels, and tall enough for a pane's first
  /// two sections.
  static var minimumSize: CGSize { CGSize(width: 780, height: 520) }

  @Binding var selection: EvieSettingsSection
  @ViewBuilder var detail: (EvieSettingsSection) -> Detail

  var body: some View {
    NavigationSplitView {
      SettingsSidebar(selection: $selection)
        .navigationSplitViewColumnWidth(min: 210, ideal: 220, max: 280)
        // The sidebar is the window's only navigation, as in System Settings;
        // hiding it would leave a pane with no way to the others.
        .toolbar(removing: .sidebarToggle)
    } detail: {
      detail(selection)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .navigationTitle(selection.title)
    }
    .navigationSplitViewStyle(.balanced)
    .frame(minWidth: Self.minimumSize.width, minHeight: Self.minimumSize.height)
  }
}

/// The list of sections.
struct SettingsSidebar: View {
  @Binding var selection: EvieSettingsSection

  var body: some View {
    List(
      EvieSettingsSection.allCases,
      selection: Binding<EvieSettingsSection?>(
        get: { selection },
        set: { if let section = $0 { selection = section } }
      )
    ) { section in
      SettingsSidebarRow(section: section)
        .tag(section)
    }
    .listStyle(.sidebar)
  }
}

/// One sidebar row: the section's symbol on a coloured tile, then its name —
/// the shape System Settings taught everyone to scan.
private struct SettingsSidebarRow: View {
  let section: EvieSettingsSection

  var body: some View {
    Label {
      Text(section.title)
    } icon: {
      SettingsSymbolTile(systemImage: section.systemImage, tint: section.tint)
    }
  }
}

/// A white SF Symbol on a rounded, coloured square.
struct SettingsSymbolTile: View {
  var systemImage: String
  var tint: Color
  var size: CGFloat = 20

  var body: some View {
    Image(systemName: systemImage)
      .font(.system(size: size * 0.52, weight: .semibold))
      .foregroundStyle(.white)
      .frame(width: size, height: size)
      .background(
        RoundedRectangle(cornerRadius: size * 0.24, style: .continuous)
          .fill(tint.gradient)
      )
      .accessibilityHidden(true)
  }
}

extension EvieSettingsSection {
  /// The tile's colour. Presentation, so it lives with the views rather than
  /// beside the section's name in EvieCore.
  var tint: Color {
    switch self {
    case .general: .gray
    case .brain: .purple
    // The agent's amber, the colour a session paints the screen edge.
    case .screenAndAgent: BrainChipPalette.agent
    case .filesAndFolders: .blue
    case .voice: .pink
    case .shortcuts: .gray
    case .knowledge: .indigo
    case .appearance: .teal
    case .permissions: .blue
    case .advanced: .gray
    }
  }
}

/// Geral: what is in use at a glance, with a way to each, and updates — the
/// way System Settings keeps Software Update in General.
struct GeneralSettingsView: View {
  @ObservedObject var updater: EvieUpdater
  var brain: EvieModelProfile
  var isAgentModeOn: Bool
  var open: (EvieSettingsSection) -> Void

  var body: some View {
    Form {
      Section {
        summaryRow(
          title: "Cérebro preferido",
          value: "\(brain.displayModelName) \(brain.location.answerPlace)",
          section: .brain
        )
        summaryRow(
          title: "Modo agente",
          value: isAgentModeOn ? "Ligado" : "Desligado",
          section: .screenAndAgent
        )
      } header: {
        Text("Evie")
      } footer: {
        Text(
          "O cérebro de cada conversa também aparece na barra onde você escreve; "
            + "clique nele para escolher outro ou testar a conexão."
        )
        .font(.footnote)
        .foregroundStyle(.secondary)
      }

      UpdateSettingsView(updater: updater)
    }
    .formStyle(.grouped)
  }

  private func summaryRow(title: String, value: String, section: EvieSettingsSection)
    -> some View
  {
    LabeledContent {
      HStack(spacing: 10) {
        Text(value)
          .foregroundStyle(.secondary)
        Button("Abrir") { open(section) }
          .controlSize(.small)
          .help("Abre \(section.path)")
      }
    } label: {
      Label {
        Text(title)
      } icon: {
        SettingsSymbolTile(systemImage: section.systemImage, tint: section.tint)
      }
    }
  }
}

/// Arquivos e pastas: which folders she may read, and the extension point for
/// what she may write.
///
/// Today it is the folders pane alone. The document tools (built on the
/// `v2-files` branch) add their options as a self-contained view — Sections,
/// such as `DocumentSettingsSection` — passed as `documents`; it then gets its
/// own segment, "Documentos", beside "Pastas", inside a grouped Form of its
/// own. Nothing else here has to change for it.
struct FilesAndFoldersSettingsView<Documents: View>: View {
  @ObservedObject var rootsViewModel: EvieRootsViewModel
  @ViewBuilder var documents: () -> Documents

  @State private var pane = 0

  var body: some View {
    if Documents.self == EmptyView.self {
      RootsSettingsView(viewModel: rootsViewModel)
    } else {
      VStack(spacing: 0) {
        PaneSelector(titles: ["Pastas", "Documentos"], selection: $pane)
        if pane == 0 {
          RootsSettingsView(viewModel: rootsViewModel)
        } else {
          Form {
            documents()
          }
          .formStyle(.grouped)
        }
      }
    }
  }
}

extension FilesAndFoldersSettingsView where Documents == EmptyView {
  init(rootsViewModel: EvieRootsViewModel) {
    self.init(rootsViewModel: rootsViewModel) { EmptyView() }
  }
}

/// One pane per question, chosen with a segmented control rather than a second
/// row of tabs, which macOS would draw as a second chrome bar.
struct PaneSelector: View {
  var titles: [String]
  @Binding var selection: Int

  var body: some View {
    // The label is empty on screen because the sidebar already names the
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

/// How she speaks, and which voices she has. One question, so one section.
struct VoiceTabView: View {
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

/// What she has been allowed to keep and to reach beyond the folders: memory,
/// skills, Mail and Calendar, and schedules. The folders moved to their own
/// section, Arquivos e pastas.
struct KnowledgeTabView: View {
  @ObservedObject var preferencesViewModel: EviePreferencesViewModel
  @ObservedObject var schedulesViewModel: EvieSchedulesViewModel
  @ObservedObject var memoryViewModel: EvieMemoryViewModel
  @ObservedObject var skillsViewModel: EvieSkillsViewModel

  var body: some View {
    VStack(spacing: 0) {
      PaneSelector(
        titles: ["Memória", "Habilidades", "Mail e agenda", "Agendamentos"],
        selection: $memoryViewModel.knowledgePane
      )
      switch memoryViewModel.knowledgePane {
      case 0:
        MemorySettingsView(viewModel: memoryViewModel)
      case 1:
        SkillsSettingsView(viewModel: skillsViewModel)
      case 2:
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
