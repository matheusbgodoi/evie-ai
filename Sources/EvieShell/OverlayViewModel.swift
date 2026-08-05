import AppKit
import EvieCore
import Foundation

@MainActor
final class OverlayViewModel: ObservableObject {
  @Published var visualState: EvieVisualState = .ready
  @Published var primaryText = "Evie está pronta"
  @Published var secondaryText: String? = "⌥Espaço para conversar"
  @Published var waveformSamples: [CGFloat] = []
  @Published var artifacts: [ArtifactCardModel] = []
  @Published var isQuickTextEntryPresented = false
  @Published var quickText = ""
  @Published private(set) var activeConversationID = UUID()
  @Published private(set) var activeConversationTitle = "Nova conversa"

  var onLayoutInvalidated: (@MainActor () -> Void)?
  var onDismissRequested: (@MainActor () -> Void)?
  /// Set once a real capture path exists. While it is `nil` the mark says so
  /// instead of pretending the microphone opened.
  var onVoiceActivationRequested: (@MainActor () -> Void)?

  private var agentClient: any AgentClient
  private var capabilities: EvieCapabilitySnapshot
  private let conversationStore: EvieConversationStore
  private var conversation: [ChatMessage]
  private var conversationCreatedAt = Date()
  private var interactionState = EvieInteractionState()
  private var requestTask: Task<Void, Never>?
  private var persistenceTask: Task<Void, Never>?
  private var conversationGeneration: UInt64 = 0
  private var activeRequestID: UUID?
  private var activeArtifactID: UUID?
  private var streamedResponse = ""
  private var pendingPrompt: String?

  init(
    agentClient: any AgentClient,
    conversationStore: EvieConversationStore = EvieConversationStore(),
    capabilities: EvieCapabilitySnapshot = .textOnly
  ) {
    self.agentClient = agentClient
    self.conversationStore = conversationStore
    self.capabilities = capabilities
    conversation = [
      ChatMessage(role: .system, content: Self.systemPrompt(for: capabilities))
    ]
  }

  /// Rebuilds the hidden persona message when a capability is switched on or
  /// off, so Evie never keeps claiming — or denying — something that changed
  /// mid-session. Only the system message is replaced; the visible turns stay.
  func applyCapabilities(_ capabilities: EvieCapabilitySnapshot) {
    guard capabilities != self.capabilities else {
      return
    }
    self.capabilities = capabilities
    let message = ChatMessage(role: .system, content: systemPrompt)
    if conversation.first?.role == .system {
      conversation[0] = message
    } else {
      conversation.insert(message, at: 0)
    }
  }

  var hasActiveRequest: Bool {
    activeRequestID != nil
  }

  /// What the interface calls the thing that answers.
  ///
  /// Evie never shows the model name, the server product, or a host and port:
  /// they are implementation detail, and a loopback address on screen only
  /// invites confusion. The raw endpoint stays available for the diagnostics
  /// section of Settings.
  var engineDescription: String {
    "Modelo local"
  }

  var diagnosticEndpointDescription: String {
    let configuration = agentClient.configuration
    let defaultPort = configuration.endpoint.scheme?.lowercased() == "https" ? 443 : 80
    return
      "\(configuration.endpoint.host ?? "127.0.0.1"):\(configuration.endpoint.port ?? defaultPort)"
  }

  var configuration: EvieConfiguration {
    agentClient.configuration
  }

  func applyConfiguration(_ configuration: EvieConfiguration) {
    agentClient = TurboFieldfareClient(configuration: configuration)
    secondaryText = "Novos ajustes serão usados na próxima pergunta"
    onLayoutInvalidated?()
  }

