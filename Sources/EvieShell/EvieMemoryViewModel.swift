import EvieCore
import Foundation

/// What Evie remembers, and the only place it is written.
///
/// She can propose; only a click here stores anything. That split is the whole
/// point: a memory that writes itself turns one misunderstanding into a permanent
/// fact, and every later answer built on it is wrong in a way whose origin nobody
/// can trace.
@MainActor
final class EvieMemoryViewModel: ObservableObject {
  @Published private(set) var entries: [EvieMemoryEntry] = []
  /// Things she asked to keep, still waiting on an answer.
  @Published private(set) var proposals: [Proposal] = []
  @Published private(set) var feedback: Feedback?

  /// Called whenever what she remembers changes, so her instructions are rebuilt
  /// before the next question rather than before the next launch.
  var onChange: (@MainActor () -> Void)?

  struct Proposal: Identifiable, Hashable {
    let id = UUID()
    var text: String
  }

  struct Feedback: Equatable {
    var message: String
    var isError: Bool
  }

  private let store: EvieMemoryStore

  init(store: EvieMemoryStore = EvieMemoryStore()) {
    self.store = store
    entries = store.load()
  }

  /// Puts a proposal on screen. Stores nothing.
  func propose(_ text: String) {
    let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !trimmed.isEmpty else {
      return
    }
    // Already known, or already asked in this session: asking again is noise.
    guard
      !entries.contains(where: { $0.text.caseInsensitiveCompare(trimmed) == .orderedSame }),
      !proposals.contains(where: { $0.text.caseInsensitiveCompare(trimmed) == .orderedSame })
    else {
      return
    }
    proposals.append(Proposal(text: trimmed))
  }

  func accept(_ proposal: Proposal) {
    proposals.removeAll { $0.id == proposal.id }
    do {
      let updated = try store.remember(proposal.text, in: entries)
      try store.save(updated)
      entries = updated
      onChange?()
      feedback = Feedback(message: "Guardado.", isError: false)
    } catch {
      feedback = Feedback(
        message: (error as? LocalizedError)?.errorDescription ?? "Não consegui guardar isso.",
        isError: true
      )
    }
  }

  func decline(_ proposal: Proposal) {
    proposals.removeAll { $0.id == proposal.id }
  }

  func forget(_ entry: EvieMemoryEntry) {
    let updated = store.forget(id: entry.id, in: entries)
    do {
      try store.save(updated)
      entries = updated
      onChange?()
      feedback = Feedback(message: "Ela esqueceu isso.", isError: false)
    } catch {
      feedback = Feedback(message: "Não consegui apagar essa lembrança.", isError: true)
    }
  }

  /// Adds something the user typed themselves, without her asking.
  func remember(_ text: String) {
    do {
      let updated = try store.remember(text, in: entries)
      try store.save(updated)
      entries = updated
      onChange?()
      feedback = Feedback(message: "Guardado.", isError: false)
    } catch {
      feedback = Feedback(
        message: (error as? LocalizedError)?.errorDescription ?? "Não consegui guardar isso.",
        isError: true
      )
    }
  }

  func forgetEverything() {
    do {
      try store.save([])
      entries = []
      onChange?()
      feedback = Feedback(message: "Ela não lembra mais de nada sobre você.", isError: false)
    } catch {
      feedback = Feedback(message: "Não consegui limpar a memória.", isError: true)
    }
  }
}
