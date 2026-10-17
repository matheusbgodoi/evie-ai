import AppKit
import EvieCore
import Foundation
import SwiftUI

// `/buscar` and `/web` — the two commands that change where an answer comes
// from rather than how it is produced.

extension OverlayViewModel {
  /// Carries out `/buscar`: retrieval over the notes, and nothing else.
  ///
  /// No model call at any point, including when nothing is found. A question
  /// costs a whole turn before a word appears; this costs a lookup, and when
  /// what you wanted was the note itself the turn was never buying anything.
  func runVaultSearch(term: String, requestID: UUID) async {
    guard !term.isEmpty else {
      finishFailure(SearchCommandFailure.nothingToFind, requestID: requestID)
      return
    }
    // The same closure an ordinary question uses, so there is one retrieval path
    // and `/buscar` cannot drift away from what a question would have found.
    guard let retrieve = retrieveFromVault else {
      finishFailure(SearchCommandFailure.noNotes, requestID: requestID)
      return
    }

    // An index that does not exist yet and one that holds nothing relevant give
    // the same empty answer, and the difference is everything: one means "your
    // notes do not mention this" and the other means "I have not read them".
    // Reporting the second as the first is how a search told him his notes were
    // empty when they were only unread.
    if indexedPassageCount() == 0 {
      finishFailure(SearchCommandFailure.notesNotRead, requestID: requestID)
      return
    }

    updateActiveArtifact(with: "Procurando nas suas anotações…")
    let found = await retrieve(term)
    guard activeRequestID == requestID else {
      return
    }

    updateActiveArtifact(with: EvieVaultSearchReport.text(for: found, query: term))
    // Only when something was found. The label for "nothing consulted" is the
    // warning about answering from memory, and nothing here was answered from
    // memory — putting that line under a search result would teach him to
    // ignore it where it matters.
    if !found.isEmpty {
      setProvenance(
        EvieAnswerProvenance(usedLocalKnowledge: true),
        on: activeArtifactID
      )
    }
    // Nothing is spoken and nothing joins the conversation. The passages are
    // his own notes, quoted; handing them to the next turn as something Evie
    // said would strip the fence that keeps note text data rather than
    // instruction, and reading six passages out loud is unbearable.
    // "Somente local" stays here, alone among the status lines: a note search
    // reads this Mac's index and asks no brain anything.
    settle(
      summary: found.isEmpty
        ? "Nada nas anotações · somente local"
        : "\(found.count) trechos · somente local"
    )
  }

  /// Carries out `/web`: the ordinary turn with the notes step skipped.
  ///
  /// The question is sent without its command, because "/web" is addressed to
  /// Evie and not part of what is being asked.
  func runWebOnlyTurn(
    question: String,
    requestID: UUID,
    userMessage: ChatMessage,
    roots: [EvieFileRoot],
    web: any EvieWebSearching,
    on brain: ResolvedBrain
  ) async throws {
    let plan = EvieTurnPlan(brain)
    let messages = try await conversationPrefix(
      adding: ChatMessage(role: .user, content: question),
      plan: plan, client: brain.client
    )
    // No vault, because the whole point is not to consult it. Passing it and
    // ignoring the result would still pay for the retrieval. A capture still
    // replayed from an earlier turn — as pixels, or as the text sent beside
    // them once they are a marker (`derivedFromPicture`) — keeps the model
    // away from the web tools: the search runs first, on the question's own
    // words.
    let offersTools =
      plan.route(
        hasRoots: !roots.isEmpty,
        searchesTheWeb: true,
        readsMailAndCalendar: false,
        carriesPicture: EvieTurnPlan.carriesPicture(messages)
      ) == .agentLoop(offersTools: true)
    let outcome = try await EvieAgentLoop(
      web: web,
      vault: nil,
      offersChanges: false,
      offersTools: offersTools,
      readiness: plan.readiness,
      modelFamily: plan.profile.family
    )
    .run(
      messages: messages,
      roots: roots,
      client: brain.client,
      skipsNotes: true
    ) { [weak self] event in
      await self?.receiveDuringLoop(event, requestID: requestID)
    }
    try Task.checkCancellation()
    finishLoop(outcome, requestID: requestID, userMessage: userMessage)
  }

  enum SearchCommandFailure: LocalizedError {
    case nothingToFind
    case noNotes
    case notesNotRead
    case nothingToAsk
    case webIsOff

    var errorDescription: String? {
      switch self {
      case .nothingToFind:
        "Escreva o que você quer achar depois de /buscar."
      case .noNotes:
        "Ainda não tenho anotações indexadas — autorize a pasta do seu vault em Configurações."
      case .notesNotRead:
        "Ainda estou lendo suas anotações pela primeira vez. Leva menos de um "
          + "minuto; tente de novo em seguida."
      case .nothingToAsk:
        "Escreva a pergunta depois de /web."
      case .webIsOff:
        "A busca na web está desligada. Ligue em Configurações e tente de novo."
      }
    }
  }
}
