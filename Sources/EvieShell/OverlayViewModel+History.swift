import AppKit
import EvieCore
import Foundation
import SwiftUI

// Which turns are on screen, and which are behind "Ver mensagens anteriores".

extension OverlayViewModel {
  /// How many turns are drawn at once, and how many more each request adds.
  static let artifactPageSize = 12

  /// The messages a person would call "the conversation". Tool calls and their
  /// results are real turns to the model and noise to a reader.
  static func shownMessages(in messages: [ChatMessage]) -> [ChatMessage] {
    messages.filter { message in
      switch message.role {
      case .user:
        return true
      case .assistant:
        // An assistant turn that only asked for a tool has nothing to show.
        return message.toolCalls == nil && !message.content.isEmpty
      case .system, .developer, .tool:
        return false
      }
    }
  }

  /// A question and the answer it produced, which is the unit a person actually
  /// wants back. An assistant turn that only asked for a tool has no answer in
  /// it and is skipped.
  static func turns(in messages: [ChatMessage]) -> [(question: ChatMessage, answer: ChatMessage)] {
    var turns: [(question: ChatMessage, answer: ChatMessage)] = []
    var pending: ChatMessage?

    for message in messages {
      switch message.role {
      case .user:
        pending = message
      case .assistant:
        guard message.toolCalls == nil, !message.content.isEmpty else {
          continue
        }
        if let question = pending {
          turns.append((question, message))
          pending = nil
        }
      default:
        continue
      }
    }
    return turns
  }

  static func cards(
    for turns: [(question: ChatMessage, answer: ChatMessage)]
  ) -> [ArtifactCardModel] {
    turns.map { turn in
      ArtifactCardModel(
        // Keyed on the question, which is what `submitQuickText` keys on too.
        id: turn.question.id,
        kind: .answer,
        // From the answer, the same as a live card, or scrolling back would
        // show one column headed by questions and another by answers depending
        // on which side of a restart you were looking at.
        title: Self.title(fromAnswer: turn.answer.content),
        question: turn.question.content,
        summary: turn.answer.content,
        isExpanded: false,
        actions: Self.answerActions(phase: .idle)
      )
    }
  }

  /// Turns of this conversation that exist but are not drawn.
  ///
  /// The whole conversation is always in memory; the card list is a window onto
  /// it. Rebuilding every card on every turn would be wasteful and would reset
  /// the expansion state of cards the user had opened.
  var earlierTurnCount: Int {
    Self.turns(in: conversation).filter { !isShown($0) }.count
  }

  /// Whether a turn already has a card.
  ///
  /// Either identifier counts. Keying on the question is the rule, and matching
  /// the answer too means a divergence like the one that caused duplicate cards
  /// cannot produce them again.
  func isShown(_ turn: (question: ChatMessage, answer: ChatMessage)) -> Bool {
    let shown = Set(artifacts.map(\.id))
    return shown.contains(turn.question.id) || shown.contains(turn.answer.id)
  }

  /// Brings back the previous page of turns, oldest-last, all closed.
  func loadEarlierTurns() {
    defer { refreshSpeakActions() }
    let hidden = Self.turns(in: conversation).filter { !isShown($0) }
    guard !hidden.isEmpty else {
      return
    }
    artifacts.insert(
      contentsOf: Self.cards(for: Array(hidden.suffix(Self.artifactPageSize))),
      at: 0
    )
    onLayoutInvalidated?()
  }
}

// MARK: - Running a plan
