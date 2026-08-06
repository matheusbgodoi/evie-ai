import AppKit
import EvieCore
import Foundation
import SwiftUI

// Carrying out `/plano`: one model call to write the plan, one per step, one
// to answer, strictly in sequence.

extension OverlayViewModel {
  /// Carries out `/plano`: one call to write the plan, one per step, one to
  /// answer.
  ///
  /// Sequential and never concurrent, which is measured rather than cautious:
  /// this Mac serves one model, and three requests at once took 23.3 s against
  /// 8.1 s for one. Fanning the steps out would cost 2.9× and buy nothing.
  ///
  /// A step that fails does not end the run. Four findings and one gap is a
  /// better evening than four minutes and no answer, and the gap is named in
  /// what she finally says rather than quietly missing from it.
  func runPlan(
    question: String,
    requestID: UUID,
    userMessage: ChatMessage,
    roots: [EvieFileRoot],
    web: (any EvieWebSearching)?,
    client: any AgentClient
  ) async {
    guard !question.isEmpty else {
      finishFailure(PlanFailure.nothingToPlan, requestID: requestID)
      return
    }

    var plan: EviePlan
    do {
      updateActiveArtifact(with: "Dividindo em etapas…")
      let written = try await answer(
        to: EviePlanPrompts.planning(for: question),
        roots: [],
        web: nil,
        client: client
      )
      try Task.checkCancellation()
      plan = EviePlan(question: question, steps: try EviePlanParser.steps(in: written))
    } catch is CancellationError {
      finishCancellation(requestID: requestID)
      return
    } catch let error as EviePlanParser.ParseError {
      // Not a failure worth stopping for. If it will not divide, it is one
      // question, and answering it costs one call instead of four.
      updateActiveArtifact(with: "Isso não se divide em etapas — respondendo direto.")
      await runPlainTurn(
        question: question,
        requestID: requestID,
        userMessage: userMessage,
        roots: roots,
        web: web,
        client: client,
        note: error.errorDescription
      )
      return
    } catch {
      finishFailure(error, requestID: requestID)
      return
    }

    for index in plan.steps.indices {
      guard activeRequestID == requestID else {
        return
      }
      if Task.isCancelled {
        // Everything not reached is marked, so the summary can tell "stopped"
        // from "went wrong".
        for remaining in index..<plan.steps.count {
          plan.steps[remaining].state = .cancelled
        }
        break
      }

      plan.steps[index].state = .running
      updateActiveArtifact(with: plan.progressReport)

      do {
        let result = try await answer(
          to: EviePlanPrompts.step(index, of: plan),
          roots: roots,
          web: web,
          client: client
        )
        try Task.checkCancellation()
        plan.steps[index].state = .done(result)
      } catch is CancellationError {
        for remaining in index..<plan.steps.count {
          plan.steps[remaining].state = .cancelled
        }
        break
      } catch {
        plan.steps[index].state = .failed(
          (error as? LocalizedError)?.errorDescription ?? "não deu certo"
        )
      }
      updateActiveArtifact(with: plan.progressReport)
    }

    guard activeRequestID == requestID else {
      return
    }
    // Nothing at all was found. Asking the model to write an answer out of
    // nothing produces a confident one, which is the worst possible result.
    guard !plan.findings.isEmpty else {
      finishFailure(PlanFailure.nothingFound, requestID: requestID)
      return
    }

    do {
      let written = try await answer(
        to: EviePlanPrompts.synthesis(for: plan),
        roots: [],
        web: nil,
        client: client
      )
      finishPlan(plan, answer: written, requestID: requestID, userMessage: userMessage)
    } catch is CancellationError {
      // The steps still ran, so what they found is shown rather than thrown
      // away for want of a closing paragraph.
      finishPlan(
        plan,
        answer: plan.findings.map { "**\($0.instruction)**\n\($0.result)" }
          .joined(separator: "\n\n"),
        requestID: requestID,
        userMessage: userMessage
      )
    } catch {
      finishFailure(error, requestID: requestID)
    }
  }

  /// One model call, returning what it said.
  func answer(
    to prompt: String,
    roots: [EvieFileRoot],
    web: (any EvieWebSearching)?,
    client: any AgentClient
  ) async throws -> String {
    let outcome = try await EvieAgentLoop(
      web: web,
      vault: roots.isEmpty ? nil : retrieveFromVault,
      offersChanges: false
    ).run(
      messages: [ChatMessage(role: .user, content: prompt)],
      roots: roots,
      client: client
    ) { _ in }
    let text = outcome.answer.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !text.isEmpty else {
      throw TurboFieldfareClientError.emptyStream
    }
    return text
  }

  /// The ordinary turn, for a question that would not divide.
  func runPlainTurn(
    question: String,
    requestID: UUID,
    userMessage: ChatMessage,
    roots: [EvieFileRoot],
    web: (any EvieWebSearching)?,
    client: any AgentClient,
    note: String?
  ) async {
    do {
      let written = try await answer(to: question, roots: roots, web: web, client: client)
      guard activeRequestID == requestID else {
        return
      }
      updateActiveArtifact(with: written)
      onAnswerReady?(EvieRichText(written))
      conversation.append(userMessage)
      conversation.append(ChatMessage(role: .assistant, content: written))
      persistConversation()
      settle(summary: "Respondido direto · somente local")
    } catch is CancellationError {
      finishCancellation(requestID: requestID)
    } catch {
      finishFailure(error, requestID: requestID)
    }
  }

  func finishPlan(
    _ plan: EviePlan,
    answer: String,
    requestID: UUID,
    userMessage: ChatMessage
  ) {
    guard activeRequestID == requestID else {
      return
    }
    // The plan stays above the answer. It is what the minutes were spent on, and
    // hiding it once it is done would make the wait look like nothing happened.
    updateActiveArtifact(with: plan.progressReport + "\n\n" + answer)
    onAnswerReady?(EvieRichText(answer))
    if conversation.count == 1 {
      activeConversationTitle = Self.title(for: userMessage.content)
    }
    conversation.append(userMessage)
    conversation.append(ChatMessage(role: .assistant, content: answer))
    persistConversation()
    settle(
      summary: plan.findings.count == plan.steps.count
        ? "\(plan.steps.count) etapas · somente local"
        : "\(plan.findings.count) de \(plan.steps.count) etapas · somente local"
    )
  }

  /// Puts the interface back the way `finishLoop` leaves it.
  ///
  /// Written once rather than copied, because the six places that clear this
  /// state are exactly how a request leaks and leaves the stop button lit with
  /// nothing running.
  func settle(summary: String) {
    visualState = .completed
    primaryText = "Resposta concluída"
    secondaryText = summary
    activeRequestID = nil
    activeArtifactID = nil
    streamedResponse = ""
    pendingPrompt = nil
    requestTask = nil
    isQuickTextEntryPresented = true
    onLayoutInvalidated?()
  }

  enum PlanFailure: LocalizedError {
    case nothingToPlan
    case nothingFound

    var errorDescription: String? {
      switch self {
      case .nothingToPlan:
        "Escreva o que você quer depois de /plano."
      case .nothingFound:
        "Nenhuma etapa achou nada, então não tenho com o que responder."
      }
    }
  }
}

// MARK: - Searching
