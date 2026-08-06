import EvieCore
import SwiftUI

/// The only place in the interface where the plumbing is visible.
///
/// The overlay deliberately never mentions the model, the server, or a loopback
/// address. When something is broken those values are exactly what you need, so
/// they live here rather than nowhere.
struct DiagnosticsSettingsView: View {
  var modelName: String
  var endpoint: String
  var contextWindowTokens: Int
  var preferencesPath: String
  var configurationPath: String

  var body: some View {
    Form {
      Section {
        copyableRow("Modelo", value: modelName)
        copyableRow("Endereço local", value: endpoint)
        LabeledContent("Janela do servidor", value: "\(contextWindowTokens.formatted()) tokens")
      } header: {
        Text("Motor")
      } footer: {
        Text(
          "O endereço fica em 127.0.0.1, ou seja, só este Mac alcança. A porta 38433 "
            + "foi escolhida fora do registro da IANA e abaixo da faixa efêmera do macOS, "
            + "para nunca esbarrar em outro projeto seu."
        )
        .font(.caption)
        .foregroundStyle(.secondary)
      }

      Section {
        copyableRow("Preferências", value: preferencesPath)
        copyableRow("Configuração do modelo", value: configurationPath)
      } header: {
        Text("Arquivos locais")
      } footer: {
        Text(
          "Ficam fora do repositório, só para o seu usuário. Conversas, áudio e "
            + "credenciais nunca entram no Git."
        )
        .font(.caption)
        .foregroundStyle(.secondary)
      }

      Section("Comandos") {
        commandRow(
          "Ver o que a Evie recebe como instrução",
          command: "evie-shell --print-persona"
        )
        commandRow(
          "Conferir o motor local",
          command: "Scripts/evie-runtime status"
        )
        commandRow(
          "Teste de ponta a ponta",
          command: "Scripts/evie-runtime smoke"
        )
      }
    }
    .formStyle(.grouped)
  }

  /// LabeledContent, not a hand-built HStack: this is exactly the read-only
  /// value it is for, and it lines these rows up with the "Janela do servidor"
  /// row above that already used it.
  private func copyableRow(_ title: String, value: String) -> some View {
    LabeledContent(title) {
      HStack(spacing: 6) {
        Text(value)
          .font(.system(size: 11, design: .monospaced))
          .foregroundStyle(.secondary)
          .textSelection(.enabled)
          .lineLimit(1)
          .truncationMode(.middle)
          .help(value)
        copyButton(value)
      }
    }
  }

  private func commandRow(_ title: String, command: String) -> some View {
    VStack(alignment: .leading, spacing: 3) {
      Text(title)
      HStack {
        Text(command)
          .font(.system(size: 11, design: .monospaced))
          .foregroundStyle(.secondary)
          .textSelection(.enabled)
        Spacer()
        copyButton(command)
      }
    }
  }

  private func copyButton(_ value: String) -> some View {
    Button {
      NSPasteboard.general.clearContents()
      NSPasteboard.general.setString(value, forType: .string)
    } label: {
      Image(systemName: "doc.on.doc")
        .font(.system(size: 10))
        .symbolRenderingMode(.hierarchical)
    }
    .buttonStyle(.borderless)
    .help("Copiar para a Área de Transferência")
    .accessibilityLabel("Copiar \(value)")
  }
}
