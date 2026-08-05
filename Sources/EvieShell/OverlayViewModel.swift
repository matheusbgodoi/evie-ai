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
  /// Documents read but not yet asked about. They travel with the next message.
  @Published private(set) var attachments: [EvieDocumentAttachment] = []

  var onLayoutInvalidated: (@MainActor () -> Void)?
  var onDismissRequested: (@MainActor () -> Void)?
  /// Set once a real capture path exists. While it is `nil` the mark says so
  /// instead of pretending the microphone opened.
  var onVoiceActivationRequested: (@MainActor () -> Void)?
  /// Called when an answer is complete, so it can be spoken. Only set when the
  /// user has asked Evie to speak.
  var onAnswerReady: (@MainActor (EvieRichText) -> Void)?

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
  private let documentReader = EvieDocumentReader()
  /// Ceiling on how much document text one turn may carry, so a long PDF cannot
  /// silently push the actual question out of the model's context.
  private static let attachmentCharacterLimit = 20_000

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
        .filter { $0.role == .user || $0.role == .assistant }
        .suffix(12)
        .map { message in
          message.role == .user
            ? ArtifactCardModel(
              id: message.id,
              kind: .prompt,
              title: Self.title(for: message.content),
              summary: message.content,
              isExpanded: false
            )
            : ArtifactCardModel(
              id: message.id,
              kind: .answer,
              title: stored.title,
              summary: message.content,
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

  /// Reads dropped or pasted files and holds them for the next question.
  ///
  /// Attaching does not ask anything by itself: you attach, then say what you
  /// want. Sending immediately would guess at a question the user has not asked.
  func attachFiles(at urls: [URL]) {
    let readable = urls.filter(EvieDocumentReader.canRead)
    let rejected = urls.filter { !EvieDocumentReader.canRead($0) }

    if !rejected.isEmpty {
      secondaryText =
        "Ainda leio só imagens e PDFs — "
        + rejected.map(\.lastPathComponent).joined(separator: ", ") + " ficou de fora."
    }
    guard !readable.isEmpty else {
      onLayoutInvalidated?()
      return
    }

    visualState = .usingTool
    primaryText = readable.count == 1 ? "Lendo o arquivo…" : "Lendo os arquivos…"
    onLayoutInvalidated?()

    Task { @MainActor [weak self] in
      guard let self else { return }
      for url in readable {
        do {
          let pages = try await documentReader.read(fileAt: url)
          appendAttachment(
            EvieDocumentAttachment(name: url.lastPathComponent, pages: pages)
          )
        } catch {
          artifacts.append(
            ArtifactCardModel(
              kind: .error,
              title: "Não consegui ler \(url.lastPathComponent)",
              summary: (error as? LocalizedError)?.errorDescription
                ?? error.localizedDescription,
              isExpanded: true
            )
          )
        }
      }
      visualState = .ready
      primaryText = attachments.isEmpty ? "Evie está pronta" : "Li o que você mandou"
      isQuickTextEntryPresented = true
      onLayoutInvalidated?()
    }
  }

  /// Opens the system file picker.
  ///
  /// Evie is an accessory application with no key window of her own, so she has
  /// to be activated first or the panel opens behind whatever is in front.
  func browseForFiles() {
    let panel = NSOpenPanel()
    panel.allowsMultipleSelection = true
    panel.canChooseDirectories = false
    panel.allowedContentTypes = EvieDocumentReader.supportedContentTypes
    panel.prompt = "Anexar"
    panel.message = "Escolha uma imagem ou um PDF para a Evie ler."

    NSApp.activate(ignoringOtherApps: true)
    guard panel.runModal() == .OK else {
      return
    }
    attachFiles(at: panel.urls)
  }

  func removeAttachment(id: UUID) {
    attachments.removeAll { $0.id == id }
    onLayoutInvalidated?()
  }

  private func appendAttachment(_ attachment: EvieDocumentAttachment) {
    attachments.append(attachment)
    artifacts.append(
      ArtifactCardModel(
        id: attachment.id,
        kind: .answer,
        title: attachment.name,
        summary: attachment.summary,
        detail: attachment.preview,
        source: attachment.provenanceDescription,
        isExpanded: false,
        actions: [
          ArtifactActionModel(
            id: "copy",
            title: "Copiar texto",
            systemImage: "doc.on.doc",
            role: .secondary
          )
        ]
      )
    )
    secondaryText = "Agora me pergunte o que você quer saber sobre isso."
  }

  /// The microphone is open. This is only ever called after capture actually
  /// started, so the listening indicator can never be shown over a closed
  /// microphone.
  func beginListening() {
    guard !hasActiveRequest else {
      return
    }
    visualState = .listening
    primaryText = "Ouvindo…"
    secondaryText = "Clique na chave de novo para parar"
    waveformSamples = []
    onLayoutInvalidated?()
  }

  /// The microphone closed and the recogniser is settling the last words.
  func presentTranscribing() {
    guard visualState == .listening else {
      return
    }
    visualState = .transcribing
    secondaryText = nil
    waveformSamples = []
    onLayoutInvalidated?()
  }

  /// Shows what is being heard while it is still being heard.
  ///
  /// The volatile part is the recogniser's current guess and is marked as such;
  /// it is never treated as a question, and it is discarded if capture ends on it.
  func updateTranscript(settled: String, volatile: String) {
    guard visualState == .listening else {
      return
    }
    let combined = [settled, volatile]
      .filter { !$0.isEmpty }
      .joined(separator: " ")
    primaryText = combined.isEmpty ? "Ouvindo…" : combined
    secondaryText = volatile.isEmpty ? nil : "ainda ouvindo…"
  }

  /// She started speaking. Only ever called once audio is actually playing.
  func beginSpeaking() {
    guard !hasActiveRequest else {
      return
    }
    visualState = .speaking
    primaryText = "Falando…"
    secondaryText = "Fale por cima para interromper"
    waveformSamples = []
    onLayoutInvalidated?()
  }

  func updateOutputLevels(_ levels: [CGFloat]) {
    guard visualState == .speaking else {
      return
    }
    waveformSamples = levels
  }

  func endSpeaking() {
    guard visualState == .speaking else {
      return
    }
    visualState = .ready
    primaryText = "Evie está pronta"
    secondaryText = nil
    waveformSamples = []
    isQuickTextEntryPresented = true
    onLayoutInvalidated?()
  }

  func updateInputLevels(_ levels: [CGFloat]) {
    guard visualState == .listening else {
      return
    }
    waveformSamples = levels
  }

  /// Capture stopped. `transcript` is `nil` while speech recognition is not wired,
  /// and the interface says so rather than pretending the audio was understood.
  func endListening(transcript: String?) {
    waveformSamples = []
    guard let transcript, !transcript.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    else {
      visualState = .ready
      primaryText = "Microfone fechado"
      secondaryText = "A transcrição ainda não está ligada — me escreva por enquanto."
      isQuickTextEntryPresented = true
      onLayoutInvalidated?()
      return
    }

    quickText = transcript
    visualState = .ready
    primaryText = "Transcrito"
    secondaryText = nil
    isQuickTextEntryPresented = true
    onLayoutInvalidated?()
    submitQuickText()
  }

  /// Voice could not start. Nothing about the interface may suggest it did.
  func presentVoiceUnavailable(_ error: any Error) {
    visualState = .ready
    waveformSamples = []
    primaryText = "Microfone indisponível"
    secondaryText =
      (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
    isQuickTextEntryPresented = true
    onLayoutInvalidated?()
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
    let evidence = takeAttachmentEvidence()
    let requestMessages = conversationPrefix(
      adding: userMessage,
      evidence: evidence
    )
    let client = agentClient

    activeRequestID = requestID
    activeArtifactID = artifactID
    streamedResponse = ""
    interactionState = EvieInteractionState(phase: .thinking)
    pendingPrompt = prompt
    quickText = ""
    // The field stays. Hiding it mid-answer made the layout jump and moved the
    // cancel control somewhere else at the exact moment it is wanted; now the
    // send button becomes a stop button in place.
    isQuickTextEntryPresented = true
    visualState = .thinking
    primaryText = "Pensando…"
    secondaryText = nil
    waveformSamples = []
    // Your own question, kept on screen. Without it the overlay is a column of
    // answers to questions that disappeared, and there is no way to find your
    // place in a long conversation.
    artifacts.append(
      ArtifactCardModel(
        id: userMessage.id,
        kind: .prompt,
        title: Self.title(for: prompt),
        summary: prompt,
        isExpanded: false
      )
    )
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
      // What lands on the clipboard is the answer without its syntax: no hashes,
      // no asterisks, no LaTeX. Pasting it anywhere should need no cleanup.
      NSPasteboard.general.clearContents()
      NSPasteboard.general.setString(
        EvieRichText(artifact.detail ?? artifact.summary).plainText,
        forType: .string
      )
      primaryText = "Resposta copiada"
      secondaryText = "Sem marcações — pronta para colar"

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

  fileprivate func conversationPrefix(
    adding userMessage: ChatMessage,
    evidence: ChatMessage? = nil
  ) -> [ChatMessage] {
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
    // Evidence goes immediately before the question so the model reads the
    // document, then what is being asked about it.
    return prefix + [evidence, userMessage].compactMap { $0 }
  }

  /// Consumes the pending attachments into one message, bounded so a long
  /// document cannot crowd out the question itself.
  fileprivate func takeAttachmentEvidence() -> ChatMessage? {
    guard !attachments.isEmpty else {
      return nil
    }
    let pages = attachments.flatMap(\.pages)
    attachments = []

    var evidence = pages.promptEvidence
    if evidence.count > Self.attachmentCharacterLimit {
      let cut = evidence.index(evidence.startIndex, offsetBy: Self.attachmentCharacterLimit)
      evidence = String(evidence[..<cut])
      evidence +=
        "\n<<<CORTADO AQUI — o documento é maior do que cabe nesta conversa>>>"
    }
    return ChatMessage(role: .user, content: evidence)
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