  func startNewConversation() {
    if hasActiveRequest {
      cancelCurrentInteraction()
    }

    conversationGeneration &+= 1
    activeConversationID = UUID()
    activeConversationTitle = "Nova conversa"
    conversationCreatedAt = Date()
    conversation = [ChatMessage(role: .system, content: systemPrompt)]
    artifacts = []
    visualState = .ready
    primaryText = "Nova conversa"
    secondaryText = "O histórico anterior continua salvo somente neste Mac"
    quickText = ""
    pendingPrompt = nil
    isQuickTextEntryPresented = true
    onLayoutInvalidated?()
  }

  @discardableResult
  func openConversation(id: UUID) async -> Bool {
    if hasActiveRequest {
      cancelCurrentInteraction()
    }
    conversationGeneration &+= 1
    let requestedGeneration = conversationGeneration

    do {
      let stored = try await conversationStore.load(id: id)
      guard conversationGeneration == requestedGeneration else {
        return false
      }
      activeConversationID = stored.id
      activeConversationTitle = stored.title
      conversationCreatedAt = stored.createdAt
      conversation =
        [ChatMessage(role: .system, content: systemPrompt)]
        + stored.messages
      artifacts = stored.messages
        .filter { $0.role == .assistant }
        .suffix(8)
        .map { message in
          ArtifactCardModel(
            id: message.id,
            kind: .answer,
            title: stored.title,
            summary: message.content,
            source: "Histórico local",
            isExpanded: false,
            actions: [
              ArtifactActionModel(
                id: "copy",
                title: "Copiar",
                systemImage: "doc.on.doc",
                role: .secondary
              )
            ]
          )
        }
      visualState = .ready
      primaryText = stored.title
      secondaryText = "Conversa restaurada deste Mac"
      quickText = ""
      pendingPrompt = nil
      isQuickTextEntryPresented = true
      onLayoutInvalidated?()
      return true
    } catch {
      guard conversationGeneration == requestedGeneration else {
        return false
      }
      presentRuntimeError(title: "Não foi possível abrir a conversa", error: error)
      return false
    }
  }

  func conversationWasDeleted(id: UUID) {
    guard activeConversationID == id else {
      return
    }
    startNewConversation()
  }

  func waitForHistoryPersistence() async {
    await persistenceTask?.value
  }

  func prepareForConversationDeletion(id: UUID) async {
    if activeConversationID == id, hasActiveRequest {
      cancelCurrentInteraction()
    }
    await persistenceTask?.value
    if activeConversationID == id {
      startNewConversation()
    }
  }

  func presentReadyState() {
    guard !hasActiveRequest else {
      return
    }

    isQuickTextEntryPresented = false
    visualState = .ready
    primaryText = "Evie está pronta"
    secondaryText = "Voz ainda não está ativa · ⌥Espaço para conversar"
    waveformSamples = []
    onLayoutInvalidated?()
  }

  @discardableResult
  func beginQuickText() -> Bool {
    guard !hasActiveRequest else {
      primaryText = "Aguarde ou cancele a consulta atual"
      return false
    }

    isQuickTextEntryPresented = true
    visualState = .ready
    primaryText = "Digite um comando"
    secondaryText = "Tudo acontece neste Mac"
    onLayoutInvalidated?()
    return true
  }

  /// Tapping the mark, pressing push-to-talk, or saying the wake phrase all end
  /// up here so the three routes cannot drift apart.
  func requestVoiceActivation() {
    guard let onVoiceActivationRequested else {
      secondaryText = "A voz ainda não está ligada neste build."
      onLayoutInvalidated?()
      return
    }
    onVoiceActivationRequested()
  }

  func dismissQuickText() {
    guard !hasActiveRequest else {
      return
    }

    isQuickTextEntryPresented = false
    presentReadyState()
    onDismissRequested?()
  }

