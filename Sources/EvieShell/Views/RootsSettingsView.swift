import EvieCore
import SwiftUI

/// Which folders Evie can read.
///
/// The list is the whole permission model made visible. Everything Evie can
/// reach is on this screen, each row can be taken back, and nothing gets here
/// except by someone choosing it in the system's open panel.
struct RootsSettingsView: View {
  @ObservedObject var viewModel: EvieRootsViewModel

  var body: some View {
    Form {
      Section {
        Toggle(
          "Liberar minha pasta pessoal inteira",
          isOn: Binding(
            get: { viewModel.isHomeGranted },
            set: { viewModel.setHomeGranted($0) }
          )
        )
        .help("Autoriza tudo dentro da sua pasta pessoal de uma vez, no lugar das pastas avulsas")
      } header: {
        Text("Sem escolher pasta por pasta")
      } footer: {
        Text(
          """
          Libera tudo de uma vez, e substitui as autorizações individuais — a \
          pasta pessoal já contém todas elas. Senhas, chaves e a pasta Biblioteca \
          (Mail, Mensagens, cookies, tokens) continuam fora do alcance dela.

          Isto libera o lado da Evie. O macOS continua com o dele: na primeira vez \
          que ela olhar Mesa, Documentos, Transferências ou iCloud Drive, o \
          sistema vai pedir sua permissão uma vez para cada. Escolher a pasta no \
          painel já traz essa permissão junto; este botão não tem como.
          """
        )
        .font(.footnote)
        .foregroundStyle(.secondary)
      }

      Section {
        if viewModel.roots.isEmpty {
          emptyState
        } else {
          ForEach(viewModel.roots) { root in
            row(for: root)
          }
        }
      } header: {
        Text("Pastas que a Evie pode ler")
      } footer: {
        Text(
          """
          A Evie só enxerga o que estiver dentro destas pastas. Ela lê, nunca \
          escreve nem apaga. Senhas, chaves e credenciais continuam fora do \
          alcance mesmo dentro de uma pasta autorizada.
          """
        )
        .font(.footnote)
        .foregroundStyle(.secondary)
      }

      if !viewModel.untrackedObsidianVaults.isEmpty {
        Section {
          ForEach(viewModel.untrackedObsidianVaults, id: \.self) { url in
            Button {
              viewModel.add(url)
            } label: {
              Label(
                "Usar meu Obsidian (\(url.lastPathComponent))",
                systemImage: "book.closed"
              )
            }
            .help("Autoriza a Evie a ler as notas deste cofre; ela nunca escreve nem apaga")
          }
        } footer: {
          Text(
            """
            Ela lê suas notas para responder — engenharia, Cluemed, Keymatic, o que \
            estiver escrito lá. Nunca escreve, nunca edita, nunca apaga: não existe \
            ferramenta capaz disso.
            """
          )
          .font(.footnote)
          .foregroundStyle(.secondary)
        }
      }

      Section {
        Toggle(
          "Deixar a Evie mexer nos arquivos",
          isOn: Binding(
            get: { viewModel.canChangeFiles },
            set: { viewModel.setCanChangeFiles($0) }
          )
        )
        .help("Permite que ela sugira mandar para o Lixo, renomear e mover, sempre com um clique seu")
        Text(
          viewModel.canChangeFiles
            ? """
              Ela pode sugerir mandar para o Lixo, renomear e mover, dentro das \
              pastas autorizadas. Cada sugestão vira um cartão com o arquivo exato, \
              e nada acontece até você clicar. Apagar sempre é o Lixo — ela não \
              tem como apagar de vez.
              """
            : """
              Desligado. Ela lê e só. Não existe ferramenta capaz de mover ou \
              apagar nada, então nenhum documento e nenhuma página conseguem \
              convencê-la a tentar.
              """
        )
        .font(.footnote)
        .foregroundStyle(.secondary)

        Toggle(
          "Fazer sem me perguntar",
          isOn: Binding(
            get: { viewModel.autoApprovesChanges },
            set: { viewModel.setAutoApprovesChanges($0) }
          )
        )
        .disabled(!viewModel.canChangeFiles)
        .help(
          viewModel.canChangeFiles
            ? "Dispensa o clique só quando a sua própria mensagem pediu a mudança"
            : "Disponível quando “Deixar a Evie mexer nos arquivos” estiver ligado"
        )
        Text(
          viewModel.autoApprovesChanges
            ? """
              Ligado, e só vale quando a **sua mensagem** pedir para mexer em algo. \
              Uma sugestão que apareceu sozinha — porque um arquivo ou uma página \
              mandou — continua parando num cartão. Tudo que for feito assim aparece \
              na conversa depois, e apagar continua sendo o Lixo.
              """
            : "Cada mudança espera um clique seu. É o padrão, e é o mais seguro."
        )
        .font(.footnote)
        .foregroundStyle(.secondary)
      } header: {
        Text("Mexer nos arquivos")
      }

      Section {
        Button {
          viewModel.grant()
        } label: {
          Label("Autorizar uma pasta…", systemImage: "folder.badge.plus")
        }
        .help("Abre o painel do sistema para escolher mais uma pasta que a Evie pode ler")
      }
    }
    .formStyle(.grouped)
    .settingsFeedback(
      viewModel.feedback?.message,
      isError: viewModel.feedback?.isError == true
    )
  }

  private var emptyState: some View {
    VStack(alignment: .leading, spacing: 6) {
      Text("Nenhuma pasta autorizada.")
        .font(.body)
      Text(
        """
        Enquanto estiver assim, a Evie responde do que sabe e não tem como abrir \
        nada seu.
        """
      )
      .font(.footnote)
      .foregroundStyle(.secondary)
    }
    .padding(.vertical, 4)
  }

  private func row(for root: EvieFileRoot) -> some View {
    HStack(spacing: 12) {
      Image(systemName: "folder")
        .symbolRenderingMode(.hierarchical)
        .foregroundStyle(.secondary)
        // Decoration next to a name that already says what this is; announcing
        // "pasta" before every row would only slow VoiceOver down.
        .accessibilityHidden(true)

      VStack(alignment: .leading, spacing: 2) {
        Text(root.displayName)
          .font(.body)
        Text(viewModel.displayPath(for: root))
          .font(.caption)
          .foregroundStyle(.secondary)
          .lineLimit(1)
          .truncationMode(.middle)
        // A grant that has stopped working should say so here rather than turn
        // into a puzzling failure in the middle of an answer.
        if !viewModel.isReachable(root) {
          Label("não está acessível agora", systemImage: "exclamationmark.triangle.fill")
            .font(.caption)
            .symbolRenderingMode(.hierarchical)
            .foregroundStyle(.orange)
        }
      }

      Spacer()

      // Destructive by role because it takes access away, but with no
      // confirmation: nothing is deleted and the folder can be authorised again
      // from the button below.
      Button("Remover", role: .destructive) {
        viewModel.revoke(root)
      }
      .buttonStyle(.borderless)
      .foregroundStyle(.red)
      .help("Tira a autorização desta pasta; nada é apagado")
      .accessibilityLabel("Remover a autorização de \(root.displayName)")
    }
    .padding(.vertical, 2)
  }
}
