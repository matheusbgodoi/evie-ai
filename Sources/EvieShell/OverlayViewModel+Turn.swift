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

    case .status(let message):
      secondaryText = message

    case .artifactCreated(let artifact):
      artifacts.append(artifactCard(from: artifact))
      onLayoutInvalidated?()

    case .usage(let usage):
      secondaryText = "\(usage.totalTokens) tokens · somente local"

    case .completed(let message, _):
      guard let userMessage else {
        return
      }
      let content = message.content.trimmingCharacters(in: .whitespacesAndNewlines)
      if content.isEmpty {
        finishFailure(
          TurboFieldfareClientError.emptyStream,
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
      conversation.append(message)
      persistConversation()
      visualState = .completed
      primaryText = "Resposta concluída"
      if let usage = interactionState.usage {
        secondaryText = "\(usage.totalTokens) tokens · somente local"
      } else {
        secondaryText = "Processado localmente"
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
            + "está ligada. Desligue em Configurações › O que ela sabe."
          : report,
        isExpanded: true
      )
    )
    onLayoutInvalidated?()
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
    autoApproveChanges: Bool = false
  ) {
    guard activeRequestID == requestID else {
      return
    }

    let answer = outcome.answer.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !answer.isEmpty else {
      finishFailure(
        outcome.exhausted
          ? EvieAgentLoopFailure.exhausted
          : TurboFieldfareClientError.emptyStream,
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
    for change in outcome.changeProposals {
      if autoApproveChanges {
        performChange(change, wasAutomatic: true)
      } else {
        presentChangeProposal(change)
      }
    }
    onAnswerReady?(EvieRichText(answer))
    if conversation.count == 1 {
      activeConversationTitle = Self.title(for: userMessage.content)
    }
    conversation.append(userMessage)
    conversation.append(contentsOf: outcome.appended)
    persistConversation()

    visualState = .completed
    primaryText = "Resposta concluída"
    secondaryText =
      outcome.toolCallCount == 1
      ? "Olhei em 1 lugar · somente local"
      : "Olhei em \(outcome.toolCallCount) lugares · somente local"
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
      recoverySuggestion:
        "O modelo local não respondeu. Abra Configurações › Diagnóstico para conferir o motor."
    )
    finishFailure(failure, requestID: requestID)
  }

  func finishFailure(_ failure: EvieFailure, requestID: UUID) {
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
        title: "Não consegui responder agora",
        summary: failure.message,
        detail: failure.recoverySuggestion,
        isExpanded: true
      )
    } else {
      artifacts.append(
        ArtifactCardModel(
          kind: .error,
          title: "Não consegui responder agora",
          summary: failure.message,
          detail: failure.recoverySuggestion,
            isExpanded: true
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

  func conversationPrefix(
    adding userMessage: ChatMessage,
    evidence: ChatMessage? = nil
  ) -> [ChatMessage] {
    // The day may have turned over since this conversation started. Rebuilding
    // costs a string comparison — `refreshSystemPrompt` returns early when the
    // text is unchanged — and the prompt now carries only the date, so it is
    // unchanged for a whole day and the cached prefix survives.
    refreshSystemPrompt()
    var prefix = conversation
    let characterBudget = max(
      8_000,
      (agentClient.configuration.contextWindowTokens
        - agentClient.configuration.maxCompletionTokens) * 2
    )
    let tailLength = userMessage.content.count + (evidence?.content.count ?? 0)

    while prefix.count > 1,
      prefix.reduce(0, { $0 + $1.content.count }) + tailLength > characterBudget
    {
      removeOldestTurn(from: &prefix)
    }
    // Skills are instructions, so they go with the instructions — at the front,
    // before any turn of the conversation. Putting them next to the question
    // instead would place guidance after the conversation started, which this
    // server refuses, and would read as something the user said.
    if let guidance = EvieSkillLibrary.guidance(
      for: EvieSkillLibrary.matching(userMessage.content, in: installedSkills())
    ) {
      let position = prefix.first?.role == .system ? 1 : 0
      prefix.insert(ChatMessage(role: .system, content: guidance), at: position)
    }

    // The exact time rides with the question rather than sitting in the system
    // prompt. Up there it would change every minute and break the cached prefix
    // on every turn; down here it lands after everything cached, where the tokens
    // were going to be new anyway. Earlier turns keep the time they were asked
    // at, which is both true and what keeps the prefix stable.
    let asked = ChatMessage(
      role: .user,
      content: "[\(Self.timestamp())] \(userMessage.content)"
    )

    // Evidence goes immediately before the question so the model reads the
    // document, then what is being asked about it.
    return prefix + [evidence, asked].compactMap { $0 }
  }

  /// Consumes the pending attachments into one message, bounded so a long
  /// document cannot crowd out the question itself.
  /// Whether describing this file makes sense. A PDF is read, not looked at.
  static func isImage(_ url: URL) -> Bool {
    ["png", "jpg", "jpeg", "heic", "heif", "gif", "tiff", "bmp", "webp"]
      .contains(url.pathExtension.lowercased())
  }

  func takeAttachmentEvidence(for messageID: UUID? = nil) -> ChatMessage? {
    // Only what finished preparing. A slot still being read, or one that failed,
    // is not evidence — and the send path waits for the first kind before
    // getting here, so arriving with one is a genuine failure rather than a race.
    let attachments = attachmentSlots.compactMap(\.prepared)
    guard !attachments.isEmpty else {
      attachmentSlots = []
      return nil
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
    let pages = attachments.flatMap(\.pages)
    // What was seen goes first, because it says what kind of thing this is
    // before the recognised text arrives. A wall of OCR with no frame around it
    // is how a chart becomes a list of stray numbers.
    let seen = attachments.compactMap { attachment -> String? in
      guard let description = attachment.visualDescription else {
        return nil
      }
      return "\(attachment.name): \(description)"
    }
    attachmentSlots = []

    var evidence = ""
    if !seen.isEmpty {
      evidence += """
        <<<O QUE A EVIE VIU NA IMAGEM — descrição, não texto extraído>>>
        \(seen.joined(separator: "\n"))
        <<<FIM DA DESCRIÇÃO>>>


        """
    }
    evidence += pages.promptEvidence
    if evidence.count > Self.attachmentCharacterLimit {
      let cut = evidence.index(evidence.startIndex, offsetBy: Self.attachmentCharacterLimit)
      evidence = String(evidence[..<cut])
      evidence +=
        "\n<<<CORTADO AQUI — o documento é maior do que cabe nesta conversa>>>"
    }
    return ChatMessage(role: .user, content: evidence)
  }

  func removeOldestTurn(from messages: inout [ChatMessage]) {
    guard messages.count > 1 else {
      return
    }

    messages.remove(at: 1)
    if messages.count > 1, messages[1].role == .assistant {
      messages.remove(at: 1)
    }
  }
}