  func submitQuickText() {
    let prompt = quickText.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !prompt.isEmpty, !hasActiveRequest else {
      NSSound.beep()
      return
    }

    let requestID = UUID()
    let artifactID = UUID()
    let userMessage = ChatMessage(role: .user, content: prompt)
    let requestMessages = conversationPrefix(adding: userMessage)
    let client = agentClient

    activeRequestID = requestID
    activeArtifactID = artifactID
    streamedResponse = ""
    interactionState = EvieInteractionState(phase: .thinking)
    pendingPrompt = prompt
    quickText = ""
    isQuickTextEntryPresented = false
    visualState = .thinking
    primaryText = "Pensando…"
    secondaryText = nil
    waveformSamples = []
    artifacts.append(
      ArtifactCardModel(
        id: artifactID,
        kind: .answer,
        title: "Resposta da Evie",
        summary: "Aguardando o primeiro trecho…",
        source: engineDescription,
        isExpanded: true,
        actions: [
          ArtifactActionModel(
            id: "copy",
            title: "Copiar",
            systemImage: "doc.on.doc",
            role: .secondary
          )
        ]
      )
    )
    onLayoutInvalidated?()

    requestTask = Task { @MainActor [weak self] in
      do {
        for try await event in client.stream(messages: requestMessages) {
          try Task.checkCancellation()
          self?.receive(
            event,
            requestID: requestID,
            userMessage: userMessage
          )
        }
      } catch is CancellationError {
        self?.finishCancellation(requestID: requestID)
      } catch {
        self?.finishFailure(error, requestID: requestID)
      }
    }
  }

  func cancelCurrentInteraction() {
    guard activeRequestID != nil else {
      return
    }

    activeRequestID = nil
    requestTask?.cancel()
    requestTask = nil
    interactionState.apply(
      .failed(
        EvieFailure(
          kind: .cancelled,
          message: "Consulta cancelada pelo usuário."
        )
      )
    )
    visualState = .ready
    primaryText = "Consulta cancelada"
    secondaryText = "Nenhuma ação foi executada"

    if let artifactID = activeArtifactID,
      let index = artifacts.firstIndex(where: { $0.id == artifactID }),
      artifacts[index].summary == "Aguardando o primeiro trecho…"
    {
      artifacts.remove(at: index)
      onLayoutInvalidated?()
    }

    activeArtifactID = nil
    streamedResponse = ""
    quickText = pendingPrompt ?? quickText
    pendingPrompt = nil
    isQuickTextEntryPresented = true
    onLayoutInvalidated?()
  }

  func toggleArtifact(_ id: UUID) {
    guard let index = artifacts.firstIndex(where: { $0.id == id }) else {
      return
    }
    artifacts[index].isExpanded.toggle()
    onLayoutInvalidated?()
  }

  func dismissArtifact(_ id: UUID) {
    artifacts.removeAll { $0.id == id }
    onLayoutInvalidated?()
  }

  func performArtifactAction(_ id: UUID, action: ArtifactActionModel) {
    guard let artifact = artifacts.first(where: { $0.id == id }) else {
      return
    }

    switch action.id {
    case "copy":
      NSPasteboard.general.clearContents()
      NSPasteboard.general.setString(
        artifact.detail ?? artifact.summary,
        forType: .string
      )
      primaryText = "Resposta copiada"
      secondaryText = nil
    default:
      break
    }
  }

  func expandLatestArtifact() {
    guard let index = artifacts.indices.last else {
      return
    }
    artifacts[index].isExpanded = true
    onLayoutInvalidated?()
  }

  /// Something is degraded but Evie still works.
  ///
  /// Deliberately quieter than `presentRuntimeError`: it does not take over the
  /// visual state, close the entry field, or cancel anything. A shortcut another
  /// application already owns is worth saying once, not worth interrupting for.
  func presentRuntimeWarning(_ message: String) {
    secondaryText = message
    onLayoutInvalidated?()
  }

  func presentRuntimeError(title: String, error: any Error) {
    requestTask?.cancel()
    requestTask = nil
    activeRequestID = nil
    activeArtifactID = nil
    isQuickTextEntryPresented = false
    visualState = .error
    primaryText = title
    secondaryText = error.localizedDescription
    artifacts.append(
      ArtifactCardModel(
        kind: .error,
        title: title,
        summary: error.localizedDescription,
        detail: "A Evie continua disponível pelo menu da barra.",
        isExpanded: true
      )
    )
    onLayoutInvalidated?()
  }
}

