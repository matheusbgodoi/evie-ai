import AppKit
import EvieCore
import Foundation
import SwiftUI

// The machinery of one turn: the prompt she is given, the events that come
// back, the proposals she may make, and the several ways a turn can end.

extension OverlayViewModel {
  /// The hidden persona message for the capabilities that are switched on right
  /// now. It is regenerated rather than stored so a capability change can never
  /// leave a stale claim in the conversation.
  var systemPrompt: String {
    Self.systemPrompt(for: capabilities, remembering: memories())
  }

  static func systemPrompt(
    for capabilities: EvieCapabilitySnapshot,
    remembering entries: [EvieMemoryEntry] = []
  ) -> String {
    let persona = EviePersona.evie.systemPrompt(capabilities: capabilities)
    guard let recall = EvieMemoryStore.recallBlock(from: entries) else {
      return persona
    }
    return persona + "\n\n" + recall
  }

  /// The opening of the answer, for the line you scan when the card is closed.
  ///
  /// The title used to be the question, which reads well while you are still
  /// looking at what you typed and badly a minute later: a column headed "oi",
  /// "e aí" and "e isso?" tells you nothing about which answer is which. The
  /// question is still on the card — it is shown when the card is open, right
  /// above the answer — so nothing is lost by titling the card with the thing
  /// that actually distinguishes it.
  /// The buttons every answer carries.
  ///
  /// One place, because three call sites building the same pair by hand is how
  /// one of them ends up without the speaker.
  /// How long a button says it worked before going back to what it says.
  ///
  /// Long enough to be read without looking for it, short enough that the button
  /// is ready again by the time anybody wants it.
  static let confirmationSeconds: Double = 2

  static func answerActions(
    phase: SpeechPhase,
    confirming: String? = nil
  ) -> [ArtifactActionModel] {
    [
      ArtifactActionModel(
        id: "speak",
        title: phase == .speaking ? "Parar" : "Ouvir",
        systemImage: phase == .speaking ? "stop.fill" : "speaker.wave.2.fill",
        role: .secondary,
        isBusy: phase == .preparing
      ),
      ArtifactActionModel(
        id: "copy",
        title: confirming == "copy" ? "Copiado" : "Copiar",
        systemImage: "doc.on.doc",
        role: .secondary,
        isConfirmed: confirming == "copy"
      ),
    ]
  }

  /// Marks one button on one card as having just worked, and undoes it.
  func confirm(_ actionID: String, on card: UUID) {
    confirmationTask?.cancel()
    confirmedAction = (card, actionID)
    refreshSpeakActions()
    onLayoutInvalidated?()

    confirmationTask = Task { @MainActor [weak self] in
      try? await Task.sleep(for: .seconds(Self.confirmationSeconds))
      guard !Task.isCancelled, let self else {
        return
      }
      confirmedAction = nil
      refreshSpeakActions()
      onLayoutInvalidated?()
    }
  }

  /// Keeps the button on every card in step with whether she is actually
  /// talking, so it never offers to start something already running.
  func refreshSpeakActions() {
    for index in artifacts.indices where artifacts[index].kind == .answer {
      artifacts[index].actions = Self.answerActions(
        phase: speechPhase,
        confirming: confirmedAction?.card == artifacts[index].id
          ? confirmedAction?.action : nil
      )
    }
  }

  static func title(fromAnswer answer: String) -> String {
    // Markers stripped rather than rendered: a heading that opens an answer
    // would otherwise put "## " at the front of the title.
    let cleaned =
      answer
      .split(whereSeparator: \.isNewline)
      .first { !$0.trimmingCharacters(in: .whitespaces).isEmpty }
      .map(String.init)?
      .trimmingCharacters(in: CharacterSet(charactersIn: "#*_>-• \t"))
      .replacingOccurrences(of: "**", with: "")
      ?? ""
    guard !cleaned.isEmpty else {
      return "Resposta"
    }
    // Cut at the first sentence when there is one, so the title settles early
    // and stops changing while the rest of the answer streams in.
    if let stop = cleaned.firstIndex(where: { ".!?".contains($0) }),
      cleaned.distance(from: cleaned.startIndex, to: stop) >= 12
    {
      return String(cleaned[cleaned.startIndex...stop])
    }
    return title(for: cleaned)
  }

  static func title(for prompt: String) -> String {
    let firstLine =
      prompt
      .split(whereSeparator: \.isNewline)
      .first
      .map(String.init) ?? prompt
    let collapsed =
      firstLine
      .split(whereSeparator: \.isWhitespace)
      .joined(separator: " ")
    guard collapsed.count > 64 else {
      return collapsed
    }
    return String(collapsed.prefix(61)).trimmingCharacters(in: .whitespaces) + "…"
  }

  func persistConversation() {
    let visibleMessages = conversation.filter { message in
      message.role != .system && message.role != .developer
    }
    let snapshot = EvieConversation(
      id: activeConversationID,
      title: activeConversationTitle,
      createdAt: conversationCreatedAt,
      updatedAt: Date(),
      messages: visibleMessages,
      media: conversationMedia
    )
    let precedingTask = persistenceTask
    let store = conversationStore

    persistenceTask = Task { @MainActor [weak self] in
      await precedingTask?.value
      do {
        _ = try await store.save(snapshot)
      } catch {
        guard let self else { return }
        self.secondaryText = "A resposta chegou, mas o histórico não pôde ser salvo"
        self.onLayoutInvalidated?()
      }
    }
  }

