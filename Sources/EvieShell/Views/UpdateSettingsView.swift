import EvieCore
import SwiftUI

/// Where an update is offered, and never taken.
///
/// Every step is a separate press: look, download, install. The middle step is
/// where the signature is checked, so "baixar" and "instalar" are deliberately
/// not one button — what is being confirmed at the end is replacing the
/// application, and by then Evie can say who signed the replacement.
struct UpdateSettingsView: View {
  @ObservedObject var updater: EvieUpdater

  var body: some View {
    Form {
      Section {
        LabeledContent("Versão instalada") {
          Text(EvieUpdater.installedVersion?.description ?? "desconhecida")
            .foregroundStyle(.secondary)
        }
        LabeledContent("Última verificação") {
          Text(
            updater.lastChecked.map {
              $0.formatted(date: .abbreviated, time: .shortened)
            } ?? "nunca"
          )
          .foregroundStyle(.secondary)
        }
        status
      } header: {
        Text("Atualizações")
      } footer: {
        Text(
          "A Evie só instala um download assinado com o mesmo certificado desta "
            + "cópia. Uma release adulterada, ou uma conta do GitHub invadida, não "
            + "consegue produzir essa assinatura."
        )
        .font(.footnote)
        .foregroundStyle(.secondary)
      }
    }
    .formStyle(.grouped)
    .task { await updater.check() }
  }

  @ViewBuilder
  private var status: some View {
    switch updater.state {
    case .idle, .upToDate, .failed:
      HStack {
        Button("Procurar atualização") {
          Task { await updater.check(force: true) }
        }
        if case .upToDate = updater.state {
          Text("Você está na versão mais recente.")
            .font(.footnote)
            .foregroundStyle(.secondary)
        }
        if case .failed(let reason) = updater.state {
          Text(reason)
            .font(.footnote)
            .foregroundStyle(.orange)
        }
      }

    case .checking:
      HStack(spacing: 8) {
        ProgressView().controlSize(.small)
        Text("Perguntando ao GitHub…").foregroundStyle(.secondary)
      }

    case .available(let release):
      VStack(alignment: .leading, spacing: 8) {
        Text("Versão \(release.version.description) disponível")
          .font(.headline)
        if !release.notes.isEmpty {
          // Truncated rather than scrolled: the whole point of this pane is the
          // decision, and release notes are a paragraph, not a document.
          Text(release.notes)
            .font(.footnote)
            .foregroundStyle(.secondary)
            .lineLimit(6)
        }
        Button("Baixar e conferir a assinatura") {
          Task { await updater.download(release) }
        }
      }

    case .downloading(let fraction):
      ProgressView(value: fraction) {
        Text("Baixando…")
      }

    case .readyToInstall(let release):
      VStack(alignment: .leading, spacing: 8) {
        Label(
          "Versão \(release.version.description) conferida — assinada por quem assinou esta cópia.",
          systemImage: "checkmark.seal"
        )
        .foregroundStyle(.green)
        HStack {
          Button("Instalar e reabrir") { updater.install() }
            .buttonStyle(.borderedProminent)
          Button("Descartar") {
            updater.discardStaged()
            Task { await updater.check(force: true) }
          }
        }
      }
    }
  }
}
