import AppKit
import EvieCore

/// Agent mode in the chat: the session card, the confirmation cards, the
/// session itself and the log at its end (ADR 0016).
///
/// A session begins only from his own request — typed, push-to-talk, or a
/// click on the mark, never the wake word (`ComputerUseStart`) — and then a
/// click by a hand on Começar. Every answer to a card goes through
/// `ComputerConfirmationDesk` or `ComputerUserPress`, which ignore Evie's own
/// clicks and every key.
extension OverlayViewModel {
  /// Reads the request as a computer-use instruction. Returns true when it
  /// was one: the session card or the reason there can be none is on
  /// screen, and nothing else happens for this request.
  func offerComputerUse(for prompt: String) -> Bool {
    guard let host = computerUse else {
      return false
    }
    let explicitlyAsked = asksForComputerGoal
    asksForComputerGoal = false
    let offer = ComputerUseStart.offer(
      for: prompt,
      origin: lastPromptWasSpoken ? spokenOrigin : .typed,
      explicitlyAsked: explicitlyAsked,
      isEnabled: host.isEnabled,
      profile: brainResolver.expectedProfile(for: activeConversationID),
      apps: host.apps()
    )
    switch offer {
    case .none:
      return false
    case .explain(let reason):
      quickText = ""
      artifacts.removeAll { !$0.isAwaitingDecision }
      artifacts.append(
        ArtifactCardModel(
          kind: .computer, title: "Não vou controlar o Mac agora", question: prompt,
          summary: reason, isExpanded: true))
      primaryText = "Nada foi feito no Mac"
      secondaryText = nil
      onLayoutInvalidated?()
      return true
    case .propose(let goal):
      quickText = ""
      presentSessionCard(goal: goal)
      return true
    }
  }

  /// "Controlar o Mac…" in the menu: the next request, said or typed, is a
  /// session goal, whatever its words.
  func askForComputerGoal() {
    asksForComputerGoal = true
    secondaryText = ComputerUseCopy.askForGoal
    onLayoutInvalidated?()
  }

  /// The card with his goal. Começar takes a hand; the first time, the card
  /// is the consent, and Começar accepts it.
  func presentSessionCard(goal: String) {
    if let earlier = pendingSession {
      artifacts.removeAll { $0.id == earlier.card }
    }
    let card = UUID()
    let consented = computerUseConsentGiven()
    pendingSession = (card, goal)
    artifacts.removeAll { !$0.isAwaitingDecision }
    artifacts.append(
      ArtifactCardModel(
        id: card,
        kind: .computer,
        title: ComputerUseCopy.sessionTitle,
        question: goal,
        summary: consented ? ComputerUseCopy.sessionTerms : ComputerUseCopy.consent,
        isExpanded: true,
        actions: [
          ArtifactActionModel(
            id: "cu-start:\(card.uuidString)",
            title: consented ? ComputerUseCopy.start : ComputerUseCopy.consentAccept,
            systemImage: "play.fill", role: .primary, needsHand: true),
          ArtifactActionModel(
            id: "cu-cancel:\(card.uuidString)", title: ComputerUseCopy.notNow,
            systemImage: "xmark", role: .secondary, needsHand: true),
        ]
      )
    )
    primaryText = "Confirme para eu controlar o Mac"
    secondaryText = nil
    onLayoutInvalidated?()
  }

  /// A press on a button only a hand may press.
  func performArtifactPress(_ id: UUID, action: ArtifactActionModel, press: ComputerUserPress) {
    let parts = action.id.split(separator: ":", maxSplits: 1).map(String.init)
    guard parts.count == 2 else {
      return
    }
    switch parts[0] {
    case "cu-start":
      guard press.mayApprove, let session = pendingSession, session.card == id else {
        return
      }
      pendingSession = nil
      artifacts.removeAll { $0.id == id }
      if !computerUseConsentGiven() {
        onComputerUseConsent?()
      }
      startComputerUse(goal: session.goal)
    case "cu-cancel":
      guard press.mayDecline else {
        return
      }
      dismissComputerUseCard(id)
      artifacts.removeAll { $0.id == id }
      primaryText = "Nada foi feito no Mac"
      onLayoutInvalidated?()
    case "cu-do", "cu-skip":
      guard let confirmation = UUID(uuidString: parts[1]) else {
        return
      }
      computerUse?.desk.answer(confirmation, parts[0] == "cu-do" ? .perform : .skip, by: press)
    default:
      break
    }
  }