  /// `userMessage` is absent for events forwarded from inside the agent loop,
  /// which never carry the `.completed` that closes a turn — that turn is closed
  /// by `finishLoop` instead.
  func receive(
    _ event: EvieInteractionEvent,
    requestID: UUID,
    userMessage: ChatMessage?
  ) {
    guard activeRequestID == requestID else {
      return
    }

    interactionState.apply(event)

    switch event {
    case .phaseChanged(let phase):
      visualState = visualState(for: phase)
      if phase == .thinking {
        primaryText = "Evie está pensando…"
      }

    case .transcriptUpdated(let text, _):
      primaryText = text

    case .responseTextDelta(let delta):
      streamedResponse += delta
      visualState = .thinking
      primaryText = "Recebendo resposta…"
      updateActiveArtifact(with: streamedResponse)

    case .reasoningDelta:
      // Only the fact that she is thinking reaches the screen. The text is never
      // shown, never spoken, and never part of the answer that is saved.
      visualState = .thinking
      if primaryText != "Evie está pensando…" {
        primaryText = "Evie está pensando…"
      }

    case .status(let message):
      secondaryText = message

    case .artifactCreated(let artifact):
      artifacts.append(artifactCard(from: artifact))
      onLayoutInvalidated?()

    case .usage(let usage):
      contextUsageDescription = Self.contextUsageLabel(
        tokens: usage.promptTokens, capacity: answeringProfile.contextTokens, estimated: false)
      secondaryText = "\(usage.totalTokens) tokens · \(answeringLocation.statusTag)"

    case .completed(let message, _):
      guard let userMessage else {
        return
      }
      let content = message.content.trimmingCharacters(in: .whitespacesAndNewlines)
      if content.isEmpty {
        finishFailure(
          ModelClientError.emptyStream,
          requestID: requestID
        )
        return
      }

      updateActiveArtifact(with: content)
      setProvenance(EvieAnswerProvenance(), on: activeArtifactID)
      onAnswerReady?(EvieRichText(content))
      if conversation.count == 1 {
        activeConversationTitle = Self.title(for: userMessage.content)
      }
      conversation.append(userMessage)
      keepSentPictures(of: userMessage)
      conversation.append(message)
      persistConversation()
      visualState = .completed
      primaryText = "Resposta concluída"
      if let usage = interactionState.usage {
        secondaryText = "\(usage.totalTokens) tokens · \(answeringLocation.statusTag)"
      } else {
        secondaryText = answeringLocation.processedLine
      }
      activeRequestID = nil
      activeArtifactID = nil
      streamedResponse = ""
      pendingPrompt = nil
      requestTask = nil
      isQuickTextEntryPresented = true
      onLayoutInvalidated?()

    case .failed(let failure):
      finishFailure(failure, requestID: requestID)
    }
  }

  /// Events arriving mid-loop.
  ///
  /// A `.completed` here means one step finished, not the turn — feeding it to
  /// `receive` would end the answer while Evie was still looking things up. The
  /// streamed text is dropped for the same reason: a step that ends in a tool
  /// call has nothing to show, and whatever it did say is not the answer.
  func receiveDuringLoop(_ event: EvieInteractionEvent, requestID: UUID) {
    guard activeRequestID == requestID else {
      return
    }
    switch event {
    case .completed:
      streamedResponse = ""
    case .phaseChanged(.usingTool):
      visualState = .thinking
      primaryText = "Evie está procurando…"
    default:
      receive(event, requestID: requestID, userMessage: nil)
    }
  }

  /// Labels a card with where its answer came from.
  func setProvenance(_ provenance: EvieAnswerProvenance, on id: UUID?) {
    guard let id, let index = artifacts.firstIndex(where: { $0.id == id }) else {
      return
    }
    artifacts[index].source = provenance.note
  }

  /// Puts a change on screen with two buttons and no default.
  ///
  /// The card says exactly what will happen to exactly which file, because an
  /// approval is only meaningful if the thing approved was legible. It expires
  /// on its own terms in the writer, so a card left on screen while the world
  /// moved on cannot be honoured later.
  func presentChangeProposal(_ change: EvieFileChange) {
    let rootName = grantedRoots().first { $0.id == change.rootID }?.displayName ?? "a pasta"
    artifacts.append(
      ArtifactCardModel(
        id: change.id,
        kind: .approval,
        title: change.describe(rootName: rootName),
        summary: change.detail(rootName: rootName),
        isExpanded: true,
        actions: [
          ArtifactActionModel(
            id: "change-do:\(change.id.uuidString)",
            title: change.kind == .trash ? "Mandar para o Lixo" : "Fazer",
            systemImage: change.kind == .trash ? "trash" : "checkmark",
            role: .primary
          ),
          ArtifactActionModel(
            id: "change-skip:\(change.id.uuidString)",
            title: "Não",
            systemImage: "xmark",
            role: .secondary
          ),
        ]
      )
    )
    pendingChanges[change.id] = change
    onLayoutInvalidated?()
  }

