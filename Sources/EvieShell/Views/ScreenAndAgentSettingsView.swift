import EvieCore
import SwiftUI

/// Settings › Tela e modo agente: the agent-mode switch, the grants it and the
/// screen look depend on, and the screen-look shortcut.
///
/// The switch used to be the fourth pane of Avançado, and the owner could not
/// find it (2026-10-16). It is the first thing here now, large, with what it
/// does, what it never does and how to stop it in one paragraph. It ships off
/// and never starts anything by itself: each session still begins with a key
/// held or a button clicked and a confirm on the session card, and lasts at
/// most 15 minutes (ADR 0016). `EVIE_COMPUTER_USE=0` turns it off for one
/// launch, whatever is set here, and the pane says so.
///
/// The setter arrives from outside, as in `MailCalendarSettingsView`, so the
/// write goes through the view model's feedback line.
struct ScreenAndAgentSettingsView: View {
  @ObservedObject var viewModel: EviePreferencesViewModel
  @ObservedObject var permissionGuide: PermissionGuideViewModel
  var setEnabled: @MainActor @Sendable (Bool) -> Void
  var environment: [String: String] = ProcessInfo.processInfo.environment

  /// The grants this pane depends on: the screen for looking, Accessibility
  /// and input events for acting.
  static let permissionRows: Set<String> = [
    EviePermission.screenRecording.rawValue,
    EviePermission.accessibility.rawValue,
    EviePermission.postEvents.rawValue,
  ]

  private var forcedOff: Bool {
    ComputerUseSwitch.forcedOff(environment: environment)
  }

  private var isOn: Bool {
    viewModel.preferences.computerUseEnabled
  }

  var body: some View {
    Form {
      Section {
        agentSwitch
        Text(
          ComputerUseCopy.settingsExplanation(
            stopShortcut: viewModel.shortcut(for: .emergencyStop)?.displayString)
        )
        .font(.callout)
        .foregroundStyle(.secondary)
        .fixedSize(horizontal: false, vertical: true)
        if forcedOff {
          Label(
            "Desligado nesta execução por EVIE_COMPUTER_USE=0, seja qual for este ajuste.",
            systemImage: "exclamationmark.triangle.fill"
          )
          .font(.footnote)
          .symbolRenderingMode(.hierarchical)
          .foregroundStyle(.orange)
        }
      }

      Section {
        PermissionGuideRowsView(viewModel: permissionGuide, only: Self.permissionRows)
      } header: {
        Text("Permissões")
      } footer: {
        Text(
          "Gravação de tela também é o que ela usa para olhar a tela quando você pede, "
            + "com o modo agente ligado ou não."
        )
        .font(.footnote)
        .foregroundStyle(.secondary)
      }

      Section {
        ShortcutRow(action: .lookAtScreen, viewModel: viewModel)
      } header: {
        Text("Olhar a tela")
      }

      Section {
        Text(
          """
          O que aparece na tela é escrito por quem fez a página ou o app. A \
          Evie trata isso como informação, nunca como ordem, e as regras que \
          decidem o que ela pode fazer estão no código, não no modelo — isso \
          reduz o risco de uma página tentar comandá-la, mas não o elimina.
          """
        )
        .font(.footnote)
        .foregroundStyle(.secondary)
      } header: {
        Text("O que a tela pode tentar")
      }
    }
    .formStyle(.grouped)
    .onAppear { permissionGuide.refresh() }
    .onDisappear { viewModel.cancelRecording() }
  }

  /// The switch, drawn as the subject of the pane rather than one row of it.
  private var agentSwitch: some View {
    HStack(alignment: .center, spacing: 12) {
      SettingsSymbolTile(
        systemImage: EvieSettingsSection.screenAndAgent.systemImage,
        tint: isOn ? BrainChipPalette.agent : .gray,
        size: 34
      )
      VStack(alignment: .leading, spacing: 2) {
        Text("Deixar a Evie controlar o Mac")
          .font(.headline)
        Text(isOn ? "Modo agente ligado" : "Modo agente desligado")
          .font(.subheadline)
          .foregroundStyle(isOn ? BrainChipPalette.agent : .secondary)
      }
      Spacer(minLength: 12)
      Toggle(
        "Deixar a Evie controlar o Mac",
        isOn: Binding(get: { isOn }, set: setEnabled)
      )
      .toggleStyle(.switch)
      .labelsHidden()
      .help("Ela clica, digita e abre apps por você, só numa sessão que você começa.")
    }
    .padding(.vertical, 4)
  }
}
