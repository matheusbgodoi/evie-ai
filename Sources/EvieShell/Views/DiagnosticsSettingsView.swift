import EvieCore
import SwiftUI

/// The only place in the interface where the plumbing is visible.
///
/// The overlay deliberately never mentions the model, the server, or a loopback
/// address. When something is broken those values are exactly what you need, so
/// they live here rather than nowhere.
struct DiagnosticsSettingsView: View {
  /// The profile in use, with this run's environment overrides.
  var profile: EvieModelProfile
  var preferencesPath: String
  var configurationPath: String

  var body: some View {
    Form {
      Section {
        copyableRow("Modelo", value: profile.model)
        copyableRow("Endereço", value: profile.endpoint.absoluteString)
        LabeledContent("Contexto", value: profile.contextLine)
        LabeledContent("Onde roda", value: profile.location.placeDescription)
      } header: {
        Text("Motor: \(profile.displayName)")
      } footer: {
        Text(footer)
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
        commandRow(
          "Importar a chave do PC pelo Terminal",
          command: "Scripts/evie-app import-pc-key"
        )
      }
    }
    .formStyle(.grouped)
  }

  /// What the address means, for the brain in use. It used to name 127.0.0.1 and
  /// port 38433 whatever the configuration said.
  private var footer: String {
    switch profile.location {
    case .yourPC:
      "O endereço é o gateway do seu PC na sua rede Tailscale, por https. A chave fica no "
        + "Keychain deste Mac e só vai para esse endereço. Teste em Configurações › Cérebro."
    case .thisMac:
      "O endereço fica neste Mac (\(profile.endpoint.host ?? "127.0.0.1")), ou seja, só este Mac "
        + "alcança; nada da conversa sai daqui."
    }
  }

  /// LabeledContent, not a hand-built HStack: this is exactly the read-only
  /// value it is for, and it lines these rows up with the "Contexto" row above
  /// that already used it.
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