  /// Carries it out and says what happened, whether a button was pressed or not.
  ///
  /// A change made automatically is reported exactly as loudly as one that was
  /// approved. Convenience that hides what it did is how a person stops knowing
  /// the state of their own disk.
  func performChange(_ change: EvieFileChange, wasAutomatic: Bool) {
    pendingChanges[change.id] = nil
    guard let onChangeApproved else {
      return
    }
    let report = onChangeApproved(change)
    artifacts.append(
      ArtifactCardModel(
        kind: .file,
        title: wasAutomatic ? "Feito, sem te perguntar" : "Feito",
        summary: wasAutomatic
          ? report + "\n\nVocê pediu isso na sua mensagem, e a aprovação automática "
            + "está ligada. Desligue em \(EvieSettingsSection.filesAndFolders.path)."
          : report,
        isExpanded: true
      )
    )
    onLayoutInvalidated?()
  }

  /// Puts a suggested event on screen with two buttons and no default.
  ///
  /// The card is where a wrong date gets caught, so it is written for a person
  /// rather than for a machine: the weekday spelled out, the hours, how long it
  /// lasts and which calendar it lands in. She resolved "hoje 10:30" from a
  /// sentence, and models get dates wrong — this is the step that makes that
  /// survivable instead of silent.
  func presentEventProposal(_ proposal: EvieCalendarEventProposal) {
    artifacts.append(
      ArtifactCardModel(
        id: proposal.id,
        kind: .calendar,
        title: proposal.summary,
        summary: proposal.detail,
        isExpanded: true,
        actions: [
          ArtifactActionModel(
            id: "event-do:\(proposal.id.uuidString)",
            title: "Marcar",
            systemImage: "calendar.badge.plus",
            role: .primary
          ),
          ArtifactActionModel(
            id: "event-skip:\(proposal.id.uuidString)",
            title: "Não",
            systemImage: "xmark",
            role: .secondary
          ),
        ]
      )
    )
    pendingEvents[proposal.id] = proposal
    onLayoutInvalidated?()
  }

  /// Creates it and says where it landed.
  ///
  /// Asynchronous because it is: the Calendar app answers in its own time, the
  /// same seconds a read takes. Nothing is claimed until it has answered — a
  /// "Feito" written before the app confirmed is how somebody ends up with a
  /// meeting they think exists.
  ///
  /// There is no automatic path here, unlike file changes. Auto-approval exists
  /// for undoing things on his own disk; an event is a commitment, and the card
  /// is the whole feature.
  func performEventProposal(_ proposal: EvieCalendarEventProposal) {
    pendingEvents[proposal.id] = nil
    guard let onEventApproved else {
      return
    }
    primaryText = "Marcando…"
    onLayoutInvalidated?()

    Task { @MainActor [weak self] in
      let receipt = await onEventApproved(proposal)
      guard let self else {
        return
      }
      artifacts.append(
        ArtifactCardModel(
          kind: receipt.created ? .calendar : .error,
          title: receipt.created ? "Marcado" : "Não consegui marcar",
          summary: receipt.report,
          isExpanded: true
        )
      )
      primaryText = receipt.created ? "Compromisso criado" : "Nada foi criado"
      onLayoutInvalidated?()
    }
  }

  /// Puts a written message on screen with everything that will leave visible.
  ///
  /// This card carries more weight than any other in the app, because it is the
  /// only one whose button cannot be undone afterwards. So it is built for the
  /// mistake that actually happens — the wrong recipient — rather than for a typo
  /// in the text: every address in full, the account it leaves from, the subject,
  /// and the whole body. Nothing is counted, shortened or summarised, and if it
  /// does not fit the card grows.
  ///
  /// Three buttons rather than two, and the middle one is the argument. "Não"
  /// used to be the only way out of a card, which for a message means throwing
  /// away something he may have wanted with one word changed. "Salvar rascunho"
  /// keeps it, in Mail, where editing and sending are what that app is for — and
  /// it is also the safer half of this whole feature: a draft reaches nobody. It
  /// is not the primary button because he asked to send, and a card whose main
  /// action is "quase" would just move the decision somewhere with less context.
  ///
  /// No timeout, no "lembrar desta escolha", and no automatic path anywhere —
  /// see `performMailProposal`.
  func presentMailProposal(_ proposal: EvieMailProposal) {
    artifacts.append(
      ArtifactCardModel(
        id: proposal.id,
        kind: .email,
        title: proposal.summary,
        summary: proposal.detail,
        isExpanded: true,
        actions: [
          ArtifactActionModel(
            id: "mail-send:\(proposal.id.uuidString)",
            // The verb, not "OK". What this button does is put the message on
            // somebody else's screen, and it says so.
            title: "Enviar",
            systemImage: "paperplane.fill",
            role: .primary
          ),
          ArtifactActionModel(
            id: "mail-draft:\(proposal.id.uuidString)",
            title: "Salvar rascunho",
            systemImage: "tray.and.arrow.down",
            role: .secondary
          ),
          ArtifactActionModel(
            id: "mail-skip:\(proposal.id.uuidString)",
            title: "Não",
            systemImage: "xmark",
            role: .secondary
          ),
        ]
      )
    )
    pendingMail[proposal.id] = proposal
    onLayoutInvalidated?()
  }

