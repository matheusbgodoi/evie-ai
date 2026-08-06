import AppKit
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
        .help("Começar uma conversa nova")

        Button {
          viewModel.refresh()
        } label: {
          Label("Atualizar", systemImage: "arrow.clockwise")
        }
        .help("Reler o histórico salvo neste Mac")

        Button {
          viewModel.exportSelected()
        } label: {
          Label("Exportar", systemImage: "square.and.arrow.up")
        }
        .disabled(!viewModel.canModifySelection)
        .help(exportHelp)

        Button {
          viewModel.confirmDeleteSelected()
        } label: {
          Label("Excluir", systemImage: "trash")
        }
        .disabled(!viewModel.canModifySelection)
        .help(deleteHelp)
      }
    }
    .frame(minWidth: 780, minHeight: 560)
    .onChange(of: viewModel.selectedIDs) {
      viewModel.loadSelection()
    }
  }

  private var exportHelp: String {
    viewModel.selectionCount > 1
      ? "Exportar as \(viewModel.selectionCount) conversas selecionadas em Markdown"
      : "Exportar a conversa selecionada em Markdown (.md)"
  }

  private var deleteHelp: String {
    viewModel.selectionCount > 1
      ? "Excluir as \(viewModel.selectionCount) conversas selecionadas deste Mac"
      : "Excluir a conversa selecionada deste Mac"
  }

  private var conversationList: some View {
    VStack(spacing: 0) {
      List(selection: $viewModel.selectedIDs) {
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

      Divider()

      HStack(spacing: 8) {
        Text(selectionSummary)
          .font(.caption)
          .foregroundStyle(.secondary)
        Spacer()
        Button {
          viewModel.confirmDeleteAll()
        } label: {
          Label("Excluir tudo", systemImage: "trash.slash")
            .labelStyle(.iconOnly)
        }
        .buttonStyle(.borderless)
        .disabled(viewModel.conversations.isEmpty || viewModel.isDeleting)
        .help("Excluir todo o histórico salvo neste Mac")
      }
      .padding(.horizontal, 12)
      .padding(.vertical, 7)
    }
    .navigationTitle("Conversas")
  }

  private var selectionSummary: String {
    let total = viewModel.conversations.count
    let selected = viewModel.selectionCount
    if selected > 1 {
      return "\(selected) de \(total) selecionadas"
    }
    return total == 1 ? "1 conversa" : "\(total) conversas"
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
    if viewModel.selectionCount > 1 {
      ContentUnavailableView(
        "\(viewModel.selectionCount) conversas selecionadas",
        systemImage: "square.on.square",
        description: Text(
          "Exporte ou exclua o conjunto pela barra de ferramentas. Para ler uma delas, selecione só ela."
        )
      )
    } else if let conversation = viewModel.selectedConversation {
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
          .help("Reabrir esta conversa na janela da Evie e seguir de onde parou")
        }
        .padding()

        Divider()

        ScrollView {
          LazyVStack(alignment: .leading, spacing: 12) {
            ForEach(conversation.messages) { message in
              messageCard(message)
            }
            if !viewModel.unattachedMedia.isEmpty {
              orphanedAttachments
            }
          }
          .padding()
        }

        Divider()

        HStack(spacing: 10) {
          if let errorMessage = viewModel.errorMessage {
            Label(errorMessage, systemImage: "exclamationmark.triangle")
              .font(.caption)
              .foregroundStyle(.red)
              .lineLimit(2)
          } else if let statusMessage = viewModel.statusMessage {
            Label(statusMessage, systemImage: "checkmark.circle")
              .font(.caption)
              .foregroundStyle(.secondary)
              .lineLimit(2)
          }
          Spacer()
          Button {
            viewModel.exportSelected()
          } label: {
            Label("Exportar conversa", systemImage: "square.and.arrow.up")
          }
          .disabled(!viewModel.canModifySelection)
          .help("Salvar esta conversa como arquivo Markdown (.md)")

          Button(role: .destructive) {
            viewModel.confirmDeleteSelected()
          } label: {
            Label("Excluir conversa", systemImage: "trash")
          }
          .disabled(!viewModel.canActOnSelection)
          .help("Excluir esta conversa e os arquivos anexados a ela")
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

      // The files that came with this turn sit next to it. A transcript that says
      // "a imagem mostra…" without the image is a record of an answer with the
      // question missing.
      let attachments = viewModel.media(for: message)
      if !attachments.isEmpty {
        attachmentStrip(attachments)
      }
    }
    .padding(13)
    .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 14))
    .overlay {
      RoundedRectangle(cornerRadius: 14)
        .strokeBorder(roleTint(message.role).opacity(0.16), lineWidth: 0.7)
    }
  }

  /// Files whose message is no longer in the transcript still get shown, because
  /// silently dropping them would make the conversation look smaller than it was.
  private var orphanedAttachments: some View {
    VStack(alignment: .leading, spacing: 7) {
      Label("Outros anexos", systemImage: "paperclip")
        .font(.caption.bold())
        .foregroundStyle(.secondary)
      attachmentStrip(viewModel.unattachedMedia)
    }
    .padding(13)
    .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 14))
  }

  private func attachmentStrip(_ media: [EvieStoredMedia]) -> some View {
    VStack(alignment: .leading, spacing: 6) {
      ForEach(media) { item in
        Button {
          viewModel.revealInFinder(item)
        } label: {
          attachmentLabel(item)
        }
        .buttonStyle(.plain)
        .help("Mostrar \(item.originalName) no Finder")
        .accessibilityLabel("Anexo \(item.originalName). Mostrar no Finder.")
      }
    }
  }

  @ViewBuilder
  private func attachmentLabel(_ item: EvieStoredMedia) -> some View {
    if item.isImage, let image = viewModel.thumbnails[item.id] {
      VStack(alignment: .leading, spacing: 4) {
        Image(nsImage: image)
          .resizable()
          .aspectRatio(contentMode: .fit)
          .frame(maxWidth: 260, maxHeight: 190)
          .clipShape(RoundedRectangle(cornerRadius: 9))
          .overlay {
            RoundedRectangle(cornerRadius: 9)
              .strokeBorder(.secondary.opacity(0.25), lineWidth: 0.7)
          }
        Text(item.originalName)
          .font(.caption2)
          .foregroundStyle(.secondary)
          .lineLimit(1)
      }
    } else {
      HStack(spacing: 7) {
        Image(systemName: attachmentSymbol(item))
          .foregroundStyle(.secondary)
        Text(item.originalName)
          .font(.caption)
          .lineLimit(1)
        Text(byteCountText(item.byteCount))
          .font(.caption2)
          .foregroundStyle(.tertiary)
      }
      .padding(.horizontal, 9)
      .padding(.vertical, 6)
      .background(.quaternary.opacity(0.5), in: RoundedRectangle(cornerRadius: 8))
    }
  }

  private func attachmentSymbol(_ item: EvieStoredMedia) -> String {
    if item.isImage {
      // An image whose thumbnail never arrived: either the file is gone or the
      // format did not decode. Saying so with a distinct icon beats a blank box.
      return "photo"
    }
    return (item.originalName as NSString).pathExtension.lowercased() == "pdf"
      ? "doc.richtext" : "doc"
  }

  private func byteCountText(_ bytes: Int) -> String {
    ByteCountFormatter.string(fromByteCount: Int64(bytes), countStyle: .file)
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
