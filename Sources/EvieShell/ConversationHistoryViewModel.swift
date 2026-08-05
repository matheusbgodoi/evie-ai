import EvieCore
import Foundation

@MainActor
final class ConversationHistoryViewModel: ObservableObject {
  @Published private(set) var conversations: [EvieConversationSummary] = []
  @Published var selectedID: UUID?
  @Published private(set) var selectedConversation: EvieConversation?
  @Published private(set) var isLoading = false
  @Published private(set) var isLoadingSelection = false
  @Published private(set) var isDeleting = false
  @Published private(set) var unavailableRecordCount = 0
  @Published private(set) var errorMessage: String?
  @Published var showsDeleteConfirmation = false

  private let store: EvieConversationStore
  private let onContinue: @MainActor (UUID) -> Void
  private let onNewConversation: @MainActor () -> Void
  private let onPrepareDelete: @MainActor (UUID) async -> Void
  private let onDelete: @MainActor (UUID) -> Void
  private var refreshTask: Task<Void, Never>?
  private var selectionTask: Task<Void, Never>?

  init(
    store: EvieConversationStore,
    onContinue: @escaping @MainActor (UUID) -> Void,
    onNewConversation: @escaping @MainActor () -> Void,
    onPrepareDelete: @escaping @MainActor (UUID) async -> Void,
    onDelete: @escaping @MainActor (UUID) -> Void
  ) {
    self.store = store
    self.onContinue = onContinue
    self.onNewConversation = onNewConversation
    self.onPrepareDelete = onPrepareDelete
    self.onDelete = onDelete
  }

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

        if let selectedID, latest.contains(where: { $0.id == selectedID }) {
          loadSelection()
        } else {
          selectedID = latest.first?.id
          loadSelection()
        }
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
      } catch is CancellationError {
        return
      } catch {
        selectedConversation = nil
        errorMessage = error.localizedDescription
      }
    }
  }

  func continueSelectedConversation() {
    guard let selectedConversation, selectedConversation.id == selectedID else { return }
    onContinue(selectedConversation.id)
  }

  func createNewConversation() {
    onNewConversation()
  }

  func deleteSelectedConversation() {
    guard
      !isDeleting,
      let deletingID = selectedConversation?.id,
      deletingID == selectedID
    else { return }
    isDeleting = true

    Task { @MainActor [weak self] in
      guard let self else { return }
      defer { isDeleting = false }
      do {
        await onPrepareDelete(deletingID)
        try await store.delete(id: deletingID)
        onDelete(deletingID)
        if self.selectedID == deletingID {
          self.selectedID = nil
          selectedConversation = nil
        }
        refresh()
      } catch {
        errorMessage = error.localizedDescription
      }
    }
  }

  var canActOnSelection: Bool {
    !isLoadingSelection
      && !isDeleting
      && selectedConversation?.id == selectedID
  }
}