  /// Sends it, or files it, and says which one happened.
  ///
  /// Asynchronous because Mail answers in its own time. Nothing is claimed until
  /// it has: "enviado" written before the app confirmed is how somebody spends a
  /// week believing a message went out.
  ///
  /// There is no automatic path here, and there is no switch that could create
  /// one. Auto-approval exists for undoing things on his own disk, where the
  /// worst case is a file in the Trash; a sent message is on somebody else's
  /// screen and no preference is allowed to skip the press.
  func performMailProposal(_ proposal: EvieMailProposal, sending: Bool) {
    pendingMail[proposal.id] = nil
    guard let onMailApproved else {
      return
    }
    primaryText = sending ? "Enviando…" : "Guardando o rascunho…"
    onLayoutInvalidated?()

    Task { @MainActor [weak self] in
      let receipt = await onMailApproved(proposal, sending)
      guard let self else {
        return
      }
      artifacts.append(
        ArtifactCardModel(
          kind: receipt.outcome == .failed ? .error : .email,
          title: Self.mailCardTitle(for: receipt.outcome),
          summary: receipt.report,
          isExpanded: true
        )
      )
      switch receipt.outcome {
      case .sent:
        primaryText = "E-mail enviado"
        secondaryText = "Não dá para voltar atrás"
      case .draft:
        primaryText = "Rascunho guardado"
        secondaryText = "Nada foi enviado"
      case .failed:
        primaryText = "Nada foi enviado"
      }
      onLayoutInvalidated?()
    }
  }

  static func mailCardTitle(for outcome: EvieMailReceipt.Outcome) -> String {
    switch outcome {
    case .sent: "Enviado"
    case .draft: "Guardado em Rascunhos"
    case .failed: "Não consegui enviar"
    }
  }

  /// Puts a suggested skill on screen with its instructions visible.
  ///
  /// The instructions are shown in full rather than summarised, because agreeing
  /// to a skill is agreeing to instructions that will steer future answers. A
  /// summary would be asking someone to sign a page they were not shown.
  func presentSkillProposal(_ skill: EvieSkill) {
    artifacts.append(
      ArtifactCardModel(
        id: UUID(),
        kind: .workflow,
        title: "Guardo isto como uma habilidade?",
        summary: """
          **\(skill.name)** — carrega quando você falar de: \(skill.when)

          \(skill.instructions)
          """,
        isExpanded: true,
        actions: [
          ArtifactActionModel(
            id: "skill-keep",
            title: "Guardar",
            systemImage: "checkmark",
            role: .primary
          ),
          ArtifactActionModel(
            id: "skill-discard",
            title: "Agora não",
            systemImage: "xmark",
            role: .secondary
          ),
        ]
      )
    )
    pendingSkills[artifacts.last?.id ?? UUID()] = skill
    onLayoutInvalidated?()
  }

  /// Puts "guardar isto?" on screen.
  ///
  /// A card rather than a dialog: a modal in the middle of reading an answer is
  /// an interruption, and the decision is not urgent. It sits there until it is
  /// answered, and answering it is one click either way.
  func presentMemoryProposal(_ fact: String) {
    let trimmed = fact.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !trimmed.isEmpty else {
      return
    }
    artifacts.append(
      ArtifactCardModel(
        id: UUID(),
        kind: .memory,
        title: "Posso guardar isto?",
        summary: trimmed,
        isExpanded: true,
        actions: [
          ArtifactActionModel(
            id: "memory-keep",
            title: "Guardar",
            systemImage: "checkmark",
            role: .primary
          ),
          ArtifactActionModel(
            id: "memory-discard",
            title: "Agora não",
            systemImage: "xmark",
            role: .secondary
          ),
        ]
      )
    )
    onLayoutInvalidated?()
  }

  /// Closes a turn that used tools.
  ///
  /// The intermediate turns go into the conversation as well as the answer. They
  /// are what lets a follow-up question — "e o outro contrato?" — work without
  /// starting the search over, and dropping them would leave the model holding an
  /// answer it cannot account for.
  func finishLoop(
    _ outcome: EvieAgentLoop.Outcome,
    requestID: UUID,
    userMessage: ChatMessage,
    autoApproveChanges: Bool = false,
    savesDocumentsDirectly: Bool = false
  ) {
    guard activeRequestID == requestID else {
      return
    }

    let answer = outcome.answer.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !answer.isEmpty else {
      finishFailure(
        outcome.exhausted
          ? EvieAgentLoopFailure.exhausted
          : ModelClientError.emptyStream,
        requestID: requestID
      )
      return
    }

    updateActiveArtifact(with: answer)
    // Set on the card rather than appended to the answer, so it is never spoken
    // and never lands on the clipboard: it is a note about the answer, not part
    // of it.
    setProvenance(outcome.provenance, on: activeArtifactID)
    for proposal in outcome.memoryProposals {
      presentMemoryProposal(proposal)
    }
    for skill in outcome.skillProposals {
      presentSkillProposal(skill)
    }
    for event in outcome.eventProposals {
      presentEventProposal(event)
    }
    // Never routed through the auto-approval branch below, and not by omission:
    // there is no branch to route it through. `autoApproveChanges` is about files.
    for mail in outcome.mailProposals {
      presentMailProposal(mail)
    }
    for change in outcome.changeProposals {
      if autoApproveChanges {
        performChange(change, wasAutomatic: true)
      } else {
        presentChangeProposal(change)
      }
    }
    // Documents, folders to permit and files opened. Never routed through
    // `autoApproveChanges`: a document has its own, narrower policy.
    presentFileOutcome(
      outcome, question: userMessage.content, savesDirectly: savesDocumentsDirectly)
    onAnswerReady?(EvieRichText(answer))
    if conversation.count == 1 {
      activeConversationTitle = Self.title(for: userMessage.content)
    }
    conversation.append(userMessage)
    keepSentPictures(of: userMessage)
    conversation.append(contentsOf: outcome.appended)
    persistConversation()

    visualState = .completed
    primaryText = "Resposta concluída"
    secondaryText =
      outcome.toolCallCount == 1
      ? "Olhei em 1 lugar · \(answeringLocation.statusTag)"
      : "Olhei em \(outcome.toolCallCount) lugares · \(answeringLocation.statusTag)"
    activeRequestID = nil
    activeArtifactID = nil
    streamedResponse = ""
    pendingPrompt = nil
    requestTask = nil
    isQuickTextEntryPresented = true
    onLayoutInvalidated?()
  }

