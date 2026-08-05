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

      Section {
        Button {
          viewModel.grant()
        } label: {
          Label("Autorizar uma pasta…", systemImage: "folder.badge.plus")
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
        .foregroundStyle(.secondary)

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
          Label("não está acessível agora", systemImage: "exclamationmark.triangle")
            .font(.caption)
            .foregroundStyle(.orange)
        }
      }

      Spacer()

      Button("Remover") {
        viewModel.revoke(root)
      }
      .buttonStyle(.borderless)
      .foregroundStyle(.red)
    }
    .padding(.vertical, 2)
  }
}