  /// Closing a card with the ×: the session card starts nothing, a
  /// confirmation is a no.
  func dismissComputerUseCard(_ id: UUID) {
    if pendingSession?.card == id {
      pendingSession = nil
    }
    if let waiting = computerUse?.desk.waiting, confirmationCards[waiting.confirmation.id] == id {
      computerUse?.desk.withdraw()
    }
  }

  /// The card ids of the confirmations on screen, by confirmation id.
  var confirmationCards: [UUID: UUID] {
    Dictionary(
      uniqueKeysWithValues: artifacts.compactMap { card in
        card.actions.first { $0.id.hasPrefix("cu-do:") }
          .flatMap { UUID(uuidString: String($0.id.dropFirst("cu-do:".count))) }
          .map { ($0, card.id) }
      })
  }

  /// The confirmation card: amber, the policy's question, the newest
  /// picture with the target marked, Fazer and Pular for a hand only.
  func presentConfirmation(_ request: ComputerConfirmationRequest) {
    let id = request.confirmation.id
    artifacts.append(
      ArtifactCardModel(
        kind: .computer,
        title: request.text,
        summary: "A Evie quer fazer isso agora. Confira na imagem.",
        isExpanded: true,
        actions: [
          ArtifactActionModel(
            id: "cu-do:\(id.uuidString)", title: ComputerUseCopy.perform,
            systemImage: "checkmark", role: .primary, needsHand: true),
          ArtifactActionModel(
            id: "cu-skip:\(id.uuidString)", title: ComputerUseCopy.skip,
            systemImage: "forward.fill", role: .secondary, needsHand: true),
        ],
        thumbnail: request.picture.flatMap { ArtifactThumbnail($0, mark: request.mark) }
      )
    )
    primaryText = "Esperando você confirmar"
    onLayoutInvalidated?()
  }

  func closeConfirmation(_ id: UUID) {
    if let card = confirmationCards[id] {
      artifacts.removeAll { $0.id == card }
      onLayoutInvalidated?()
    }
  }

  // MARK: - The session

  /// After Começar: the permissions (asked once each), then the session as
  /// a turn of its own, cancelled like any other.
  func startComputerUse(goal: String) {
    guard let host = computerUse, !hasActiveRequest, !isResearchBusy() else {
      NSSound.beep()
      return
    }
    if let missing = host.missingPermission() {
      artifacts.append(
        ArtifactCardModel(
          kind: .computer, title: "Falta uma permissão", question: goal, summary: missing,
          isExpanded: true))
      primaryText = "Nada foi feito no Mac"
      onLayoutInvalidated?()
      return
    }
    let requestID = UUID()
    let userMessage = ChatMessage(role: .user, content: goal)
    activeRequestID = requestID
    activeArtifactID = userMessage.id
    streamedResponse = ""
    pendingPrompt = nil
    visualState = .thinking
    primaryText = "Controlando o Mac…"
    secondaryText = ComputerUseCopy.sessionTerms
    artifacts.append(
      ArtifactCardModel(
        id: userMessage.id, kind: .computer, title: "", question: goal, summary: "",
        isExpanded: true, isLoading: true))
    onLayoutInvalidated?()
    let conversationID = activeConversationID
    requestTask = Task { @MainActor [weak self] in
      await self?.runComputerUse(
        userMessage: userMessage, conversation: conversationID, requestID: requestID)
    }
  }

