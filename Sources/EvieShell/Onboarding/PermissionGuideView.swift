import EvieCore
import SwiftUI

/// The first-run checklist: one row per thing Evie needs, each with its live
/// state and the one button that can change it.
///
/// The same view is the guide window on first launch and the "Permissões" pane
/// in Settings. `onDone` is what tells them apart: the window has a button that
/// closes it, the pane does not.
struct PermissionGuideView: View {
  @ObservedObject var viewModel: PermissionGuideViewModel
  /// The well-known folders, offered on first launch. Absent in Settings,
  /// where the folders pane has its own copy of the same section.
  var folders: EvieRootsViewModel?
  var onDone: (() -> Void)?

  var body: some View {
    Form {
      Section {
        PermissionGuideRowsView(viewModel: viewModel)
      } header: {
        Text("O que a Evie precisa")
      } footer: {
        footer
      }

      if let folders {
        SuggestedFoldersSection(viewModel: folders)
      }

      if let onDone {
        Section {
          HStack {
            Spacer()
            Button(viewModel.allSatisfied ? "Pronto" : "Depois eu termino", action: onDone)
              .keyboardShortcut(.defaultAction)
          }
        }
      }
    }
    .formStyle(.grouped)
    .onAppear { viewModel.refresh() }
  }

  @ViewBuilder
  private var footer: some View {
    if viewModel.isBundled {
      Text(
        """
        Cada permissão é pedida uma vez pelo macOS. Se você recusar, o botão \
        passa a abrir a página certa dos Ajustes, onde dá para mudar de ideia. \
        A chave e o cérebro também ficam em Configurações › Cérebro, e esta \
        lista em Configurações › Permissões.
        """
      )
      .font(.footnote)
      .foregroundStyle(.secondary)
    } else {
      Label(
        """
        Esta cópia não está empacotada como aplicativo, então o macOS daria \
        essas permissões ao Terminal, não à Evie. Rode Scripts/evie-app install.
        """,
        systemImage: "exclamationmark.triangle.fill"
      )
      .font(.footnote)
      .symbolRenderingMode(.hierarchical)
      .foregroundStyle(.orange)
    }
  }
}

/// The guide's rows, or only some of them, for a section of any Form:
/// Settings › Tela e modo agente shows the three grants agent mode needs, with
/// the same buttons, beside its switch.
struct PermissionGuideRowsView: View {
  @ObservedObject var viewModel: PermissionGuideViewModel
  /// Row ids to show (`EviePermission.rawValue` for a permission); nil for all.
  var only: Set<String>? = nil

  var body: some View {
    ForEach(viewModel.rows.filter { only?.contains($0.id) ?? true }) { row in
      PermissionGuideRowView(
        row: row,
        showsAction: viewModel.isBundled,
        isBusy: viewModel.busyRows.contains(row.id),
        perform: { action in
          Task { await viewModel.perform(action, onRow: row.id) }
        }
      )
    }
  }
}

private struct PermissionGuideRowView: View {
  let row: PermissionGuideRow
  let showsAction: Bool
  let isBusy: Bool
  let perform: (PermissionGuideRow.Action) -> Void

  var body: some View {
    HStack(alignment: .firstTextBaseline, spacing: 10) {
      mark
      VStack(alignment: .leading, spacing: 3) {
        Text(row.title).font(.headline)
        Text(row.detail)
          .font(.callout)
          .foregroundStyle(.secondary)
          .fixedSize(horizontal: false, vertical: true)
        if let hint = row.hint {
          Text(hint)
            .font(.footnote)
            .foregroundStyle(.secondary)
            .fixedSize(horizontal: false, vertical: true)
        }
      }
      Spacer(minLength: 12)
      Text(row.statusText)
        .font(.footnote)
        .foregroundStyle(.secondary)
      if isBusy {
        ProgressView().controlSize(.small)
      }
      if showsAction, let action = row.action {
        Button(action.title) { perform(action) }
          .disabled(isBusy)
          .help(help(for: action))
      }
    }
    .accessibilityElement(children: .contain)
  }

  /// A distinct symbol per state, so the colour is never the only signal.
  private var mark: some View {
    let (symbol, tint): (String, Color) =
      switch row.mark {
      case .satisfied: ("checkmark.circle.fill", .green)
      case .pending: ("circle.dashed", .secondary)
      case .refused: ("exclamationmark.triangle.fill", .orange)
      }
    return Image(systemName: symbol)
      .symbolRenderingMode(.hierarchical)
      .foregroundStyle(tint)
      .accessibilityLabel(row.statusText)
  }

  private func help(for action: PermissionGuideRow.Action) -> String {
    switch action.kind {
    case .request: "Mostra o pedido do macOS para \(row.title.lowercased())"
    case .openSettings: "Abre Ajustes do Sistema › Privacidade e Segurança na página certa"
    case .importPCKey: "Copia a chave do gateway que a configuração do PC guardou no Keychain"
    case .testConnection:
      "Pergunta ao servidor se ele responde, se aceita a chave e se o modelo está carregado"
    }
  }
}
