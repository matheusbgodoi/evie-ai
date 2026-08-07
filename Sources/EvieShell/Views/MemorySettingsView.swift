import EvieCore
import SwiftUI

/// Everything Evie remembers, in one list, each line deletable.
///
/// The whole point of confirming a memory is that it can be audited later. That
/// is only true if it is all visible in one place and each line can be taken
/// back, which is what this screen is.
struct MemorySettingsView: View {
  @ObservedObject var viewModel: EvieMemoryViewModel
  @StateObject private var wipePrompt = MemoryWipePrompt()

  var body: some View {
    Form {
      Section {
        if viewModel.entries.isEmpty {
          VStack(alignment: .leading, spacing: 6) {
            Text("Ela ainda não guarda nada sobre você.")
            Text(
              """
              Quando ela achar que aprendeu algo que vale para outras conversas, \
              vai perguntar se pode guardar. Nada entra aqui sem você confirmar.
              """
            )
            .font(.footnote)
            .foregroundStyle(.secondary)
          }
          .padding(.vertical, 4)
        }

        ForEach(viewModel.entries) { entry in
          HStack(alignment: .top, spacing: 10) {
            VStack(alignment: .leading, spacing: 2) {
              Text(entry.text)
              Text(entry.createdAt, format: .dateTime.day().month().year())
                .font(.caption)
                .foregroundStyle(.secondary)
            }
            Spacer()
            // One line, no confirmation: the cost of a mistake is retyping a
            // sentence, and a dialog for every row would make auditing this
            // list — the whole point of the screen — tedious enough to skip.
            Button("Esquecer", role: .destructive) { viewModel.forget(entry) }
              .buttonStyle(.borderless)
              .foregroundStyle(.red)
              .help("Tira esta linha da memória dela")
              .accessibilityLabel("Esquecer: \(entry.text)")
          }
          .padding(.vertical, 2)
        }
      } header: {
        Text("O que ela sabe sobre você")
      } footer: {
        Text(
          """
          Isto vai junto em toda pergunta, então vale manter curto. O que estiver \
          escrito no seu Obsidian ela já lê de lá — aqui é só o que você contou \
          conversando e não está escrito em lugar nenhum.
          """
        )
        .font(.footnote)
        .foregroundStyle(.secondary)
      }

      if !viewModel.entries.isEmpty {
        Section {
          Button("Esquecer tudo", role: .destructive) {
            wipePrompt.isAsking = true
          }
          .help("Apaga de uma vez tudo o que ela guardou sobre você")
        }
      }
    }
    .formStyle(.grouped)
    // The one action on this screen that cannot be undone one row at a time.
    .confirmationDialog(
      "Esquecer tudo o que a Evie sabe sobre você?",
      isPresented: $wipePrompt.isAsking,
      titleVisibility: .visible
    ) {
      Button("Esquecer tudo", role: .destructive) {
        viewModel.forgetEverything()
      }
      Button("Cancelar", role: .cancel) {}
    } message: {
      Text(
        "As \(viewModel.entries.count) linhas acima somem deste Mac e não têm como voltar."
      )
    }
    .settingsFeedback(
      viewModel.feedback?.message,
      isError: viewModel.feedback?.isError == true
    )
  }
}

/// Whether the wipe confirmation is up.
///
/// This toolchain has no `@State`, and the memory view model is shared with the
/// overlay's proposal cards, so a flag about a dialog in a settings pane does
/// not belong there.
@MainActor
private final class MemoryWipePrompt: ObservableObject {
  @Published var isAsking = false
}
