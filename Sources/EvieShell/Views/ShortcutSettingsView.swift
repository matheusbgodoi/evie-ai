import EvieCore
import SwiftUI

/// Every shortcut Evie answers to, each one editable, disableable, and
/// resettable on its own.
struct ShortcutSettingsView: View {
  @ObservedObject var viewModel: EviePreferencesViewModel

  var body: some View {
    Form {
      Section {
        ForEach(EvieShortcutAction.allCases, id: \.self) { action in
          ShortcutRow(action: action, viewModel: viewModel)
        }
      } header: {
        Text("Atalhos globais")
      } footer: {
        Text(
          "Funcionam de qualquer aplicativo. Toda combinação precisa de ⌘, ⌥ ou ⌃ — "
            + "só ⇧ mudaria a letra que você digita."
        )
        .font(.caption)
        .foregroundStyle(.secondary)
      }
    }
    .formStyle(.grouped)
    .onDisappear {
      viewModel.cancelRecording()
    }
    .safeAreaInset(edge: .bottom) {
      HStack {
        Button("Restaurar todos os atalhos") {
          viewModel.resetAllShortcuts()
        }
        .disabled(viewModel.preferences.shortcuts.isUsingDefaults)
        Spacer()
      }
      .padding(14)
      .background(.bar)
    }
  }
}

private struct ShortcutRow: View {
  var action: EvieShortcutAction
  @ObservedObject var viewModel: EviePreferencesViewModel

  private var isRecording: Bool {
    viewModel.recordingAction == action
  }

  private var conflicts: [EvieShortcutAction] {
    viewModel.conflictingActions(with: action)
  }

  var body: some View {
    VStack(alignment: .leading, spacing: 5) {
      HStack(alignment: .firstTextBaseline, spacing: 12) {
        VStack(alignment: .leading, spacing: 2) {
          Text(action.title)
          Text(action.details)
            .font(.caption)
            .foregroundStyle(.secondary)
        }

        Spacer(minLength: 12)

        Button(action: toggleRecording) {
          Text(label)
            .font(.system(size: 12, weight: .medium, design: .rounded))
            .monospacedDigit()
            .frame(minWidth: 96)
            .padding(.vertical, 4)
        }
        .buttonStyle(.bordered)
        .tint(isRecording ? .accentColor : nil)
        .help(isRecording ? "Pressione a combinação, ou Esc para desistir" : "Alterar o atalho")

        Menu {
          Button("Restaurar padrão") {
            viewModel.resetShortcut(action)
          }
          .disabled(viewModel.isUsingDefault(action))

          Button("Desativar este atalho") {
            viewModel.disableShortcut(action)
          }
          .disabled(viewModel.isDisabled(action))
        } label: {
          Image(systemName: "ellipsis.circle")
        }
        .menuStyle(.borderlessButton)
        .fixedSize()
        .accessibilityLabel("Mais opções para \(action.title)")
      }

      if !conflicts.isEmpty {
        rowNote(
          "Mesma combinação de \(conflicts.map(\.title).joined(separator: " e ")).",
          symbol: "exclamationmark.triangle.fill",
          tint: .orange
        )
      } else if viewModel.unavailableActions.contains(action) {
        rowNote(
          "Outro aplicativo já usa esta combinação, então ela não foi registrada.",
          symbol: "xmark.octagon.fill",
          tint: .red
        )
      } else if viewModel.isDisabled(action) {
        rowNote(
          "Desativado. Esta ação continua disponível pelo menu da Evie.",
          symbol: "moon.zzz.fill",
          tint: .secondary
        )
      }
    }
    .padding(.vertical, 2)
  }

  private var label: String {
    if isRecording {
      return "Gravando…"
    }
    return viewModel.shortcut(for: action)?.displayString ?? "Desativado"
  }

  private func toggleRecording() {
    if isRecording {
      viewModel.cancelRecording()
    } else {
      viewModel.beginRecording(action)
    }
  }

  private func rowNote(_ text: String, symbol: String, tint: Color) -> some View {
    Label(text, systemImage: symbol)
      .font(.caption)
      .foregroundStyle(tint)
  }
}
