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
        .help("Pergunta ao GitHub se existe uma versão mais nova; nada é baixado ainda")
        if case .upToDate = updater.state {
          Label("Você está na versão mais recente.", systemImage: "checkmark.circle.fill")
            .font(.footnote)
            .symbolRenderingMode(.hierarchical)
            .foregroundStyle(.secondary)
        }
        if case .failed(let reason) = updater.state {
          Label(reason, systemImage: "exclamationmark.triangle.fill")
            .font(.footnote)
            .symbolRenderingMode(.hierarchical)
            .foregroundStyle(.orange)
        }
      }

    case .checking:
      HStack(spacing: 8) {
        ProgressView().controlSize(.small)
        Text("Perguntando ao GitHub…").foregroundStyle(.secondary)
      }
      .accessibilityElement(children: .combine)

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
        .help("Baixa a nova versão e confere quem a assinou; nada é instalado ainda")
      }

    case .downloading(let fraction):
      ProgressView(value: fraction) {
        Text("Baixando…")
      }
      .accessibilityLabel("Baixando a atualização")
      .accessibilityValue("\(Int(fraction * 100)) por cento")

    case .readyToInstall(let release):
      VStack(alignment: .leading, spacing: 8) {
        Label(
          "Versão \(release.version.description) conferida — assinada por quem assinou esta cópia.",
          systemImage: "checkmark.seal.fill"
        )
        .symbolRenderingMode(.hierarchical)
        .foregroundStyle(.green)
        HStack {
          Button("Instalar e reabrir") { updater.install() }
            .buttonStyle(.borderedProminent)
            .keyboardShortcut(.defaultAction)
            .help("Substitui esta cópia da Evie pela nova versão e reabre o aplicativo")
          // Destructive by role because it throws away a verified download the
          // user waited for; no confirmation, because pressing it costs only
          // another download.
          Button("Descartar", role: .destructive) {
            updater.discardStaged()
            Task { await updater.check(force: true) }
          }
          .help("Joga fora o download conferido e procura de novo")
        }
      }
    }
  }
}
