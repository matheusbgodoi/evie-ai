import AppKit
import EvieCore
import Foundation
import UniformTypeIdentifiers

@MainActor
final class ConversationHistoryViewModel: ObservableObject {
  @Published private(set) var conversations: [EvieConversationSummary] = []
  /// The sidebar selection, as a set because the list allows more than one row.
  ///
  /// Everything that acts on "the selection" reads this. The detail pane still
  /// shows a single conversation, because reading two transcripts at once is not
  /// a thing anyone does — it shows the one row when there is exactly one.
  @Published var selectedIDs: Set<UUID> = []
  @Published private(set) var selectedConversation: EvieConversation?
  @Published private(set) var isLoading = false
  @Published private(set) var isLoadingSelection = false
  @Published private(set) var isDeleting = false
  @Published private(set) var isExporting = false
  @Published private(set) var unavailableRecordCount = 0
  @Published private(set) var errorMessage: String?
  @Published private(set) var statusMessage: String?
  /// Thumbnails for the open conversation's pictures, read off disk once.
  ///
  /// Kept here rather than loaded from the view body: a body runs whenever
  /// anything around it changes, and decoding a HEIC every time would make
  /// scrolling a long conversation stutter.
  @Published private(set) var thumbnails: [UUID: NSImage] = [:]

  private let store: EvieConversationStore
  private let mediaStore: EvieMediaStore
  private let onContinue: @MainActor (UUID) -> Void
  private let onNewConversation: @MainActor () -> Void
  private let onPrepareDelete: @MainActor (UUID) async -> Void
  private let onDelete: @MainActor (UUID) -> Void
  private var refreshTask: Task<Void, Never>?
  private var selectionTask: Task<Void, Never>?

  init(
    store: EvieConversationStore,
    mediaStore: EvieMediaStore = EvieMediaStore(),
    onContinue: @escaping @MainActor (UUID) -> Void,
    onNewConversation: @escaping @MainActor () -> Void,
    onPrepareDelete: @escaping @MainActor (UUID) async -> Void,
    onDelete: @escaping @MainActor (UUID) -> Void
  ) {
    self.store = store
    self.mediaStore = mediaStore
    self.onContinue = onContinue
    self.onNewConversation = onNewConversation
    self.onPrepareDelete = onPrepareDelete
    self.onDelete = onDelete
  }

  /// The one selected row, or nothing when the selection is empty or plural.
  var selectedID: UUID? {
    selectedIDs.count == 1 ? selectedIDs.first : nil
  }

  var selectionCount: Int {
    selectedIDs.count
  }

  var hasSelection: Bool {
    !selectedIDs.isEmpty
  }

  var canActOnSelection: Bool {
    !isLoadingSelection
      && !isDeleting
      && selectedConversation?.id == selectedID
  }

  var canModifySelection: Bool {
    hasSelection && !isDeleting && !isExporting
  }

  // MARK: - Loading

  func refresh() {
    refreshTask?.cancel()
    refreshTask = Task { @MainActor [weak self] in
      guard let self else { return }
      isLoading = true
      errorMessage = nil
      defer { isLoading = false }

      do {
        let scan = try await store.scan()
        try Task.checkCancellation()
        let latest = scan.conversations
        conversations = latest
        unavailableRecordCount = scan.unavailableRecordCount

        // Rows that no longer exist must leave the selection, or a later delete
        // or export would be aimed at records that are already gone.
        let surviving = Set(latest.map(\.id))
        selectedIDs.formIntersection(surviving)
        if selectedIDs.isEmpty, let first = latest.first?.id {
          selectedIDs = [first]
        }
        loadSelection()
      } catch is CancellationError {
        return
      } catch {
        selectedConversation = nil
        errorMessage = error.localizedDescription
      }
    }
  }

  func loadSelection() {
    selectionTask?.cancel()
    thumbnails = [:]
    guard let selectedID else {
      selectedConversation = nil
      isLoadingSelection = false
      return
    }
    selectedConversation = nil
    isLoadingSelection = true
    errorMessage = nil

    selectionTask = Task { @MainActor [weak self] in
      guard let self else { return }
      defer {
        if self.selectedID == selectedID {
          self.isLoadingSelection = false
        }
      }
      do {
        let conversation = try await store.load(id: selectedID)
        try Task.checkCancellation()
        guard self.selectedID == selectedID else { return }
        selectedConversation = conversation
        errorMessage = nil
        await loadThumbnails(for: conversation)
      } catch is CancellationError {
        return
      } catch {
        selectedConversation = nil
        errorMessage = error.localizedDescription
      }
    }
  }

  // MARK: - Attachments

  /// Where a stored file lives, or nothing when the record outlived the file.
  func mediaURL(for media: EvieStoredMedia) -> URL? {
    mediaStore.url(for: media)
  }