  func runComputerUse(userMessage: ChatMessage, conversation id: UUID, requestID: UUID) async {
    guard let host = computerUse else {
      return
    }
    let brain = await brainResolver.resolve(conversation: id)
    defer { brainResolver.turnEnded(conversation: id) }
    guard activeRequestID == requestID, !Task.isCancelled else {
      return
    }
    adoptAnsweringBrain(brain)
    guard EvieAgentModeBroker.unavailableReason(on: brain.profile) == nil else {
      finishComputerUse(
        summary: ComputerUseCopy.needsThePC, log: nil, userMessage: userMessage,
        requestID: requestID, ending: "não começou")
      return
    }
    let log = ComputerActionLog()
    guard let session = host.begin(goal: userMessage.content, on: brain.profile, log: log) else {
      finishComputerUse(
        summary: ComputerUseCopy.switchedOff, log: nil, userMessage: userMessage,
        requestID: requestID, ending: "não começou")
      return
    }
    host.desk.onShow = { [weak self] request in self?.presentConfirmation(request) }
    host.desk.onClose = { [weak self] confirmation in self?.closeConfirmation(confirmation) }
    // The conversation's words, without pictures, so "cola isso no Notas"
    // knows what "isso" is.
    let messages =
      conversation.map { message in
        var plain = message
        plain.images = nil
        return plain
      } + [userMessage]

    do {
      let outcome = try await EvieAgentLoop(readiness: brain.rung).runComputerUse(
        messages: messages,
        client: brain.client,
        session: session,
        emit: { [weak self] event in
          await self?.showComputerUseStatus(event)
        }
      )
      host.end()
      finishComputerUse(
        summary: Self.summary(of: outcome), log: log, userMessage: userMessage,
        requestID: requestID, ending: Self.ending(of: outcome))
    } catch is CancellationError {
      host.end()
      finishComputerUse(
        summary: "Parei. Nada mais foi feito no Mac depois disso.", log: log,
        userMessage: userMessage, requestID: requestID, ending: "interrompida")
    } catch {
      host.end()
      finishComputerUse(
        summary: error.localizedDescription, log: log, userMessage: userMessage,
        requestID: requestID, ending: "falhou")
    }
  }

  /// Parar, Esc, ⌥⇧Esc, "para" or the grant running out: the grant is
  /// revoked and the task cancelled before the indicator moves at all.
  /// Returns whether a session was running.
  @discardableResult
  func stopComputerUse() -> Bool {
    guard let host = computerUse, host.isRunning else {
      return false
    }
    host.end()
    requestTask?.cancel()
    host.takeDownPresence()
    return true
  }

  func showComputerUseStatus(_ event: EvieInteractionEvent) {
    guard case .status(let message) = event, hasActiveRequest else {
      return
    }
    primaryText = message
    onLayoutInvalidated?()
  }

  /// The card at the end: how it ended, and the log of what was done.
  ///
  /// The conversation keeps his request and one line of Evie's own about
  /// the session; the log, the model's summary and every picture stay on
  /// screen and in memory, since they come from the screen.
  func finishComputerUse(
    summary: String,
    log: ComputerActionLog?,
    userMessage: ChatMessage,
    requestID: UUID,
    ending: String
  ) {
    guard activeRequestID == requestID else {
      return
    }
    let actions = log?.entries.filter { $0.kind == .done || $0.kind == .noChange }.count ?? 0
    if let index = artifacts.firstIndex(where: { $0.id == activeArtifactID }) {
      artifacts[index] = ArtifactCardModel(
        id: artifacts[index].id,
        kind: .computer,
        title: "O que eu fiz no Mac",
        question: userMessage.content,
        summary: summary,
        detail: log?.text,
        isExpanded: true
      )
    }
    if conversation.count == 1 {
      activeConversationTitle = Self.title(for: userMessage.content)
    }
    conversation.append(userMessage)
    conversation.append(
      ChatMessage(
        role: .assistant,
        content: "[Sessão de controle do Mac \(ending): \(actions) "
          + (actions == 1 ? "ação feita." : "ações feitas.") + "]"))
    persistConversation()

    visualState = .completed
    primaryText = "Sessão \(ending)"
    secondaryText = answeringLocation.statusTag
    activeRequestID = nil
    activeArtifactID = nil
    requestTask = nil
    isQuickTextEntryPresented = true
    onLayoutInvalidated?()
  }

  /// The model's own account is screen-derived, so it is shown as one plain
  /// line, never as markup.
  static func summary(of outcome: ComputerUseOutcome) -> String {
    let said = ComputerScreenText.sanitized(outcome.summary, limit: 600)
    return said.isEmpty ? "A sessão terminou." : said
  }

  static func ending(of outcome: ComputerUseOutcome) -> String {
    switch outcome.ending {
    case .finished(.success): "concluída"
    case .finished(.failure): "sem sucesso"
    case .finished(.needUser), .needsUser: "parada para você"
    case .answered: "encerrada"
    case .sessionEnded: "encerrada"
    case .stepLimit: "no limite de passos"
    }
  }
}