  func finishCancellation(requestID: UUID) {
    guard activeRequestID == requestID else {
      return
    }
    activeRequestID = nil
    activeArtifactID = nil
    requestTask = nil
    streamedResponse = ""
    quickText = pendingPrompt ?? quickText
    pendingPrompt = nil
    visualState = .ready
    primaryText = "Consulta cancelada"
    secondaryText = "Nenhuma ação foi executada"
    isQuickTextEntryPresented = true
    onLayoutInvalidated?()
  }

  func finishFailure(_ error: any Error, requestID: UUID) {
    let failure = EvieFailure(
      kind: .backend,
      message: error.localizedDescription,
      recoverySuggestion: answeringLocation.failureRecovery
    )
    finishFailure(failure, requestID: requestID)
  }

  func finishFailure(
    _ failure: EvieFailure,
    requestID: UUID,
    title: String = "Não consegui responder agora",
    actions: [ArtifactActionModel] = []
  ) {
    guard activeRequestID == requestID else {
      return
    }

    interactionState.apply(.failed(failure))
    visualState = failure.kind == .cancelled ? .ready : .error
    primaryText = failure.kind == .cancelled ? "Consulta cancelada" : "Evie indisponível"
    secondaryText = failure.recoverySuggestion

    if let artifactID = activeArtifactID,
      let index = artifacts.firstIndex(where: { $0.id == artifactID })
    {
      artifacts[index] = ArtifactCardModel(
        id: artifactID,
        kind: .error,
        title: title,
        summary: failure.message,
        detail: failure.recoverySuggestion,
        isExpanded: true,
        actions: actions
      )
    } else {
      artifacts.append(
        ArtifactCardModel(
          kind: .error,
          title: title,
          summary: failure.message,
          detail: failure.recoverySuggestion,
          isExpanded: true,
          actions: actions
        )
      )
    }

    activeRequestID = nil
    activeArtifactID = nil
    requestTask = nil
    streamedResponse = ""
    quickText = pendingPrompt ?? quickText
    pendingPrompt = nil
    isQuickTextEntryPresented = true
    onLayoutInvalidated?()
  }

  func updateActiveArtifact(with content: String) {
    guard let artifactID = activeArtifactID,
      let index = artifacts.firstIndex(where: { $0.id == artifactID })
    else {
      return
    }
    artifacts[index].summary = content
    let written = content.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !written.isEmpty else {
      return
    }
    // The dots stop the moment there is something to read.
    artifacts[index].isLoading = false
    artifacts[index].title = Self.title(fromAnswer: written)
  }

  func artifactCard(from artifact: EvieArtifact) -> ArtifactCardModel {
    ArtifactCardModel(
      id: artifact.id,
      kind: artifactKind(from: artifact.kind),
      title: artifact.title,
      summary: artifact.content,
      source: artifact.sourceURL?.absoluteString,
      isExpanded: true
    )
  }

  func artifactKind(from kind: EvieArtifact.Kind) -> ArtifactKind {
    switch kind {
    case .text, .markdown, .link:
      .answer
    case .file:
      .file
    case .image:
      .image
    case .email:
      .email
    case .calendarEvent:
      .calendar
    case .workflow:
      .workflow
    case .approval:
      .approval
    case .diagnostic:
      .error
    case .custom:
      .answer
    }
  }

  func visualState(for phase: EvieInteractionPhase) -> EvieVisualState {
    switch phase {
    case .sleeping, .idle, .cancelled:
      .ready
    case .listening:
      .listening
    case .transcribing:
      .transcribing
    case .thinking:
      .thinking
    case .usingTool:
      .usingTool
    case .awaitingApproval:
      .awaitingApproval
    case .speaking:
      .speaking
    case .completed:
      .completed
    case .failed:
      .error
    }
  }

  /// The moment a question was asked, in words she can read.
  ///
  /// Attached to the question rather than kept in the system prompt. It is the
  /// answer to "que horas são" without a tool call, and to "há quanto tempo"
  /// across a long conversation, since each turn carries the time it was asked.
  static func timestamp(_ now: Date = Date()) -> String {
    let formatter = DateFormatter()
    formatter.locale = Locale(identifier: "pt_BR")
    formatter.dateFormat = "EEEE, d 'de' MMMM 'de' yyyy, HH:mm"
    return formatter.string(from: now)
  }

