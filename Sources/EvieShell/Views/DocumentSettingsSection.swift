import EvieCore
import SwiftUI

/// The well-known folders a click away: Mesa, Documentos, Downloads and the
/// Obsidian vault, each with a button that grants it.
///
/// A `Section` meant to sit inside a grouped `Form` — Settings' folders pane
/// and the first-run guide both embed it. It shows nothing once every
/// suggestion that exists on this Mac is reachable.
struct SuggestedFoldersSection: View {
  @ObservedObject var viewModel: EvieRootsViewModel

  var body: some View {
    let suggestions = viewModel.suggestedRoots
    if !suggestions.isEmpty {
      Section {
        ForEach(suggestions, id: \.self) { suggestion in
          HStack(spacing: 12) {
            Image(systemName: symbol(for: suggestion))
              .symbolRenderingMode(.hierarchical)
              .foregroundStyle(.secondary)
              .accessibilityHidden(true)
            Text(suggestion.displayName)
            Spacer()
            Button("Permitir") {
              viewModel.grantSuggested(suggestion)
            }
            .help(suggestion.grantTitle)
            .accessibilityLabel(suggestion.grantTitle)
          }
        }
      } header: {
        Text("Pastas do dia a dia")
      } footer: {
        Text(
          """
          Com a permissão, você pode pedir "o que tem na minha mesa?" ou "salva \
          isso em Documentos". Ela lê quando você pede; criar ou mudar arquivo \
          continua passando por um cartão seu. O macOS pergunta uma vez por \
          pasta — é só permitir.
          """
        )
        .font(.footnote)
        .foregroundStyle(.secondary)
      }
    }
  }

  private func symbol(for suggestion: EvieSuggestedRoot) -> String {
    switch suggestion {
    case .desktop: "menubar.dock.rectangle"
    case .documents: "doc.on.doc"
    case .downloads: "arrow.down.circle"
    case .obsidian: "book.closed"
    }
  }
}

/// Everything about documents in one embeddable block: the suggested folders
/// and the switch "Salvar direto quando eu pedir explicitamente" (ADR 0019).
///
/// The hook for Settings' "Arquivos e pastas": place
/// `DocumentSettingsSection(viewModel: rootsViewModel)` inside its `Form`.
struct DocumentSettingsSection: View {
  @ObservedObject var viewModel: EvieRootsViewModel

  var body: some View {
    SuggestedFoldersSection(viewModel: viewModel)

    Section {
      Toggle(
        "Salvar direto quando eu pedir explicitamente",
        isOn: Binding(
          get: { viewModel.savesDocumentsWhenAsked },
          set: { viewModel.setSavesDocumentsWhenAsked($0) }
        )
      )
      .help("Dispensa o clique em Salvar só quando a sua própria mensagem pedir para salvar")
      Text(
        viewModel.savesDocumentsWhenAsked
          ? """
            Ligado. Quando a **sua mensagem** pedir — "salva", "grava na mesa", \
            "cria um arquivo" — um documento novo numa pasta autorizada é salvo \
            sem o cartão, e um aviso mostra onde ficou. Nunca substitui um arquivo, \
            nunca move e nunca manda nada para o Lixo. Texto de documentos, de \
            páginas ou da tela nunca conta como pedido seu.
            """
          : """
            Cada documento que a Evie escreve aparece num cartão com Salvar e \
            Salvar e abrir, e nada é gravado até você clicar. É o padrão.
            """
      )
      .font(.footnote)
      .foregroundStyle(.secondary)
    } header: {
      Text("Documentos")
    }
  }
}
