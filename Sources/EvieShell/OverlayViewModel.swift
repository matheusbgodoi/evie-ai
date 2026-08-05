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

  private var agentClient: any AgentClient
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
    conversationStore: EvieConversationStore = EvieConversationStore()
  ) {
    self.agentClient = agentClient
    self.conversationStore = conversationStore
    conversation = [
      ChatMessage(role: .system, content: Self.systemPrompt)
    ]
  }

  var hasActiveRequest: Bool {
    activeRequestID != nil
  }

  var endpointDescription: String {
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
    conversation = [ChatMessage(role: .system, content: Self.systemPrompt)]
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
        [ChatMessage(role: .system, content: Self.systemPrompt)]
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
    secondaryText = "Resposta local via Gemma"
    onLayoutInvalidated?()
    return true
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
    primaryText = "Consultando o Gemma local…"
    secondaryText = endpointDescription
    waveformSamples = []
    artifacts.append(
      ArtifactCardModel(
        id: artifactID,
        kind: .answer,
        title: "Resposta da Evie",
        summary: "Aguardando o primeiro trecho…",
        source: "Gemma local · TurboFieldfare",
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
  fileprivate static let systemPrompt = """
    Você é Evie (pronúncia “ívi”), uma assistente pessoal local no macOS.
    Responda no idioma do usuário, com clareza e concisão. Neste estágio você não
    possui ferramentas, acesso à web, arquivos, e-mail, calendário ou WhatsApp.
    O histórico visível das conversas pode ser salvo localmente, mas você ainda
    não possui memória pessoal semântica nem RAG. Nunca alegue ter realizado uma
    ação externa. Quando uma solicitação depender dessas capacidades, explique a
    limitação brevemente e ajude com o que puder apenas pelo texto.
    """

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
        primaryText = "Gemma está pensando…"
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
      secondaryText = "\(usage.totalTokens) tokens · Gemma local"

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
      recoverySuggestion: "Confirme se o TurboFieldfare está rodando em \(endpointDescription)."
    )
    finishFailure(failure, requestID: requestID)
  }

  fileprivate func finishFailure(_ failure: EvieFailure, requestID: UUID) {
    guard activeRequestID == requestID else {
      return
    }

    interactionState.apply(.failed(failure))
    visualState = failure.kind == .cancelled ? .ready : .error
    primaryText = failure.kind == .cancelled ? "Consulta cancelada" : "Gemma indisponível"
    secondaryText = failure.recoverySuggestion

    if let artifactID = activeArtifactID,
      let index = artifacts.firstIndex(where: { $0.id == artifactID })
    {
      artifacts[index] = ArtifactCardModel(
        id: artifactID,
        kind: .error,
        title: "Não foi possível consultar o Gemma",
        summary: failure.message,
        detail: failure.recoverySuggestion,
        source: endpointDescription,
        isExpanded: true
      )
    } else {
      artifacts.append(
        ArtifactCardModel(
          kind: .error,
          title: "Não foi possível consultar o Gemma",
          summary: failure.message,
          detail: failure.recoverySuggestion,
          source: endpointDescription,
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
