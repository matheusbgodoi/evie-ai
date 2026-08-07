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
  @Published var quickText = "" {
    didSet {
      guard quickText != oldValue else {
        return
      }
      // Typing brings the menu back after Escape closed it, and puts the
      // highlight on the first match. Keeping a highlight across a change of
      // text means Return runs whatever happened to be selected before, which
      // is the one thing a completion menu must never do.
      isCommandMenuDismissed = false
      commandHighlight = 0
    }
  }
  /// Which suggestion Return and Tab would take.
  @Published private(set) var commandHighlight = 0
  /// Escape closes the menu without closing Evie, and it stays closed until the
  /// text changes.
  @Published private(set) var isCommandMenuDismissed = false

  /// The commands worth offering for what is in the field.
  var commandSuggestions: [EvieCommand] {
    isCommandMenuDismissed ? [] : EvieCommandCatalogue.suggestions(for: quickText)
  }

  func moveCommandHighlight(by offset: Int) {
    let count = commandSuggestions.count
    guard count > 0 else {
      return
    }
    // Wraps, because a list this short is faster to cycle than to reverse.
    commandHighlight = ((commandHighlight + offset) % count + count) % count
  }

  /// Puts the highlighted command in the field, ready for its question.
  func completeCommand() {
    guard commandHighlight < commandSuggestions.count else {
      return
    }
    let chosen = commandSuggestions[commandHighlight]
    quickText = chosen.completion
    isCommandMenuDismissed = true
  }

  func dismissCommandMenu() {
    isCommandMenuDismissed = true
  }
  @Published private(set) var activeConversationID = UUID()
  // Not `private(set)`: the turn machinery that writes this lives in a sibling
  // file now, and `private(set)` is scoped to the file. Still internal, so
  // nothing outside this module can write it.
  @Published var activeConversationTitle = "Nova conversa"
  /// Documents read but not yet asked about. They travel with the next message.
  /// Files picked but not yet sent, in the order they were picked.
  ///
  /// Nothing here has reached the model. They go with the next message and only
  /// with it, which is the whole difference between attaching and sending.
  // Not `private(set)`: the turn machinery that writes this lives in a sibling
  // file now, and `private(set)` is scoped to the file. Still internal, so
  // nothing outside this module can write it.
  @Published var attachmentSlots: [EvieAttachmentSlot] = []
  var preparationTasks: [UUID: Task<Void, Never>] = [:]
  let mediaStore = EvieMediaStore()
  /// Files kept for the conversation being had, so it can be read back whole.
  var conversationMedia: [EvieStoredMedia] = []

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
  /// Reads an answer out loud because the button was pressed, whatever the
  /// preferences say about answering out loud on its own.
  ///
  /// Separate from `onAnswerReady` on purpose. That one is automatic and must
  /// obey the switches; this one is a person pointing at a thing and asking to
  /// hear it, which is not a preference to be overridden by a preference.
  var onSpeakRequested: (@MainActor (EvieRichText) -> Void)?
  var onSpeakStopRequested: (@MainActor () -> Void)?
  /// Where the speaking of an answer has got to.
  ///
  /// Three states rather than a flag, because the gap between pressing Ouvir and
  /// the first sound is a couple of seconds of synthesis, and a button that does
  /// not change during it looks like a button that missed the press.
  enum SpeechPhase {
    case idle
    case preparing
    case speaking
  }

  @Published private(set) var speechPhase: SpeechPhase = .idle
  /// Which button on which card is currently saying it worked.
  var confirmedAction: (card: UUID, action: String)?
  var confirmationTask: Task<Void, Never>?

  var isSpeaking: Bool {
    speechPhase == .speaking
  }

  func setSpeaking(_ speaking: Bool) {
    setSpeechPhase(speaking ? .speaking : .idle)
  }

  func setSpeechPhase(_ phase: SpeechPhase) {
    guard phase != speechPhase else {
      return
    }
    speechPhase = phase
    refreshSpeakActions()
    onLayoutInvalidated?()
  }
  /// Raised when she suggests a new one. Nothing is installed by this.
  var onSkillProposed: (@MainActor (EvieSkill) -> Void)?
  /// Hybrid retrieval over the indexed vault, when there is an index. Absent
  /// falls back to scanning for a substring, which is worse and is better than
  /// nothing.
  var retrieveFromVault: (@Sendable (String) async -> [EvieRetrievedPassage])?
  /// How many passages of the notes are indexed right now.
  ///
  /// Asked before a search so "nothing matched" and "nothing has been read yet"
  /// can be told apart — they produce the same empty result and mean opposite
  /// things.
  var indexedPassageCount: @MainActor () -> Int = { 0 }
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

  var agentClient: any AgentClient
  var capabilities: EvieCapabilitySnapshot
  let conversationStore: EvieConversationStore
  var conversation: [ChatMessage]
  var conversationCreatedAt = Date()
  var interactionState = EvieInteractionState()
  var requestTask: Task<Void, Never>?
  var persistenceTask: Task<Void, Never>?
  var conversationGeneration: UInt64 = 0
  var activeRequestID: UUID?
  var activeArtifactID: UUID?
  var streamedResponse = ""
  var pendingPrompt: String?
  let documentReader = EvieDocumentReader()
  /// Changes shown but not yet answered, so a button press knows what it means.
  var pendingChanges: [UUID: EvieFileChange] = [:]
  var pendingSkills: [UUID: EvieSkill] = [:]
  let visionDescriber = EvieVisionDescriber()
  /// Ceiling on how much document text one turn may carry, so a long PDF cannot
  /// silently push the actual question out of the model's context.
  static let attachmentCharacterLimit = 20_000

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
    // A file picked for the last conversation must not ride along into the next
    // one, and a read still running for it has nothing left to be read for.
    for task in preparationTasks.values {
      task.cancel()
    }
    preparationTasks = [:]
    attachmentSlots = []
    // Belongs to the conversation being left, which already holds it on disk.
    conversationMedia = []
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
      // Carried forward, or saving the reopened conversation would drop every
      // file it had — the record is rewritten whole on each save.
      conversationMedia = stored.media
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

    // The field opens, because an attachment with nowhere to type beside it is
    // the interface asking to be sent on its own.
    isQuickTextEntryPresented = true
    for url in readable {
      let slot = EvieAttachmentSlot(url: url, state: .preparing)
      attachmentSlots.append(slot)
      prepare(slot)
    }
    onLayoutInvalidated?()
  }

  /// Reads and, for a picture, looks at one attached file.
  ///
  /// Started on attach rather than on send: it is local work that costs nothing
  /// but time, and doing it while the question is still being typed is time the
  /// send would otherwise have to spend. Deliberately silent — no visual state,
  /// no card, nothing that could be mistaken for an answer.
  func prepare(_ slot: EvieAttachmentSlot) {
    preparationTasks[slot.id] = Task { @MainActor [weak self] in
      guard let self else { return }
      // Drawn first, so the chip stops being a grey pill the moment it appears
      // rather than when the reading finishes.
      if let picture = Self.thumbnail(for: slot.url),
        let index = attachmentSlots.firstIndex(where: { $0.id == slot.id })
      {
        attachmentSlots[index].thumbnail = picture
      }
      do {
        let pages = try await documentReader.read(fileAt: slot.url)
        try Task.checkCancellation()
        // Sight is best-effort beside reading: a Mac without it still reads the
        // text, and a failure to describe must not lose the document.
        let seen =
          Self.isImage(slot.url)
          ? try? await visionDescriber.describe(imageAt: slot.url) : nil
        try Task.checkCancellation()
        settle(
          slot.id,
          .ready(
            EvieDocumentAttachment(
              name: slot.url.lastPathComponent,
              pages: pages,
              visualDescription: seen
            )
          )
        )
      } catch is CancellationError {
        // Removed while it was being read. Nothing to report and nothing to keep.
      } catch {
        settle(
          slot.id,
          .failed(
            (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
          )
        )
      }
    }
  }

  /// A small picture of a file, for the chip.
  ///
  /// One path for images and PDFs alike: `NSImage` renders the first page of a
  /// PDF, which is exactly the preview worth showing.
  static func thumbnail(for url: URL, side: CGFloat = 52) -> NSImage? {
    guard let original = NSImage(contentsOf: url), original.size.width > 0 else {
      return nil
    }
    let scale = side / max(original.size.width, original.size.height)
    let size = NSSize(
      width: max(1, original.size.width * scale),
      height: max(1, original.size.height * scale)
    )
    let scaled = NSImage(size: size)
    scaled.lockFocus()
    original.draw(
      in: NSRect(origin: .zero, size: size),
      from: NSRect(origin: .zero, size: original.size),
      operation: .copy,
      fraction: 1
    )
    scaled.unlockFocus()
    return scaled
  }

  func settle(_ id: UUID, _ state: EvieAttachmentSlot.State) {
    preparationTasks[id] = nil
    guard let index = attachmentSlots.firstIndex(where: { $0.id == id }) else {
      return
    }
    attachmentSlots[index].state = state
    onLayoutInvalidated?()
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

  /// Waits for every file still being read, then sends.
  func awaitAttachmentsThenSubmit() {
    visualState = .usingTool
    primaryText = "Terminando de ler o anexo…"
    secondaryText = nil
    onLayoutInvalidated?()

    requestTask = Task { @MainActor [weak self] in
      guard let self else { return }
      for task in preparationTasks.values {
        await task.value
      }
      guard !Task.isCancelled else {
        return
      }
      requestTask = nil
      submitQuickText()
    }
  }

  /// Attaches whatever is on the clipboard, if it is something she can read.
  ///
  /// A screenshot goes to the clipboard as image data with no file behind it, so
  /// it is written to a temporary file first — everything downstream reads from
  /// a URL, and inventing a second path for pasted bytes would be two code paths
  /// for one idea.
  ///
  /// Returns whether anything was taken, so the field can fall back to pasting
  /// text when the clipboard holds text. Refusing a normal paste because
  /// something unreadable was on the clipboard would be worse than not
  /// supporting paste at all.
  @discardableResult
  func pasteAttachment() -> Bool {
    let pasteboard = NSPasteboard.general

    // Real files first: dragging a PDF out of Finder and copying it puts a URL
    // on the clipboard, and the file on disk is better than a re-encoding of it.
    if let urls = pasteboard.readObjects(forClasses: [NSURL.self]) as? [URL],
      !urls.isEmpty
    {
      let readable = urls.filter(EvieDocumentReader.canRead)
      if !readable.isEmpty {
        attachFiles(at: readable)
        return true
      }
    }

    guard let image = NSImage(pasteboard: pasteboard),
      let data = Self.pngData(from: image)
    else {
      return false
    }
    let url = FileManager.default.temporaryDirectory
      .appendingPathComponent("evie-colado-\(UUID().uuidString).png")
    guard (try? data.write(to: url)) != nil else {
      return false
    }
    attachFiles(at: [url])
    return true
  }

  static func pngData(from image: NSImage) -> Data? {
    guard let cgImage = image.cgImage(forProposedRect: nil, context: nil, hints: nil) else {
      return nil
    }
    return NSBitmapImageRep(cgImage: cgImage).representation(using: .png, properties: [:])
  }

  func removeAttachment(id: UUID) {
    preparationTasks[id]?.cancel()
    preparationTasks[id] = nil
    attachmentSlots.removeAll { $0.id == id }
    onLayoutInvalidated?()
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
    // Whatever went wrong, nothing is being prepared any more — the button must
    // not sit spinning over work that has stopped.
    setSpeechPhase(isSpeaking ? .speaking : .idle)
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
    var prompt = quickText.trimmingCharacters(in: .whitespacesAndNewlines)
    // An attachment on its own is a complete message. Refusing it because the
    // field is empty would mean the only way to ask about a document is to type
    // something first, and there is nothing to type.
    if prompt.isEmpty, attachmentSlots.contains(where: { $0.prepared != nil || $0.isPreparing }) {
      prompt = "Dá uma olhada nisso."
    }
    guard !prompt.isEmpty, !hasActiveRequest else {
      NSSound.beep()
      return
    }

    // Sending before a file finished being read would send the message without
    // it — silently, since the evidence is built from what is prepared. Waiting
    // is the only correct answer; it is usually already done, because reading
    // started when the file was picked.
    if attachmentSlots.contains(where: \.isPreparing) {
      quickText = prompt
      awaitAttachmentsThenSubmit()
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
    let evidence = takeAttachmentEvidence(for: userMessage.id)
    // What the person attached is the subject of the question. Looking anything
    // up is slower and answers a different question.
    let carriesAttachment = evidence != nil
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
    // A new question clears the screen. Closing the earlier cards was not
    // enough — a closed card is still a card, so the window kept growing a row
    // of titles nobody asked to see. They are not lost: every turn is in the
    // conversation, and "Ver mensagens anteriores" brings them back.
    //
    // Except a card that is waiting on an answer. Its buttons only exist while
    // it is open, so removing it would strand a question nobody can reply to.
    artifacts.removeAll { !$0.isAwaitingDecision }
    artifacts.append(
      ArtifactCardModel(
        id: artifactID,
        kind: .answer,
        // The question is the title, because it is what you will be looking for
        // when you scroll back — not "Resposta da Evie", of which there are
        // twenty.
        title: "",
        question: prompt,
        summary: "",
        isExpanded: true,
        isLoading: true,
        actions: Self.answerActions(phase: speechPhase)
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
    // `/buscar` never reaches the model at all: it runs the same retrieval a
    // question would have run and shows what came back. Dispatched before
    // anything asks whether there is a client, because there is nothing to ask
    // one.
    if let term = EvieVaultSearchCommand.query(in: prompt) {
      requestTask = Task { @MainActor [weak self] in
        await self?.runVaultSearch(term: term, requestID: requestID)
      }
      return
    }

    if let asked = EvieWebCommand.question(in: prompt) {
      guard !asked.isEmpty else {
        finishFailure(SearchCommandFailure.nothingToAsk, requestID: requestID)
        return
      }
      // Refused rather than quietly answered from memory. The command says where
      // the answer must come from; without the web switched on it cannot come
      // from there, and an answer under a `/web` question would read as though
      // it had.
      guard let web else {
        finishFailure(SearchCommandFailure.webIsOff, requestID: requestID)
        return
      }
      requestTask = Task { @MainActor [weak self] in
        await self?.runWebOnlyTurn(
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
          client: client,
          carriesAttachment: carriesAttachment
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

    // A card cancelled before anything arrived has nothing to keep. Recognised
    // by the loading flag rather than by comparing against a placeholder
    // sentence, which is a string two places had to agree on and one of them
    // would eventually be reworded.
    if let artifactID = activeArtifactID,
      let index = artifacts.firstIndex(where: { $0.id == artifactID }),
      artifacts[index].isLoading
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

    case "speak":
      // Toggles, because the thing you most want to do to a voice reading four
      // paragraphs at you is stop it.
      if isSpeaking {
        onSpeakStopRequested?()
        return
      }
      // Set before the request, because the couple of seconds of synthesis that
      // follow are exactly the window this is for.
      setSpeechPhase(.preparing)
      // Spoken from the resolved text, so no asterisk or hash is ever
      // pronounced, and never from the provenance note attached beside it.
      onSpeakRequested?(EvieRichText(artifact.detail ?? artifact.summary))

    case "copy":
      // What lands on the clipboard is the answer without its syntax: no hashes,
      // no asterisks, no LaTeX. Pasting it anywhere should need no cleanup.
      NSPasteboard.general.clearContents()
      NSPasteboard.general.setString(
        EvieRichText(artifact.detail ?? artifact.summary).plainText,
        forType: .string
      )
      confirm("copy", on: id)
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