  static func contextUsageLabel(tokens: Int, capacity: Int, estimated: Bool) -> String {
    let percent = Double(tokens) / Double(max(1, capacity)) * 100
    let count = tokens.formatted(.number.locale(Locale(identifier: "pt_BR")))
    let ratio = percent.formatted(
      .number.precision(.fractionLength(1)).locale(Locale(identifier: "pt_BR")))
    return
      "\(estimated ? "~" : "")\(count) tokens · \(ratio)% (\(estimated ? "estimativa" : "servidor"))"
  }

  func showContextCompactionProgress(completed: Int, total: Int, request: UUID?, conversation: UUID)
  {
    guard activeRequestID == request, activeConversationID == conversation else { return }
    isCompactingConversation = true
    secondaryText = "Organizando o contexto da conversa… \(completed)/\(total)"
    onLayoutInvalidated?()
  }

  /// Everything this turn adds after the history, built for `plan`'s brain:
  /// the persona says where that brain runs and names only tools it has, the
  /// history is trimmed to its budget, and pictures go only if it takes them.
  func conversationPrefix(
    adding userMessage: ChatMessage,
    evidence: ChatMessage? = nil,
    pictures: EvieTurnPictures = EvieTurnPictures(),
    plan: EvieTurnPlan, client: any AgentClient
  ) async throws -> [ChatMessage] {
    // Rebuilt every turn, which costs a string: the date in it may have turned
    // over, and the brain may differ from the last turn's. Within a
    // conversation both stay put, so the first bytes — and the server's cached
    // prefix — do too. The newest turn with a picture is replayed as it was
    // sent, so the cache reaches past its picture.
    var history = sentPictureTurn?.replay(conversation) ?? conversation
    let persona = ChatMessage(
      role: .system,
      content: Self.systemPrompt(
        for: plan.capabilities(from: capabilities),
        remembering: memories()
      )
    )
    if history.first?.role == .system {
      history[0] = persona
    } else {
      history.insert(persona, at: 0)
    }
    // Skills are instructions, so they stay a system message here — and they go
    // just before the question, after every earlier turn. The client sends any
    // system message after the first as a `<system-context>` block on the next
    // user message, which every server here accepts, so the guidance lands
    // after everything the server has cached: the prompt and the history keep
    // their bytes whether a skill matched this turn or not. At the front, as it
    // used to be, it changed the prefix from the second message on.
    let guidance = EvieSkillLibrary.guidance(
      for: EvieSkillLibrary.matching(userMessage.content, in: installedSkills())
    ).map { ChatMessage(role: .system, content: $0) }

    // The exact time rides with the question rather than sitting in the system
    // prompt. Up there it would change every minute and break the cached prefix
    // on every turn; down here it lands after everything cached, where the tokens
    // were going to be new anyway. Earlier turns keep the time they were asked
    // at, which is both true and what keeps the prefix stable.
    let asked = ChatMessage(
      role: .user,
      content: plan.question(userMessage.content, askedAt: Self.timestamp())
    )

    // Evidence goes immediately before the question so the model reads the
    // document, then what is being asked about it. Pictures ride on the
    // question itself, after a note that their text is data; a brain that
    // cannot see gets their text, fenced, just before it.
    let tail =
      [guidance, evidence].compactMap { $0 } + plan.pictureTail(asking: asked, with: pictures)
    let pictured = EvieTurnPlan.keepingNewestPictures(
      history + tail, sees: plan.profile.capabilities.vision)
    let request = activeRequestID
    let conversationID = activeConversationID
    await contextResetTask?.value
    try Task.checkCancellation()
    defer {
      if activeRequestID == request { isCompactingConversation = false }
    }
    let prepared = try await contextCompaction.prepare(
      history: Array(pictured.prefix(history.count)), tail: Array(pictured.suffix(tail.count)),
      budget: plan.characterBudget, client: client,
      targetID:
        "\(conversationID)|\(plan.profile.id)|\(plan.profile.model)|\(plan.profile.contextTokens)|\(plan.profile.endpoint.absoluteString)",
      onProgress: { [weak self] completed, total in
        await self?.showContextCompactionProgress(
          completed: completed, total: total,
          request: request, conversation: conversationID)
      })
    try Task.checkCancellation()
    guard activeRequestID == request, activeConversationID == conversationID else {
      throw CancellationError()
    }
    contextUsageDescription = Self.contextUsageLabel(
      tokens: prepared.estimatedInputTokens, capacity: plan.profile.contextTokens, estimated: true)
    let messages = plan.prefix(prepared.messages, then: [])
    if !pictures.isEmpty, plan.profile.capabilities.vision {
      sendingPictureTurn = EvieSentPictureTurn(
        questionID: userMessage.id,
        sent: Array(messages.suffix(tail.count))
      )
    }
    return messages
  }

  /// Once a turn with a picture has its answer, what it sent becomes the turn
  /// replayed from now on. A turn that failed or was cancelled leaves the
  /// earlier one in place.
  func keepSentPictures(of question: ChatMessage) {
    guard let sending = sendingPictureTurn, sending.questionID == question.id else {
      return
    }
    sentPictureTurn = sending
    sendingPictureTurn = nil
  }