  func media(for message: ChatMessage) -> [EvieStoredMedia] {
    selectedConversation?.media.filter { $0.messageID == message.id } ?? []
  }

  /// Attachments whose message is gone, so nothing is silently hidden.
  var unattachedMedia: [EvieStoredMedia] {
    guard let conversation = selectedConversation else { return [] }
    let messageIDs = Set(conversation.messages.map(\.id))
    return conversation.media.filter { media in
      guard let messageID = media.messageID else { return true }
      return !messageIDs.contains(messageID)
    }
  }

  func revealInFinder(_ media: EvieStoredMedia) {
    guard let url = mediaURL(for: media) else {
      errorMessage = "O arquivo \(media.originalName) não está mais neste Mac."
      return
    }
    NSWorkspace.shared.activateFileViewerSelecting([url])
  }

  private func loadThumbnails(for conversation: EvieConversation) async {
    let images = conversation.media.filter(\.isImage)
    guard !images.isEmpty else { return }

    for item in images {
      guard let url = mediaURL(for: item) else { continue }
      // Read off the main actor: a HEIC decode on the main thread is a visible
      // hitch while the window is being scrolled.
      let data = await Task.detached(priority: .utility) {
        try? Data(contentsOf: url)
      }.value
      guard let data, let image = NSImage(data: data) else { continue }
      guard selectedConversation?.id == conversation.id else { return }
      thumbnails[item.id] = image
    }
  }

  // MARK: - Actions on the selection

  func continueSelectedConversation() {
    guard let selectedConversation, selectedConversation.id == selectedID else { return }
    onContinue(selectedConversation.id)
  }

  func createNewConversation() {
    onNewConversation()
  }

  /// Asks first, then deletes every selected conversation.
  func confirmDeleteSelected() {
    let targets = orderedSelection()
    guard !targets.isEmpty else { return }
    let question =
      targets.count == 1
      ? "Excluir esta conversa deste Mac?"
      : "Excluir \(targets.count) conversas deste Mac?"
    confirm(
      question: question,
      explanation:
        "Isso remove o histórico local escolhido e os arquivos anexados a ele. Não dá para desfazer.",
      destructiveTitle: "Excluir permanentemente"
    ) { [weak self] in
      self?.delete(ids: targets)
    }
  }

  /// Asks first, then deletes everything the history lists.
  func confirmDeleteAll() {
    let targets = conversations.map(\.id)
    guard !targets.isEmpty else { return }
    confirm(
      question: "Excluir todas as \(targets.count) conversas deste Mac?",
      explanation:
        "Isso apaga todo o histórico local e os arquivos anexados a ele. Não dá para desfazer.",
      destructiveTitle: "Excluir tudo"
    ) { [weak self] in
      self?.delete(ids: targets)
    }
  }

  /// Deletes through the store, one at a time.
  ///
  /// The store is the only correct route: it tells its observer about each
  /// deletion, and that is what removes the attached files. Unlinking the JSON
  /// directly would leave the pictures behind forever.
  private func delete(ids: [UUID]) {
    guard !isDeleting, !ids.isEmpty else { return }
    isDeleting = true
    statusMessage = nil

    Task { @MainActor [weak self] in
      guard let self else { return }
      defer { isDeleting = false }
      var failures = 0
      for id in ids {
        await onPrepareDelete(id)
        do {
          try await store.delete(id: id)
          onDelete(id)
          selectedIDs.remove(id)
        } catch {
          // One unreadable record must not stop the rest: a person who asked to
          // clear the history should not be left with a partly cleared history
          // and no explanation.
          failures += 1
          errorMessage = error.localizedDescription
        }
      }
      if failures == 0 {
        errorMessage = nil
        statusMessage = ids.count == 1 ? "Conversa excluída." : "\(ids.count) conversas excluídas."
      }
      selectedConversation = nil
      refresh()
    }
  }

  // MARK: - Export

  /// Saves the selection as Markdown: one file gets a save panel, several get a
  /// folder to be written into.
  func exportSelected() {
    let targets = orderedSelection()
    guard !targets.isEmpty, !isExporting else { return }
    if targets.count == 1 {
      exportSingle(id: targets[0])
    } else {
      exportMany(ids: targets)
    }
  }