extension OverlayViewModel {
  /// The hidden persona message for the capabilities that are switched on right
  /// now. It is regenerated rather than stored so a capability change can never
  /// leave a stale claim in the conversation.
  fileprivate var systemPrompt: String {
    Self.systemPrompt(for: capabilities)
  }

  fileprivate static func systemPrompt(for capabilities: EvieCapabilitySnapshot) -> String {
    EviePersona.evie.systemPrompt(capabilities: capabilities)
  }

  fileprivate static func title(for prompt: String) -> String {
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

  fileprivate func persistConversation() {
    let visibleMessages = conversation.filter { message in
      message.role != .system && message.role != .developer
    }
    let snapshot = EvieConversation(
      id: activeConversationID,
      title: activeConversationTitle,
      createdAt: conversationCreatedAt,
      updatedAt: Date(),
      messages: visibleMessages
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

  fileprivate func receive(
    _ event: EvieInteractionEvent,
    requestID: UUID,
    userMessage: ChatMessage
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
      let content = message.content.trimmingCharacters(in: .whitespacesAndNewlines)
      if content.isEmpty {
        finishFailure(
          TurboFieldfareClientError.emptyStream,
          requestID: requestID
        )
        return
      }

      updateActiveArtifact(with: content)
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

  fileprivate func finishCancellation(requestID: UUID) {
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

  fileprivate func finishFailure(_ error: any Error, requestID: UUID) {
    let failure = EvieFailure(
      kind: .backend,
      message: error.localizedDescription,
      recoverySuggestion:
        "O modelo local não respondeu. Abra Configurações › Diagnóstico para conferir o motor."
    )
    finishFailure(failure, requestID: requestID)
  }

  fileprivate func finishFailure(_ failure: EvieFailure, requestID: UUID) {
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
        source: engineDescription,
        isExpanded: true
      )
    } else {
      artifacts.append(
        ArtifactCardModel(
          kind: .error,
          title: "Não consegui responder agora",
          summary: failure.message,
          detail: failure.recoverySuggestion,
          source: engineDescription,
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

  fileprivate func updateActiveArtifact(with content: String) {
    guard let artifactID = activeArtifactID,
      let index = artifacts.firstIndex(where: { $0.id == artifactID })
    else {
      return
    }
    artifacts[index].summary = content
  }

  fileprivate func artifactCard(from artifact: EvieArtifact) -> ArtifactCardModel {
    ArtifactCardModel(
      id: artifact.id,
      kind: artifactKind(from: artifact.kind),
      title: artifact.title,
      summary: artifact.content,
      source: artifact.sourceURL?.absoluteString,
      isExpanded: true
    )
  }

  fileprivate func artifactKind(from kind: EvieArtifact.Kind) -> ArtifactKind {
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

  fileprivate func visualState(for phase: EvieInteractionPhase) -> EvieVisualState {
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

  fileprivate func conversationPrefix(adding userMessage: ChatMessage) -> [ChatMessage] {
    var prefix = conversation
    let characterBudget = max(
      8_000,
      (agentClient.configuration.contextWindowTokens
        - agentClient.configuration.maxCompletionTokens) * 2
    )

    while prefix.count > 1,
      prefix.reduce(0, { $0 + $1.content.count }) + userMessage.content.count > characterBudget
    {
      removeOldestTurn(from: &prefix)
    }
    return prefix + [userMessage]
  }

  fileprivate func removeOldestTurn(from messages: inout [ChatMessage]) {
    guard messages.count > 1 else {
      return
    }

    messages.remove(at: 1)
    if messages.count > 1, messages[1].role == .assistant {
      messages.remove(at: 1)
    }
  }
}
