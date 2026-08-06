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
  /// The ambient level the microphone is currently reporting, so the trace can
  /// be drawn against the room instead of against zero.
  @Published private(set) var waveformNoiseFloor: CGFloat = 0
  /// Whether the question being answered was spoken rather than typed. Read by
  /// the coordinator to decide whether the answer is read out loud.
  private(set) var lastPromptWasSpoken = false
  /// Whether the question *this answer belongs to* was spoken.
  ///
  /// Captured when the question is sent, not read when the answer arrives, and
  /// that difference is the whole point. `lastPromptWasSpoken` is ambient: it
  /// describes the most recent thing that happened, which by the time an answer
  /// comes back — tens of seconds later — may be a completely different turn.
  /// Open the microphone while a typed question is still in flight and the flag
  /// flips to true underneath it, so the typed answer is read out loud against
  /// an explicit preference not to. Measured from the report; the fix is to stop
  /// asking a question about the present that was only ever about the past.
  private(set) var answeringSpokenPrompt = false
  /// Whether web search is switched on, asked for at the start of every turn so
  /// turning it off takes effect on the next question.
  var isWebSearchEnabled: @MainActor () -> Bool = { false }
  /// Whether she may suggest changing a file, and whether a suggestion happens
  /// without a button. Both asked for per turn, so switching them off in Settings
  /// applies to the next question rather than the next launch.
  var fileChangePolicy: @MainActor () -> (offers: Bool, autoApproves: Bool) = {
    (false, false)
  }
  /// Carries out a change the user approved, and reports what happened.
  var onChangeApproved: (@MainActor (EvieFileChange) -> String)?
  /// The skills installed right now, asked for per turn so a skill dropped into
  /// the folder works on the next question rather than the next launch.
  var installedSkills: @MainActor () -> [EvieSkill] = { [] }
  /// Raised when she suggests a new one. Nothing is installed by this.
  var onSkillProposed: (@MainActor (EvieSkill) -> Void)?
  /// Hybrid retrieval over the indexed vault, when there is an index. Absent
  /// falls back to scanning for a substring, which is worse and is better than
  /// nothing.
  var retrieveFromVault: (@Sendable (String) async -> [EvieRetrievedPassage])?
  /// What she has been allowed to remember. Asked for when a turn starts rather
  /// than held, so a memory deleted in Settings stops applying to the next
  /// question rather than to the next launch.
  var memories: @MainActor () -> [EvieMemoryEntry] = { [] }
  /// Called with what the user decided about a proposed memory.
  var onMemoryDecided: (@MainActor (String, Bool) -> Void)?
  /// The folders Evie may look in, asked for at the start of every turn rather
  /// than held: a folder revoked in Settings has to stop working on the next
  /// question, not on the next launch.
  var grantedRoots: @MainActor () -> [EvieFileRoot] = { [] }

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
  /// Changes shown but not yet answered, so a button press knows what it means.
  private var pendingChanges: [UUID: EvieFileChange] = [:]
  private var pendingSkills: [UUID: EvieSkill] = [:]
  private let visionDescriber = EvieVisionDescriber()
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
    // The memory source is set by the coordinator right after construction, so
    // the first prompt is rebuilt once it exists.
  }

  /// Rebuilds the hidden persona message when a capability is switched on or
  /// off, so Evie never keeps claiming — or denying — something that changed
  /// mid-session. Only the system message is replaced; the visible turns stay.
  func applyCapabilities(_ capabilities: EvieCapabilitySnapshot) {
    self.capabilities = capabilities
    refreshSystemPrompt()
  }

  /// Rebuilds the hidden instructions in place, for when what she knows changed
  /// without the conversation changing.
  func refreshSystemPrompt() {
    let message = ChatMessage(role: .system, content: systemPrompt)
    if conversation.first?.role == .system {
      guard conversation[0].content != message.content else {
        return
      }
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
      artifacts = Self.cards(
        for: Array(Self.turns(in: stored.messages).suffix(Self.artifactPageSize))
      )
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
          // Sight is best-effort beside reading: a Mac without it still reads
          // the text, and a failure to describe must not lose the document.
          let seen = Self.isImage(url) ? try? await visionDescriber.describe(imageAt: url) : nil
          appendAttachment(
            EvieDocumentAttachment(
              name: url.lastPathComponent,
              pages: pages,
              visualDescription: seen
            )
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

  /// The overlay became the voice-only surface. Nothing is written there, so the
  /// text state is cleared rather than left behind it.
  func presentCallSurface() {
    isQuickTextEntryPresented = false
    quickText = ""
    waveformSamples = []
    onLayoutInvalidated?()
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

  /// Says why a trained voice is not the one speaking.
  ///
  /// Out loud rather than swallowed: the failure this replaces was silence with
  /// no explanation anywhere, which cost an evening of looking for a crash that
  /// had not happened.
  func reportVoiceEngineFailure(_ error: any Error) {
    secondaryText =
      (error as? LocalizedError)?.errorDescription
      ?? "Não consegui iniciar o motor de voz treinada."
  }

  func updateOutputLevels(_ levels: [CGFloat]) {
    guard visualState == .speaking else {
      return
    }
    waveformSamples = levels
    // Her own voice is played at a level Evie chose, so there is no room noise
    // to subtract from it.
    waveformNoiseFloor = 0
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

  func updateInputLevels(_ levels: [CGFloat], noiseFloor: CGFloat = 0) {
    guard visualState == .listening else {
      return
    }
    waveformSamples = levels
    waveformNoiseFloor = noiseFloor
  }

  /// Capture stopped. `transcript` is `nil` while speech recognition is not wired,
  /// and the interface says so rather than pretending the audio was understood.
  func endListening(transcript: String?) {
    waveformSamples = []
    // Remembered so the answer can follow the way the question was asked. Set
    // before the guard, because a failed transcription still came from someone
    // talking.
    lastPromptWasSpoken = true
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

  /// Submits what was typed. Typing is typing however the field was reached, so
  /// this is the one path that marks the turn as written.
  func submitTypedText() {
    lastPromptWasSpoken = false
    submitQuickText()
  }

  func submitQuickText() {
    let prompt = quickText.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !prompt.isEmpty, !hasActiveRequest else {
      NSSound.beep()
      return
    }

    let requestID = UUID()
    let userMessage = ChatMessage(role: .user, content: prompt)
    // The card is keyed on the question, not on a fresh identifier, because the
    // question is the one thing both this path and the restoring path know.
    // They used to disagree — a live card got a new UUID while a restored one
    // was keyed on the answer's — so every turn looked unshown the moment it
    // finished. That put "Ver 1 mensagem anterior" on screen after every answer,
    // and pressing it added a second copy of the turn just given.
    let artifactID = userMessage.id
    let evidence = takeAttachmentEvidence()
    let requestMessages = conversationPrefix(
      adding: userMessage,
      evidence: evidence
    )
    let client = agentClient

    activeRequestID = requestID
    activeArtifactID = artifactID
    // Pinned to this turn now, while it is still true of this turn.
    answeringSpokenPrompt = lastPromptWasSpoken
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
    // A new question closes everything before it. Reading is the point of the
    // window, and reading is easier when exactly one thing is open — the rest
    // stays a column of titles to scan and reopen deliberately.
    //
    // Except a card that is waiting on an answer. Its buttons only exist while
    // it is open, so closing it would leave a question nobody can reply to.
    for index in artifacts.indices where !artifacts[index].isAwaitingDecision {
      artifacts[index].isExpanded = false
    }
    artifacts.append(
      ArtifactCardModel(
        id: artifactID,
        kind: .answer,
        // The question is the title, because it is what you will be looking for
        // when you scroll back — not "Resposta da Evie", of which there are
        // twenty.
        title: Self.title(for: prompt),
        question: prompt,
        summary: "Aguardando o primeiro trecho…",
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

    // Only offered the tools when there is somewhere to use them. With no folder
    // granted, every tool call can only fail, and paying a whole extra round trip
    // to be told so is a slower answer for nothing.
    let roots = grantedRoots()
    let web: (any EvieWebSearching)? = isWebSearchEnabled() ? EvieWebClient() : nil
    let changePolicy = fileChangePolicy()
    // Read from his own message, not from the model's decision: a proposal that
    // came out of a document must still stop at a button.
    let heAskedForAChange = EvieChangeIntent.isPresent(in: prompt)

    // `/plano` is a different shape of turn: several model calls in a row rather
    // than one, minutes rather than seconds. It is a typed command and never a
    // guess, because something that expensive must not start because a question
    // looked complicated.
    if let asked = EviePlanCommand.question(in: prompt) {
      requestTask = Task { @MainActor [weak self] in
        await self?.runPlan(
          question: asked,
          requestID: requestID,
          userMessage: userMessage,
          roots: roots,
          web: web,
          client: client
        )
      }
      return
    }

    requestTask = Task { @MainActor [weak self] in
      do {
        guard !roots.isEmpty || web != nil else {
          for try await event in client.stream(messages: requestMessages) {
            try Task.checkCancellation()
            self?.receive(event, requestID: requestID, userMessage: userMessage)
          }
          return
        }

        // Captured again, weakly, rather than reaching for the enclosing `self`:
        // the loop's callback is `@Sendable` and runs off this actor, so it may
        // not close over the outer closure's mutable binding.
        let outcome = try await EvieAgentLoop(
          web: web,
          vault: self?.retrieveFromVault,
          offersChanges: changePolicy.offers
        ).run(
          messages: requestMessages,
          roots: roots,
          client: client
        ) { [weak self] event in
          await self?.receiveDuringLoop(event, requestID: requestID)
        }
        try Task.checkCancellation()
        self?.finishLoop(
          outcome,
          requestID: requestID,
          userMessage: userMessage,
          autoApproveChanges: changePolicy.autoApproves && heAskedForAChange
        )
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

    if action.id.hasPrefix("change-do:") {
      artifacts.removeAll { $0.id == id }
      if let change = pendingChanges[id] {
        performChange(change, wasAutomatic: false)
      }
      return
    }
    if action.id.hasPrefix("change-skip:") {
      artifacts.removeAll { $0.id == id }
      pendingChanges[id] = nil
      primaryText = "Não mexi em nada"
      onLayoutInvalidated?()
      return
    }

    if action.id == "skill-keep" {
      if let skill = pendingSkills[id] {
        onSkillProposed?(skill)
      }
      pendingSkills[id] = nil
      artifacts.removeAll { $0.id == id }
      primaryText = "Aprendido"
      secondaryText = "Vou seguir isso quando o assunto voltar"
      onLayoutInvalidated?()
      return
    }
    if action.id == "skill-discard" {
      pendingSkills[id] = nil
      artifacts.removeAll { $0.id == id }
      onLayoutInvalidated?()
      return
    }

    switch action.id {
    case "memory-keep":
      onMemoryDecided?(artifact.summary, true)
      artifacts.removeAll { $0.id == id }
      primaryText = "Guardado"
      secondaryText = "Ela vai lembrar disso nas próximas conversas"
      onLayoutInvalidated?()

    case "memory-discard":
      onMemoryDecided?(artifact.summary, false)
      artifacts.removeAll { $0.id == id }
      primaryText = "Descartado"
      secondaryText = "Ela não guardou nada"
      onLayoutInvalidated?()

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
    Self.systemPrompt(for: capabilities, remembering: memories())
  }

  fileprivate static func systemPrompt(
    for capabilities: EvieCapabilitySnapshot,
    remembering entries: [EvieMemoryEntry] = []
  ) -> String {
    let persona = EviePersona.evie.systemPrompt(capabilities: capabilities)
    guard let recall = EvieMemoryStore.recallBlock(from: entries) else {
      return persona
    }
    return persona + "\n\n" + recall
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

  /// `userMessage` is absent for events forwarded from inside the agent loop,
  /// which never carry the `.completed` that closes a turn — that turn is closed
  /// by `finishLoop` instead.
  fileprivate func receive(
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
  fileprivate func receiveDuringLoop(_ event: EvieInteractionEvent, requestID: UUID) {
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
  fileprivate func setProvenance(_ provenance: EvieAnswerProvenance, on id: UUID?) {
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
  fileprivate func presentChangeProposal(_ change: EvieFileChange) {
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
  fileprivate func performChange(_ change: EvieFileChange, wasAutomatic: Bool) {
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
  fileprivate func presentSkillProposal(_ skill: EvieSkill) {
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
  fileprivate func presentMemoryProposal(_ fact: String) {
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
  fileprivate func finishLoop(
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

    // Evidence goes immediately before the question so the model reads the
    // document, then what is being asked about it.
    return prefix + [evidence, userMessage].compactMap { $0 }
  }

  /// Consumes the pending attachments into one message, bounded so a long
  /// document cannot crowd out the question itself.
  /// Whether describing this file makes sense. A PDF is read, not looked at.
  fileprivate static func isImage(_ url: URL) -> Bool {
    ["png", "jpg", "jpeg", "heic", "heif", "gif", "tiff", "bmp", "webp"]
      .contains(url.pathExtension.lowercased())
  }

  fileprivate func takeAttachmentEvidence() -> ChatMessage? {
    guard !attachments.isEmpty else {
      return nil
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
    attachments = []

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
        title: Self.title(for: turn.question.content),
        question: turn.question.content,
        summary: turn.answer.content,
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
  fileprivate func isShown(_ turn: (question: ChatMessage, answer: ChatMessage)) -> Bool {
    let shown = Set(artifacts.map(\.id))
    return shown.contains(turn.question.id) || shown.contains(turn.answer.id)
  }

  /// Brings back the previous page of turns, oldest-last, all closed.
  func loadEarlierTurns() {
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
  fileprivate func runPlan(
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
  fileprivate func answer(
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
  fileprivate func runPlainTurn(
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

  fileprivate func finishPlan(
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
  fileprivate func settle(summary: String) {
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
