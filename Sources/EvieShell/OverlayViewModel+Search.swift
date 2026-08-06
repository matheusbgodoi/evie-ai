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
    client: any AgentClient
  ) async {
    let messages = conversationPrefix(adding: ChatMessage(role: .user, content: question))
    do {
      // No vault, because the whole point is not to consult it. Passing it and
      // ignoring the result would still pay for the retrieval.
      let outcome = try await EvieAgentLoop(web: web, vault: nil, offersChanges: false)
        .run(
          messages: messages,
          roots: roots,
          client: client,
          skipsNotes: true
        ) { [weak self] event in
          await self?.receiveDuringLoop(event, requestID: requestID)
        }
      try Task.checkCancellation()
      finishLoop(outcome, requestID: requestID, userMessage: userMessage)
    } catch is CancellationError {
      finishCancellation(requestID: requestID)
    } catch {
      finishFailure(error, requestID: requestID)
    }
  }

  enum SearchCommandFailure: LocalizedError {
    case nothingToFind
    case noNotes
    case nothingToAsk
    case webIsOff

    var errorDescription: String? {
      switch self {
      case .nothingToFind:
        "Escreva o que você quer achar depois de /buscar."
      case .noNotes:
        "Ainda não tenho anotações indexadas — autorize a pasta do seu vault em Configurações."
      case .nothingToAsk:
        "Escreva a pergunta depois de /web."
      case .webIsOff:
        "A busca na web está desligada. Ligue em Configurações e tente de novo."
      }
    }
  }
}