  private func exportSingle(id: UUID) {
    isExporting = true
    statusMessage = nil
    Task { @MainActor [weak self] in
      guard let self else { return }
      do {
        let conversation = try await store.load(id: id)
        let panel = NSSavePanel()
        panel.nameFieldStringValue = EvieConversationExport.fileName(for: conversation)
        panel.allowedContentTypes = [Self.markdownType]
        panel.isExtensionHidden = false
        panel.message = "Escolha onde salvar a conversa em Markdown."
        panel.prompt = "Exportar"

        guard let host = hostWindow() else {
          isExporting = false
          errorMessage = "Não há janela para abrir o painel de exportação."
          return
        }
        panel.beginSheetModal(for: host) { [weak self] response in
          // A sheet, not `runModal()`: Evie runs as an accessory app, and a modal
          // panel there takes focus away from the window it belongs to.
          MainActor.assumeIsolated {
            guard let self else { return }
            self.isExporting = false
            guard response == .OK, let url = panel.url else { return }
            self.write(EvieConversationExport.markdown(for: conversation), to: url, count: 1)
          }
        }
      } catch {
        isExporting = false
        errorMessage = error.localizedDescription
      }
    }
  }

  private func exportMany(ids: [UUID]) {
    let panel = NSOpenPanel()
    panel.canChooseFiles = false
    panel.canChooseDirectories = true
    panel.allowsMultipleSelection = false
    panel.canCreateDirectories = true
    panel.prompt = "Exportar"
    panel.message = "Escolha a pasta que vai receber \(ids.count) arquivos Markdown."

    guard let host = hostWindow() else {
      errorMessage = "Não há janela para abrir o painel de exportação."
      return
    }
    isExporting = true
    statusMessage = nil
    panel.beginSheetModal(for: host) { [weak self] response in
      MainActor.assumeIsolated {
        guard let self else { return }
        guard response == .OK, let directory = panel.url else {
          self.isExporting = false
          return
        }
        self.writeAll(ids: ids, into: directory)
      }
    }
  }

  private func writeAll(ids: [UUID], into directory: URL) {
    Task { @MainActor [weak self] in
      guard let self else { return }
      defer { isExporting = false }
      var written = 0
      var usedNames: Set<String> = []
      for id in ids {
        do {
          let conversation = try await store.load(id: id)
          let url = directory.appendingPathComponent(
            Self.uniqueName(EvieConversationExport.fileName(for: conversation), taken: &usedNames)
          )
          try EvieConversationExport.markdown(for: conversation)
            .write(to: url, atomically: true, encoding: .utf8)
          written += 1
        } catch {
          errorMessage = error.localizedDescription
        }
      }
      if written > 0 {
        statusMessage = "\(written) de \(ids.count) conversas exportadas."
      }
    }
  }

  private func write(_ markdown: String, to url: URL, count: Int) {
    do {
      try markdown.write(to: url, atomically: true, encoding: .utf8)
      errorMessage = nil
      statusMessage = count == 1 ? "Conversa exportada." : "\(count) conversas exportadas."
    } catch {
      errorMessage = error.localizedDescription
    }
  }

  /// Two conversations can share a title, and the second must not overwrite the
  /// first without anyone noticing.
  static func uniqueName(_ name: String, taken: inout Set<String>) -> String {
    guard taken.contains(name) else {
      taken.insert(name)
      return name
    }
    let base = (name as NSString).deletingPathExtension
    let ext = (name as NSString).pathExtension
    var index = 2
    while true {
      let candidate = ext.isEmpty ? "\(base) \(index)" : "\(base) \(index).\(ext)"
      if !taken.contains(candidate) {
        taken.insert(candidate)
        return candidate
      }
      index += 1
    }
  }

  // MARK: - Panels

  private static let markdownType: UTType =
    UTType(filenameExtension: "md") ?? .plainText

  /// The window this history lives in.
  ///
  /// Sheets need a window, and an accessory app can have none when nothing was
  /// clicked, so callers must handle nothing coming back.
  private func hostWindow() -> NSWindow? {
    NSApp.keyWindow ?? NSApp.mainWindow ?? NSApp.windows.first(where: \.isVisible)
  }

  /// Both deletions ask before acting, as a sheet on the history window.
  private func confirm(
    question: String,
    explanation: String,
    destructiveTitle: String,
    perform: @escaping @MainActor () -> Void
  ) {
    let alert = NSAlert()
    alert.alertStyle = .warning
    alert.messageText = question
    alert.informativeText = explanation
    let destructive = alert.addButton(withTitle: destructiveTitle)
    destructive.hasDestructiveAction = true
    alert.addButton(withTitle: "Cancelar")

    guard let host = hostWindow() else {
      if alert.runModal() == .alertFirstButtonReturn {
        perform()
      }
      return
    }
    alert.beginSheetModal(for: host) { response in
      MainActor.assumeIsolated {
        guard response == .alertFirstButtonReturn else { return }
        perform()
      }
    }
  }

  /// The selection in the order the list shows it, so exported files come out in
  /// the order the person was looking at.
  private func orderedSelection() -> [UUID] {
    conversations.map(\.id).filter { selectedIDs.contains($0) }
  }
}
