import EvieCore
import SwiftUI

/// Everything Evie remembers, in one list, each line deletable.
///
/// The whole point of confirming a memory is that it can be audited later. That
/// is only true if it is all visible in one place and each line can be taken
/// back, which is what this screen is.
struct MemorySettingsView: View {
  @ObservedObject var viewModel: EvieMemoryViewModel

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
            Button("Esquecer") { viewModel.forget(entry) }
              .buttonStyle(.borderless)
              .foregroundStyle(.red)
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
            viewModel.forgetEverything()
          }
        }
      }
    }
    .formStyle(.grouped)
    .safeAreaInset(edge: .bottom) {
      if let feedback = viewModel.feedback {
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