  /// Consumes the pending attachments into one message, bounded so a long
  /// document cannot crowd out the question itself.
  /// Whether describing this file makes sense. A PDF is read, not looked at.
  static func isImage(_ url: URL) -> Bool {
    ["png", "jpg", "jpeg", "heic", "heif", "gif", "tiff", "bmp", "webp"]
      .contains(url.pathExtension.lowercased())
  }

  /// Consumes the pending attachments: documents become one evidence message,
  /// bounded so a long PDF cannot crowd out the question itself; pictures
  /// become `EvieTurnPictures`, sent as images to a brain that sees and as
  /// their text and description to one that does not.
  func takeAttachments(for messageID: UUID? = nil) -> (
    evidence: ChatMessage?, pictures: EvieTurnPictures
  ) {
    // Only what finished preparing. A slot still being read, or one that failed,
    // is not evidence — and the send path waits for the first kind before
    // getting here, so arriving with one is a genuine failure rather than a race.
    let attachments = attachmentSlots.compactMap(\.prepared)
    guard !attachments.isEmpty else {
      attachmentSlots = []
      return (nil, EvieTurnPictures())
    }
    // Kept before the file is forgotten. What reaches the model is the text
    // pulled out of a picture; a conversation that says "a imagem mostra uma
    // cordilheira" with no way to see the picture is an answer with its question
    // missing.
    for slot in attachmentSlots where slot.prepared != nil {
      if let stored = mediaStore.store(
        slot.url,
        originalName: slot.name,
        messageID: messageID
      ) {
        conversationMedia.append(stored)
      }
    }
    attachmentSlots = []

    let pictured = attachments.filter { $0.imagePart != nil }
    let documents = attachments.filter { $0.imagePart == nil }
    let pictures = EvieTurnPictures(
      images: pictured.compactMap(\.imagePart),
      textFallback: Self.bounded(Self.evidence(of: pictured))
    )
    let evidence = Self.bounded(Self.evidence(of: documents)).map {
      ChatMessage(role: .user, content: $0)
    }
    return (evidence, pictures)
  }

  /// What was seen first, because it says what kind of thing this is before
  /// the recognised text arrives.
  static func evidence(of attachments: [EvieDocumentAttachment]) -> String? {
    EvieTurnPictures.fallbackEvidence(
      seen: attachments.compactMap { attachment in
        attachment.visualDescription.map { (name: attachment.name, description: $0) }
      },
      read: attachments.flatMap(\.pages)
    )
  }

  /// Cut at `attachmentCharacterLimit`, with a visible marker.
  static func bounded(_ evidence: String?) -> String? {
    guard var evidence, evidence.count > attachmentCharacterLimit else {
      return evidence
    }
    let cut = evidence.index(evidence.startIndex, offsetBy: attachmentCharacterLimit)
    evidence = String(evidence[..<cut])
    evidence += "\n<<<CORTADO AQUI — o documento é maior do que cabe nesta conversa>>>"
    return evidence
  }
}

// MARK: - The brain a turn runs on

/// What a typed or spoken question carries into its turn, fixed when it is
/// sent, before the brain is known.
struct PreparedTurn {
  let requestID: UUID
  let userMessage: ChatMessage
  let evidence: ChatMessage?
  /// Pasted or attached pictures.
  let pictures: EvieTurnPictures
  /// The capture of the screen this question is about, taken before the turn
  /// resolves its brain.
  var screen: CapturedScreen?
  let carriesAttachment: Bool
  let spoken: Bool
  let roots: [EvieFileRoot]
  let web: (any EvieWebSearching)?
  let apps: (any EvieMailCalendarReading)?
  let offersChanges: Bool
  let autoApprovesChanges: Bool
  /// `EvieFileIntent`: the question is about his files, so it goes to the
  /// tools even with no folder granted.
  let asksAboutFiles: Bool
  /// His own message asked to save and the switch is on (ADR 0019); a
  /// picture in the request still cancels it.
  let savesDocumentsDirectly: Bool
}

extension OverlayViewModel {
  /// Resolves the conversation's brain, runs `attempt` on it — and once more
  /// on the next brain if it failed before the model said anything — and ends
  /// the turn when `attempt` throws.
  func runTurn(
    conversation: UUID,
    requestID: UUID,
    attempt: (ResolvedBrain) async throws -> Void
  ) async {
    let brain = await brainResolver.resolve(conversation: conversation)
    // Whatever happens next, the Mac brain's idle clock counts from the end
    // of this turn.
    defer { brainResolver.turnEnded(conversation: conversation) }
    // Cancelled while the probe or the wake question was pending.
    guard activeRequestID == requestID, !Task.isCancelled else {
      return
    }
    adoptAnsweringBrain(brain)
    showBrainNotice(brain.notice)
    do {
      try await EvieBrainTurn.run(
        conversation: conversation,
        on: brain,
        resolver: brainResolver,
        onSwitch: { next in
          adoptAnsweringBrain(next)
          showBrainNotice(next.notice)
        },
        attempt: attempt
      )
      brainTurnEnded(answered: true)
    } catch is CancellationError {
      finishCancellation(requestID: requestID)
    } catch {
      finishFailure(error, requestID: requestID)
      brainTurnEnded(answered: false)
    }
  }

