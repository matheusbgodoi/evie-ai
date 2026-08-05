import EvieCore
import SwiftUI

struct ConversationHistoryView: View {
  @ObservedObject var viewModel: ConversationHistoryViewModel

  var body: some View {
    NavigationSplitView {
      conversationList
        .navigationSplitViewColumnWidth(min: 230, ideal: 270, max: 340)
    } detail: {
      conversationDetail
    }
    .toolbar {
      ToolbarItemGroup {
        Button {
          viewModel.createNewConversation()
        } label: {
          Label("Nova conversa", systemImage: "square.and.pencil")
        }

        Button {
          viewModel.refresh()
        } label: {
          Label("Atualizar", systemImage: "arrow.clockwise")
        }
      }
    }
    .frame(minWidth: 780, minHeight: 560)
    .onChange(of: viewModel.selectedID) {
      viewModel.loadSelection()
    }
    .confirmationDialog(
      "Excluir esta conversa deste Mac?",
      isPresented: $viewModel.showsDeleteConfirmation,
      titleVisibility: .visible
    ) {
      Button("Excluir permanentemente", role: .destructive) {
        viewModel.deleteSelectedConversation()
      }
      Button("Cancelar", role: .cancel) {}
    } message: {
      Text("Essa ação remove apenas o histórico local selecionado e não pode ser desfeita.")
    }
  }

  private var conversationList: some View {
    List(selection: $viewModel.selectedID) {
      if viewModel.unavailableRecordCount > 0 {
        Label(
          unavailableHistoryMessage,
          systemImage: "exclamationmark.triangle.fill"
        )
        .font(.caption)
        .foregroundStyle(.orange)
        .listRowBackground(Color.orange.opacity(0.08))
        .accessibilityLabel(unavailableHistoryMessage)
      }

      if viewModel.conversations.isEmpty, !viewModel.isLoading {
        ContentUnavailableView(
          viewModel.unavailableRecordCount == 0
            ? "Nenhuma conversa salva" : "Nenhuma conversa disponível",
          systemImage: "bubble.left.and.bubble.right",
          description: Text(
            viewModel.unavailableRecordCount == 0
              ? "A primeira conversa será salva depois que a Evie responder."
              : "Os registros indisponíveis não foram abertos nem exibidos."
          )
        )
        .listRowBackground(Color.clear)
      } else {
        ForEach(viewModel.conversations) { conversation in
          VStack(alignment: .leading, spacing: 4) {
            Text(conversation.title)
              .font(.headline)
              .lineLimit(2)
            HStack(spacing: 5) {
              Text(conversation.updatedAt, format: .relative(presentation: .named))
              Text("·")
              Text("\(conversation.messageCount) mensagens")
            }
            .font(.caption)
            .foregroundStyle(.secondary)
          }
          .padding(.vertical, 5)
          .tag(conversation.id)
        }
      }
    }
    .overlay {
      if viewModel.isLoading {
        ProgressView()
      }
    }
    .navigationTitle("Conversas")
  }

  private var unavailableHistoryMessage: String {
    let count = viewModel.unavailableRecordCount
    if count == 1 {
      return "1 registro local está indisponível; as demais conversas continuam acessíveis."
    }
    return
      "\(count) registros locais estão indisponíveis; as demais conversas continuam acessíveis."
  }

  @ViewBuilder
  private var conversationDetail: some View {
    if let conversation = viewModel.selectedConversation {
      VStack(spacing: 0) {
        HStack(alignment: .firstTextBaseline) {
          VStack(alignment: .leading, spacing: 3) {
            Text(conversation.title)
              .font(.title2.bold())
            Text("Salva somente neste Mac")
              .font(.caption)
              .foregroundStyle(.secondary)
          }
          Spacer()
          Button("Continuar conversa") {
            viewModel.continueSelectedConversation()
          }
          .buttonStyle(.borderedProminent)
          .disabled(!viewModel.canActOnSelection)
        }
        .padding()

        Divider()

        ScrollView {
          LazyVStack(alignment: .leading, spacing: 12) {
            ForEach(conversation.messages) { message in
              messageCard(message)
            }
          }
          .padding()
        }

        Divider()

        HStack {
          if let errorMessage = viewModel.errorMessage {
            Label(errorMessage, systemImage: "exclamationmark.triangle")
              .font(.caption)
              .foregroundStyle(.red)
              .lineLimit(2)
          }
          Spacer()
          Button("Excluir conversa…", role: .destructive) {
            viewModel.showsDeleteConfirmation = true
          }
          .disabled(!viewModel.canActOnSelection)
        }
        .padding()
      }
    } else if let errorMessage = viewModel.errorMessage {
      ContentUnavailableView(
        "Não foi possível abrir o histórico",
        systemImage: "exclamationmark.triangle",
        description: Text(errorMessage)
      )
    } else if viewModel.isLoadingSelection {
      ProgressView("Abrindo conversa…")
    } else {
      ContentUnavailableView(
        "Selecione uma conversa",
        systemImage: "sidebar.left",
        description: Text("O histórico só aparece quando você o abre de propósito.")
      )
    }
  }

  private func messageCard(_ message: ChatMessage) -> some View {
    VStack(alignment: .leading, spacing: 7) {
      HStack {
        Label(roleTitle(message.role), systemImage: roleSymbol(message.role))
          .font(.caption.bold())
          .foregroundStyle(roleTint(message.role))
        Spacer()
        Text(message.createdAt, format: .dateTime.hour().minute())
          .font(.caption2)
          .foregroundStyle(.tertiary)
      }
      Text(message.content)
        .textSelection(.enabled)
        .frame(maxWidth: .infinity, alignment: .leading)
    }
    .padding(13)
    .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 14))
    .overlay {
      RoundedRectangle(cornerRadius: 14)
        .strokeBorder(roleTint(message.role).opacity(0.16), lineWidth: 0.7)
    }
  }

  private func roleTitle(_ role: ChatRole) -> String {
    switch role {
    case .user: "Você"
    case .assistant: "Evie"
    case .tool: "Ferramenta"
    case .system, .developer: "Política interna"
    }
  }

  private func roleSymbol(_ role: ChatRole) -> String {
    switch role {
    case .user: "person.fill"
    case .assistant: "sparkles"
    case .tool: "wrench.and.screwdriver.fill"
    case .system, .developer: "lock.shield.fill"
    }
  }

  private func roleTint(_ role: ChatRole) -> Color {
    switch role {
    case .user: .blue
    case .assistant: .indigo
    case .tool: .orange
    case .system, .developer: .secondary
    }
  }
}