  /// An ordinary question on `brain`, built from scratch for it.
  func answer(_ turn: PreparedTurn, on brain: ResolvedBrain) async throws {
    let plan = EvieTurnPlan(brain)
    let looking = turn.screen != nil
    let pictures = await pictures(for: turn, on: plan)
    try Task.checkCancellation()
    let requestMessages = try await conversationPrefix(
      adding: turn.userMessage,
      evidence: turn.evidence,
      pictures: pictures,
      plan: plan, client: brain.client
    )
    let requestID = turn.requestID
    if looking, plan.profile.capabilities.vision {
      // Most of the wait is the picture being read before the first word.
      secondaryText = EvieScreenLookCopy.analysing(on: plan.profile.location)
      onLayoutInvalidated?()
    }

    // A capture replayed from an earlier turn counts, and so does a picture's
    // text on a brain that cannot see it — the messages `pictureTail` built
    // carry `derivedFromPicture`: none of it rides with tools or auto-approves.
    let carriesPicture = !pictures.isEmpty || EvieTurnPlan.carriesPicture(requestMessages)

    switch plan.route(
      hasRoots: !turn.roots.isEmpty,
      searchesTheWeb: turn.web != nil,
      readsMailAndCalendar: turn.apps != nil,
      looksAtScreen: looking,
      carriesPicture: carriesPicture,
      asksAboutFiles: turn.asksAboutFiles
    ) {
    case .directStream:
      // Pinned at submit time, like the rest of the turn: a spoken question
      // gets a spoken-length answer.
      for try await event in brain.client.stream(
        messages: requestMessages,
        tools: [],
        options: plan.options(spoken: turn.spoken, looking: looking)
      ) {
        try Task.checkCancellation()
        receive(event, requestID: requestID, userMessage: turn.userMessage)
      }

    case .agentLoop(let offersTools):
      let savesDirectly = EvieTurnPlan.savesDocumentsDirectly(
        turn.savesDocumentsDirectly, carriesPicture: carriesPicture)
      // Captured weakly: the loop's callback is `@Sendable` and runs off this
      // actor.
      let outcome = try await EvieAgentLoop(
        toolbox: EvieFileToolbox(home: Self.homeURL),
        web: turn.web,
        mailAndCalendar: offersTools ? turn.apps : nil,
        vault: retrieveFromVault,
        offersChanges: turn.offersChanges,
        offersTools: offersTools,
        readiness: plan.readiness,
        modelFamily: plan.profile.family,
        offersDocuments: true,
        savesDocumentsDirectly: savesDirectly,
        opener: EvieWorkspaceOpener()
      ).run(
        messages: requestMessages,
        roots: turn.roots,
        client: brain.client,
        carriesAttachment: turn.carriesAttachment
      ) { [weak self] event in
        await self?.receiveDuringLoop(event, requestID: requestID)
      }
      try Task.checkCancellation()
      finishLoop(
        outcome,
        requestID: requestID,
        userMessage: turn.userMessage,
        autoApproveChanges: EvieTurnPlan.autoApprovesChanges(
          turn.autoApprovesChanges, carriesPicture: carriesPicture),
        savesDocumentsDirectly: savesDirectly
      )
    }
  }

  /// "Acordando o cérebro do Mac…" on the status line while the Mac brain
  /// starts, cleared when it is up unless something else was said meanwhile.
  func showLocalBrainWaking(_ waking: Bool) {
    showBrainWaking(waking)
    if waking {
      secondaryText = EvieBrainResolver.wakingStatus
    } else if secondaryText == EvieBrainResolver.wakingStatus {
      secondaryText = nil
    }
    onLayoutInvalidated?()
  }

  /// Says that the turn runs somewhere other than the preferred brain, and why.
  func showBrainNotice(_ notice: String?) {
    guard let notice else {
      return
    }
    secondaryText = notice
    onLayoutInvalidated?()
  }

  /// Puts the wake question on screen and waits for the answer. Cancelling the
  /// turn, or closing the card, is a no.
  func askToWake(_ question: EvieBrainWakeQuestion) async -> Bool {
    // One turn runs at a time, so an earlier question still waiting has lost
    // its turn.
    if let earlier = pendingWake {
      settleWake(earlier.card, accepted: false)
    }
    let card = UUID()
    artifacts.append(
      ArtifactCardModel(
        id: card,
        kind: .approval,
        title: question.text,
        summary: "Enquanto estiver acordado, ele ocupa essa memória deste Mac. "
          + "A conversa continua nele até você começar outra.",
        isExpanded: true,
        actions: [
          ArtifactActionModel(
            id: "brain-wake:\(card.uuidString)",
            title: "Acordar o Mac",
            systemImage: "power",
            role: .primary
          ),
          ArtifactActionModel(
            id: "brain-stay:\(card.uuidString)",
            title: "Agora não",
            systemImage: "xmark",
            role: .secondary
          ),
        ]
      )
    )
    onLayoutInvalidated?()
    return await withTaskCancellationHandler {
      await withCheckedContinuation { continuation in
        pendingWake = (card, continuation)
      }
    } onCancel: {
      Task { @MainActor [weak self] in
        self?.settleWake(card, accepted: false)
      }
    }
  }

  /// Answers the wake question on `card`, if it is the one waiting.
  func settleWake(_ card: UUID, accepted: Bool) {
    guard let pending = pendingWake, pending.card == card else {
      return
    }
    pendingWake = nil
    artifacts.removeAll { $0.id == card }
    onLayoutInvalidated?()
    pending.answer.resume(returning: accepted)
  }
}
