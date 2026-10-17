import AVFoundation
import AppKit
import EvieCore

@MainActor
final class AppCoordinator: NSObject {
  private let conversationStore: EvieConversationStore
  private let configurationLoader: EvieConfigurationLoader
  private let configurationStore: EvieConfigurationStore
  private let preferencesStore: EviePreferencesStore
  private var preferences: EviePreferences
  private let preferencesLoadFailure: EviePreferencesStore.LoadFailure?
  /// The `EVIE_*` variables Evie launched with. Settings edits and reloads the
  /// profile they resolve to: `EVIE_MODEL_PROFILE`, or the preferred one.
  private let configurationEnvironment: [String: String]
  private let viewModel: OverlayViewModel
  private let chrome: OverlayChromeModel
  private let panelController: OverlayPanelController
  private let startupConfigurationError: (any Error)?
  /// What Evie launched with. Its profiles are what the settings pane repairs a
  /// damaged file from.
  private let startupConfiguration: EvieLoadedConfiguration
  /// Picks each conversation's brain before its turn is built, and the next
  /// one when the first fails before answering.
  private let brainResolver: EvieBrainResolver
  /// Kept warm from launch, so the first turn's resolver reads an answer
  /// instead of waiting on a probe.
  private let readinessRefresher: EvieReadinessRefresher
  /// The Mac brain's process: held here so quitting stops it.
  private let localBrainLauncher: EvieLocalBrainLauncher
  /// The resolver's readiness cache, refreshed when a key is saved in Settings
  /// so the next turn does not wait 30 s to learn the PC now accepts it.
  private let modelReadiness: ModelReadinessCache
  private var hotKeyController: GlobalHotKeyController?
  private var statusItem: NSStatusItem?
  private var settingsWindowController: SettingsWindowController?
  private var preferencesViewModel: EviePreferencesViewModel?
  /// Owned here rather than by the settings window: the folders decide what Evie
  /// can reach on every turn, so they have to outlive a window that is usually
  /// closed.
  private let rootsViewModel = EvieRootsViewModel()
  private var voiceLibraryViewModel: EvieVoiceLibraryViewModel?
  private let memoryViewModel = EvieMemoryViewModel()
  private let skillsViewModel = EvieSkillsViewModel()
  private let vaultIndex = EvieVaultIndex()
  private let audioCapture = EvieAudioCapture()
  private let speechOutput = EvieSpeechOutput()
  private let voiceEngineLauncher = EvieVoiceEngineLauncher()
  private let updater = EvieUpdater()
  private let mediaStore = EvieMediaStore()
  private let wakeListener = EvieWakeListener()
  private var wakeListeningTask: Task<Void, Never>?
  private var wakeSuppressedByStop = false
  /// Owned here, not by the settings window: its `reload()` sweeps orphan
  /// LaunchAgents, and that has to happen at launch rather than the first time
  /// somebody opens a pane.
  private let schedulesViewModel = EvieSchedulesViewModel()
  /// True while push-to-talk is holding the microphone open, so releasing the key
  /// stops it but a click on the mark toggles instead.
  private var isHoldingToTalk = false
  /// Whether the overlay is currently showing the voice-only surface. Distinct
  /// from the preference: the preference says the mark may switch into a call,
  /// this says it did.
  private var isInCall = false
  /// Held as `AnyObject` because speech recognition needs macOS 26 and the
  /// coordinator does not. Every use is inside an availability check.
  private var transcription: AnyObject?
  private var historyWindowController: ConversationHistoryWindowController?
  /// The guide's "Cérebro" row. Held here, not only by the guide, so a key
  /// saved in Settings can drop a test result the new key makes stale.
  private lazy var guideBrainStep = EvieGuideBrainStep(
    configuration: { [brainResolver] in brainResolver.configuration },
    probe: ModelClientFactory.live.makeReadinessProbe()
  )
  /// One checklist shared by the first-run window and the Settings pane, so a
  /// permission granted in one shows as granted in the other. Lazy because it
  /// asks the coordinator's own `audioCapture` for the microphone.
  private lazy var permissionGuide = PermissionGuideViewModel(
    items: PermissionGuideViewModel.standardItems(
      audioCapture: audioCapture,
      pcKey: EvieGuidePCKeyStep(
        keys: .live,
        configuration: { [brainResolver] in brainResolver.configuration },
        onKeySaved: { [weak self] profile in self?.modelKeySaved(for: profile) }
      ),
      brain: guideBrainStep
    ),
    store: PermissionGuideStore(
      fileURL: preferencesStore.fileURL
        .deletingLastPathComponent()
        .appendingPathComponent("permission-guide.json", isDirectory: false)
    ),
    isBundled: EvieAudioCapture.isBundled
  )
  private var permissionGuideWindowController: PermissionGuideWindowController?
  /// The glow and pill that say Evie is looking at the screen. Nothing is
  /// captured unless it is composited on the display being captured.
  private lazy var screenPresence = ScreenPresence()
  private lazy var screenCapture = ScreenCaptureService()
  private lazy var screenPermission = ScreenPermission(guide: permissionGuide)
  private lazy var researchMode: ResearchModeController = {
    let controller = ResearchModeController(
      brainResolver: brainResolver,
      look: EvieScreenLook(
        capturer: screenCapture, indicator: screenPresence, permission: screenPermission),
      host: computerUse)
    controller.isOtherInteractionBusy = { [weak self] in
      guard let self else { return true }
      return NativeWakeTrainingAccess.isActive || viewModel.hasActiveRequest
        || audioCapture.isCapturing || isInCall
        || viewModel.screenLookTask != nil || viewModel.pendingSession != nil
    }
    controller.onPrepare = { [weak self] in
      guard let self else { return }
      speechOutput.stop()
      wakeListener.disarm()
      panelController.hide()
      Task { [focusCoordinator] in await focusCoordinator.restore() }
    }
    controller.onStateChange = { [weak self] in
      self?.updateWakeListening()
      self?.refreshMenuShortcuts()
    }
    controller.onConfirmation = { [weak self] request in
      self?.viewModel.presentConfirmation(request)
      self?.panelController.showPassive()
    }
    controller.onCloseConfirmation = { [weak self] id in
      self?.viewModel.closeConfirmation(id)
      self?.panelController.hide()
    }
    return controller
  }()
  /// The app the person was in when the overlay opened, which an agent
  /// session acts in and hands the front back to when it is stopped.
  private let focusCoordinator = FocusCoordinator()
  private lazy var accessibilityPermission = AccessibilityPermission(guide: permissionGuide)
  /// Agent mode's parts: the session's broker and executor, the pause, the
  /// confirmation desk, the takeover monitor and the grant's clock.
  private lazy var computerUse = ComputerUseHost(
    presence: screenPresence,
    focus: focusCoordinator,
    screenPermission: screenPermission,
    accessibility: accessibilityPermission,
    preferences: { [weak self] in
      self?.preferences ?? EviePreferences(computerUseEnabled: false)
    }
  )
  /// The Cérebro tab's model while the settings window exists, so a key
  /// imported from the guide shows as saved there too.
  private weak var modelSettings: ModelSettingsViewModel?
  private weak var visibilityMenuItem: NSMenuItem?

  override init() {
    let processEnvironment = ProcessInfo.processInfo.environment
    let supportedEnvironmentNames = [
      "EVIE_CONFIG_FILE",
      "EVIE_MODEL_PROFILE",
      "EVIE_MODEL_ENDPOINT",
      "EVIE_MODEL_NAME",
      "EVIE_MODEL_CONTEXT",
      "EVIE_MODEL_MAX_COMPLETION",
      "EVIE_MODEL_TEMPERATURE",
      "EVIE_MODEL_TOP_P",
      "EVIE_MODEL_TIMEOUT_SECONDS",
    ]
    let configurationEnvironment = Dictionary(
      uniqueKeysWithValues: supportedEnvironmentNames.compactMap { name in
        processEnvironment[name].map { (name, $0) }
      }
    )
    let configurationLoader = EvieConfigurationLoader()
    let resolvedFileResult: Result<URL, any Error>
    do {
      resolvedFileResult = .success(
        try configurationLoader.resolvedFileURL(environment: configurationEnvironment)
      )
    } catch {
      resolvedFileResult = .failure(error)
    }

    // A file or environment that cannot be used falls back to the built-in
    // profiles — the PC — and the reason is shown once the overlay is up.
    let loadResult:
      (
        loaded: EvieLoadedConfiguration,
        fileURL: URL,
        error: (any Error)?
      )
    switch resolvedFileResult {
    case .success(let configurationFileURL):
      let (loaded, failure) = configurationLoader.loadWithDiagnostics(
        environment: configurationEnvironment
      )
      loadResult = (loaded, configurationFileURL, failure)
    case .failure(let error):
      loadResult = (.builtIn, configurationLoader.fileURL, error)
    }

    let conversationStore = EvieConversationStore()
    let preferencesStore = EviePreferencesStore(
      fileURL: loadResult.fileURL
        .deletingLastPathComponent()
        .appendingPathComponent("preferences.json", isDirectory: false)
    )
    let preferencesResult = preferencesStore.loadWithDiagnostics()
    // Whether each brain can answer now, kept for 30 s, and read by the
    // resolver on every turn.
    let modelReadiness = ModelReadinessCache(
      probe: ModelClientFactory.live.makeReadinessProbe()
    )
    // Starts LensVLM on this Mac when a turn needs it, and stops it after ten
    // idle minutes or when Evie quits.
    let localBrainLauncher = EvieLocalBrainLauncher()
    let brainResolver = EvieBrainResolver(
      configuration: loadResult.loaded,
      environment: configurationEnvironment,
      factory: .live,
      readiness: modelReadiness,
      localBrain: localBrainLauncher
    )
    brainResolver.choose(preferencesResult.preferences.brainChoice)
    let viewModel = OverlayViewModel(
      brainResolver: brainResolver,
      conversationStore: conversationStore,
      capabilities: Self.capabilities(
        for: preferencesResult.preferences,
        hasGrantedFolders: !EvieRootRegistry().load().isEmpty
      )
    )
    // Evie never launches into a call: that is an action, and actions are taken
    // by the person, not restored from a file.
    let chrome = OverlayChromeModel(appearance: preferencesResult.preferences.appearance)

    self.conversationStore = conversationStore
    self.configurationLoader = configurationLoader
    configurationStore = EvieConfigurationStore(fileURL: loadResult.fileURL)
    self.preferencesStore = preferencesStore
    preferences = preferencesResult.preferences
    preferencesLoadFailure = preferencesResult.failure
    self.configurationEnvironment = configurationEnvironment
    self.viewModel = viewModel
    self.chrome = chrome
    startupConfigurationError = loadResult.error
    startupConfiguration = loadResult.loaded
    self.brainResolver = brainResolver
    self.localBrainLauncher = localBrainLauncher
    self.modelReadiness = modelReadiness
    readinessRefresher = EvieReadinessRefresher(
      cache: modelReadiness,
      profile: loadResult.loaded.activeProfile
    )
    panelController = OverlayPanelController(
      viewModel: viewModel,
      chrome: chrome,
      appearance: preferencesResult.preferences.appearance,
      preferencesStore: preferencesStore
    )
    super.init()

    brainResolver.askToWake = { [weak self] question in
      guard let self else { return false }
      if researchMode.isRunning { panelController.showPassive() }
      return await viewModel.askToWake(question)
    }
    brainResolver.onWaking = { [weak viewModel] waking in
      viewModel?.showLocalBrainWaking(waking)
    }
    // A server a crash left behind, or one the script started, is taken over
    // so it unloads like any other; a stale pid file is removed.
    localBrainLauncher.reconcilePIDFile(for: loadResult.loaded.profiles)
    panelController.onPresent = { [focusCoordinator] in focusCoordinator.recordFrontmost() }
    viewModel.grantedRoots = { [rootsViewModel] in rootsViewModel.roots }
    viewModel.memories = { [memoryViewModel] in memoryViewModel.entries }
    viewModel.installedSkills = { [skillsViewModel] in skillsViewModel.skills }
    viewModel.indexedPassageCount = { [vaultIndex] in vaultIndex.passageCount }
    // Snapshotted per call rather than captured once: the index rebuilds when a
    // folder is granted, and a stale snapshot would search yesterday's vault.
    viewModel.retrieveFromVault = { [weak self] query in
      guard let self else { return [] }
      let (passages, vectors, retriever) = await MainActor.run {
        (vaultIndex.passages, vaultIndex.vectors, vaultIndex.retriever)
      }
      guard !passages.isEmpty else { return [] }
      return retriever.retrieve(query, from: passages, vectors: vectors)
    }
    viewModel.onSkillProposed = { [weak self] skill in
      self?.skillsViewModel.install(skill)
    }
    viewModel.isWebSearchEnabled = { [weak self] in self?.preferences.webSearchEnabled ?? false }
    viewModel.isMailAndCalendarEnabled = { [weak self] in
      self?.preferences.mailAndCalendarEnabled ?? false
    }
    viewModel.grantSuggestedRoot = { [rootsViewModel] suggestion in
      rootsViewModel.grantSuggested(suggestion)
    }
    viewModel.savesDocumentsWhenAsked = { [weak self] in
      self?.preferences.savesDocumentsWhenAsked ?? false
    }
    viewModel.fileChangePolicy = { [weak self] in
      guard let self else { return (false, false) }
      return (preferences.fileChangesEnabled, preferences.autoApproveChanges)
    }
    viewModel.onChangeApproved = { [weak self] change in
      guard let self,
        let root = rootsViewModel.roots.first(where: { $0.id == change.rootID })
      else {
        return "Essa pasta não está mais autorizada, então não mexi em nada."
      }
      do {
        let receipt = try EvieFileWriter().perform(change, in: root)
        switch receipt.change.kind {
        case .trash:
          return "\(change.path) está no Lixo. Dá para recuperar de lá."
        case .rename, .move:
          return "\(change.path) agora é \(receipt.resultingPath ?? change.destination ?? "?")."
        }
      } catch {
        return (error as? LocalizedError)?.errorDescription ?? "Não consegui fazer isso."
      }
    }
    // The only path from a button to the Calendar app. Re-checks the switch at
    // the moment of the press rather than trusting the card: a card can sit on
    // screen while somebody turns Mail and Calendar off, and honouring it then
    // would be reaching into an app he had just said no to.
    viewModel.onEventApproved = { [weak self] proposal in
      guard let self, preferences.mailAndCalendarEnabled else {
        return EvieCalendarEventReceipt(
          created: false,
          report: "O Mail e o Calendário estão desligados agora, então não criei nada."
        )
      }
      do {
        let landed = try await EvieMailCalendarClient().createEvent(proposal)
        // The calendar is read back from what the app answered, not repeated
        // from what was asked for, so the receipt says where it actually is.
        var created = proposal
        created.calendarName = landed
        return EvieCalendarEventReceipt(created: true, report: created.receipt)
      } catch {
        return EvieCalendarEventReceipt(
          created: false,
          report: (error as? LocalizedError)?.errorDescription
            ?? "Não consegui criar o compromisso."
        )
      }
    }
    // The only path from a button to a message leaving this Mac. Like the
    // calendar one it re-reads the switch at the moment of the press rather than
    // trusting the card, and here that matters more: a card can sit on screen
    // while he turns Mail and Calendar off, and honouring it then would be
    // sending mail from an app he had just said no to.
    viewModel.onMailApproved = { [weak self] proposal, sending in
      guard let self, preferences.mailAndCalendarEnabled else {
        return EvieMailReceipt(
          outcome: .failed,
          report: "O Mail está desligado agora, então não enviei nada."
        )
      }
      do {
        if sending {
          try await EvieMailCalendarClient().sendMail(proposal)
          return EvieMailReceipt(outcome: .sent, report: proposal.receipt)
        }
        try await EvieMailCalendarClient().saveMailDraft(proposal)
        return EvieMailReceipt(outcome: .draft, report: proposal.draftReceipt)
      } catch {
        return EvieMailReceipt(
          outcome: .failed,
          report: (error as? LocalizedError)?.errorDescription
            ?? (sending ? "Não consegui enviar o e-mail." : "Não consegui guardar o rascunho.")
        )
      }
    }
    speechOutput.setQualitySteps(preferences.voice.resolvedQualitySteps)
    viewModel.onMemoryDecided = { [weak self] fact, keep in
      guard let self, keep else { return }
      memoryViewModel.remember(fact)
    }
    memoryViewModel.onChange = { [weak self] in
      self?.viewModel.refreshSystemPrompt()
    }
    viewModel.refreshSystemPrompt()
    rootsViewModel.canChangeFiles = preferences.fileChangesEnabled
    rootsViewModel.autoApprovesChanges = preferences.autoApproveChanges
    rootsViewModel.onPolicyChanged = { [weak self] canChange, autoApprove in
      guard let self else { return }
      var updated = preferences
      updated.setFileChangesEnabled(canChange)
      updated.autoApproveChanges = autoApprove && canChange
      preferencesDidChange(updated)
      try? preferencesStore.save(updated)
    }
    rootsViewModel.savesDocumentsWhenAsked = preferences.savesDocumentsWhenAsked
    rootsViewModel.onDocumentPolicyChanged = { [weak self] savesWhenAsked in
      guard let self else { return }
      var updated = preferences
      updated.savesDocumentsWhenAsked = savesWhenAsked
      preferencesDidChange(updated)
      try? preferencesStore.save(updated)
    }
    rootsViewModel.onChange = { [weak self] roots in
      guard let self else { return }
      viewModel.applyCapabilities(
        Self.capabilities(for: preferences, hasGrantedFolders: !roots.isEmpty)
      )
      vaultIndex.rebuild(roots: roots)
    }
  }

  /// Evie only claims a capability whose code path is actually wired up.
  ///
  /// A preference is an intention, not a capability: wanting her to speak does
  /// not make her able to. Listening additionally requires a bundle identity,
  /// because without one macOS will never hand over the microphone.
  fileprivate static func capabilities(
    for preferences: EviePreferences,
    hasGrantedFolders: Bool
  ) -> EvieCapabilitySnapshot {
    var capabilities = EvieCapabilitySnapshot.textOnly
    capabilities.readsImagesAndDocuments = true
    capabilities.seesImages = EvieVisionDescriber.isAvailable
    // Told the truth about her own reach: with nothing granted she must not
    // offer to look, and the moment a folder is authorised she must know she
    // can. Claiming either wrongly is the fastest way to make her useless.
    capabilities.readsLocalFiles = hasGrantedFolders
    // The shell's own turns always offer documents, opening and the folders a
    // click away (ADR 0019); the schedule runner builds its own snapshot.
    capabilities.worksWithDocuments = true
    // Declared unconditionally: the tool is always offered, so the persona may
    // always tell her to use it.
    capabilities.calculates = true
    capabilities.readsMailAndCalendar = preferences.mailAndCalendarEnabled
    capabilities.searchesTheWeb = preferences.webSearchEnabled
    capabilities.speaksAnswers =
      preferences.voice.speechOutputEnabled && !EvieSpeechOutput.availableVoices().isEmpty
    if EvieAudioCapture.isBundled, preferences.voice.pushToTalkEnabled {
      if #available(macOS 26, *) {
        capabilities.listensToSpeech = EvieSpeechTranscription.isSupported
      }
    }
    return capabilities
  }

  func start() {
    NSApp.setActivationPolicy(.accessory)
    configureStatusItem()

    audioCapture.onLevels = { [weak self] levels in
      guard let self else { return }
      viewModel.updateInputLevels(levels, noiseFloor: audioCapture.noiseFloor)
    }
    audioCapture.onEndOfSpeech = { [weak self] in
      self?.stopListening()
    }
    viewModel.onVoiceActivationRequested = { [weak self] in
      self?.activateVoice()
    }
    speechOutput.onLevels = { [weak self] levels in
      self?.viewModel.updateOutputLevels(levels)
    }
    speechOutput.onStarted = { [weak self] in
      self?.viewModel.beginSpeaking()
    }
    speechOutput.onSpeakingChanged = { [weak self] speaking in
      guard let self else { return }
      viewModel.setSpeaking(speaking)
      // One place decides that speaking has ended, whether it ran out or was
      // stopped. Resetting the visuals only on `onFinished` meant pressing stop
      // silenced her and left the mark pulsing red — the audio was gone and the
      // interface still said she was talking.
      if !speaking {
        viewModel.endSpeaking()
      }
    }
    speechOutput.onFinished = { [weak self] in
      guard let self else { return }
      // A call keeps going. When she stops talking the microphone opens again,
      // which is the difference between a call and a sequence of questions.
      // Resetting the visuals is not done here: `onSpeakingChanged` covers both
      // ways speaking can end, and this one only covers running out.
      if isInCall {
        startListening(origin: .callMode)
      }
    }
    viewModel.onAnswerReady = { [weak self] answer in
      self?.speak(answer)
    }
    // Pressing the speaker is a person asking to hear this, which is not the
    // same question as whether she answers out loud on her own — so it does not
    // consult `speaksAnswer` at all. It does bring the voice engine up, the same
    // as any other request to speak.
    viewModel.onSpeakRequested = { [weak self] text in
      guard let self else { return }
      let voice = Self.voice(for: preferences.voice)
      let rate = preferences.voice.resolvedSpeechRate
      guard case .cloned = voice else {
        speechOutput.speak(text, using: voice, rate: rate)
        return
      }
      Task { @MainActor [weak self] in
        guard let self else { return }
        do {
          try await voiceEngineLauncher.ensureRunning()
        } catch {
          viewModel.reportVoiceEngineFailure(error)
          speechOutput.speak(text, using: Self.fallbackVoice(for: preferences.voice), rate: rate)
          return
        }
        speechOutput.speak(text, using: voice, rate: rate)
      }
    }
    // A block that could not be synthesised used to be skipped in silence, which
    // is how an answer stops halfway with nothing to explain it.
    speechOutput.onBlockFailed = { [weak self] in
      self?.viewModel.reportVoiceEngineFailure(
        SpeechGapNotice()
      )
    }
    viewModel.onSpeakStopRequested = { [weak self] in
      self?.speechOutput.stop()
    }

    voiceEngineLauncher.onRepaired = { [weak self] names in
      self?.viewModel.reportVoiceEngineFailure(
        VoiceRepairNotice(
          names: names)
      )
    }

    wakeListener.onWake = { [weak self] in
      guard let self else { return }
      // Called by name, so the answer follows the way the question was asked:
      // she comes, she opens the microphone, and she speaks the reply.
      panelController.showQuickText()
      startListening(origin: .wakeWord)
    }

    do {
      let controller = try GlobalHotKeyController()
      controller.onAction = { [weak self] action, phase in
        self?.perform(action, phase: phase)
      }
      hotKeyController = controller
      applyShortcuts()
    } catch {
      viewModel.presentRuntimeError(title: "Atalhos globais indisponíveis", error: error)
      panelController.showPassive()
    }

    // Armed at launch if that is what the preference says, so being able to call
    // her by name does not depend on having opened settings this session.
    updateWakeListening()
    readinessRefresher.start()
    viewModel.screenLook = EvieScreenLook(
      capturer: screenCapture,
      indicator: screenPresence,
      permission: screenPermission
    )
    viewModel.openScreenRecordingSettings = { [weak self] in
      self?.screenPermission.openSettings()
    }
    // Parar on the pill, or Esc during an agent session: the same as the
    // emergency shortcut.
    screenPresence.onStop = { [weak self] in
      self?.stopEverything()
    }
    // Agent mode: the pill's pause and Continuar hold and release the loop,
    // the grant's end stops it, and "para" is Parar.
    let computerUse = computerUse
    viewModel.computerUse = computerUse
    screenPresence.onPause = { [weak computerUse] in computerUse?.presencePaused() }
    screenPresence.onResume = { [weak computerUse] in computerUse?.presenceResumed() }
    computerUse.onExpired = { [weak self] in
      guard let self else { return }
      if researchMode.isRunning { researchMode.stop() } else { stopComputerUseSession() }
    }
    viewModel.isResearchBusy = { [weak self] in
      (self?.researchMode.isRunning ?? false) || NativeWakeTrainingAccess.isActive
    }
    viewModel.onStopRequested = { [weak self] in self?.stopEverything() }
    viewModel.computerUseConsentGiven = { [weak self] in
      self?.preferences.computerUseConsentGiven ?? false
    }
    viewModel.onComputerUseConsent = { [weak self] in self?.recordComputerUseConsent() }
    // The brain chip's menu: agent mode on and off without opening Settings,
    // and Settings opened on the section a line of the menu is about.
    viewModel.onSetAgentMode = { [weak self] enabled in self?.setAgentMode(enabled) }
    NativeWakeTrainingAccess.store = EvieWakeEnrollmentStore(
      fileURL: preferencesStore.fileURL.deletingLastPathComponent().appendingPathComponent(
        "wake-enrollment.json"))
    NativeWakeTrainingAccess.onAcquire = { [weak self] in
      guard let self else { throw NativeAppleError.notReady }
      guard !viewModel.hasActiveRequest, !researchMode.isArmed, !researchMode.isRunning,
        !audioCapture.isCapturing, !isInCall, !computerUse.isRunning,
        viewModel.pendingSession == nil, viewModel.screenLookTask == nil
      else { throw NativeAppleError.busy }
      wakeListeningTask?.cancel()
      wakeListeningTask = nil
      speechOutput.stop()
      wakeListener.disarm()
    }
    NativeWakeTrainingAccess.onRelease = { [weak self] in self?.updateWakeListening() }
    NativeWakeTrainingAccess.onSaved = { [weak self] in
      guard let self else { throw NativeAppleError.notReady }
      var updated = preferences
      updated.voice.wakePhrase = "Evie"
      updated.voice.wakeWordEnabled = true
      try preferencesStore.save(updated)
      wakeSuppressedByStop = false
      preferencesDidChange(updated)
    }
    NativeAppleActions.handle = { [weak self] request in
      guard let self else { throw NativeAppleError.notReady }
      guard !NativeWakeTrainingAccess.isActive, !viewModel.hasActiveRequest, !researchMode.isArmed,
        !researchMode.isRunning,
        viewModel.screenLookTask == nil, !computerUse.isRunning, !audioCapture.isCapturing,
        !isInCall, viewModel.pendingSession == nil
      else { throw NativeAppleError.busy }
      switch request {
      case .openConversation: openQuickText()
      case .prepareQuestion(let text):
        guard viewModel.quickText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
          throw NativeAppleError.busy
        }
        openQuickText()
        viewModel.quickText = text
      case .captureScreen: lookAtScreen()
      }
    }
    viewModel.onSetBrainReasoning = { [weak self] id, level in
      self?.setBrainReasoning(level, profileID: id)
    }
    viewModel.onBrainChoiceChanged = { [weak self] choice in
      guard let self else { throw CancellationError() }
      var updated = preferences
      updated.brainChoice = choice
      try preferencesStore.save(updated)
      preferencesDidChange(updated)
      researchMode.brainChoiceDidChange()
    }
    viewModel.onSetWebSearch = { [weak self] enabled in
      guard let self else { return }
      var updated = preferences
      updated.webSearchEnabled = enabled
      do {
        try preferencesStore.save(updated)
        preferencesDidChange(updated)
      } catch {
        viewModel.presentRuntimeError(title: "Não consegui mudar a pesquisa web", error: error)
      }
    }
    viewModel.onOpenSettingsSection = { [weak self] section in
      self?.openSettings(on: section)
    }
    viewModel.showAgentMode(isAgentModeOn)
    attachMediaLifecycle()
    buildVaultIndexIfMissing()

    // Evie has no Dock icon, so there is no ordinary way to reach Settings when a
    // shortcut is unavailable. This flag is that way out, and it is what makes the
    // window testable without a mouse.
    if CommandLine.arguments.contains("--open-settings") {
      openSettings()
    }

    if let startupConfigurationError {
      viewModel.presentRuntimeError(
        title: "Configuração local inválida",
        error: startupConfigurationError
      )
      panelController.showPassive()
    } else {
      openQuickText()
    }

    // After the overlay, so the checklist is the window in front on a first
    // launch rather than something the overlay covers.
    if permissionGuide.opensAtLaunch {
      openPermissionGuide()
    }
    if CommandLine.arguments.contains("--request-permissions") {
      openPermissionGuide()
      Task { [permissionGuide] in
        await permissionGuide.requestAvailablePermissions()
        EvieDiagnostics.writeLog(EviePermissionsAudit.report(), named: "permissions-check.log")
      }
    }
  }

  /// Diagnostics for `--presentation-check`. Not used by the running application.
  var presentationDiagnostics: String {
    panelController.diagnostics
  }

  func diagnosticShow() {
    openQuickText()
  }

  func diagnosticHide() {
    panelController.hide()
  }

  func stop() {
    wakeSuppressedByStop = true
    wakeListeningTask?.cancel()
    wakeListener.disarm()
    NativeWakeTrainingAccess.stop()
    NativeWakeTrainingAccess.onAcquire = nil
    NativeWakeTrainingAccess.onRelease = nil
    NativeWakeTrainingAccess.onSaved = nil
    NativeAppleActions.handle = nil
    readinessRefresher.stop()
    // Its 8 GB are not left behind for a process nobody will ask again.
    // `prepareForTermination` has normally stopped it already; this is the
    // last chance, and quit cannot wait here.
    localBrainLauncher.stopWithoutWaiting()
    audioCapture.stop()
    speechOutput.stop()
    viewModel.cancelCurrentInteraction()
    hotKeyController = nil
    researchMode.shutdown()
    if let statusItem {
      NSStatusBar.system.removeStatusItem(statusItem)
    }
    statusItem = nil
    settingsWindowController?.close()
    settingsWindowController = nil
    historyWindowController?.close()
    historyWindowController = nil
  }

  func prepareForTermination() async {
    wakeSuppressedByStop = true
    wakeListeningTask?.cancel()
    wakeListener.disarm()
    NativeWakeTrainingAccess.stop()
    researchMode.shutdown()
    audioCapture.stop()
    speechOutput.stop()
    viewModel.cancelCurrentInteraction()
    // At most the five-second grace: SIGKILL, if it comes to that, is sent
    // and not waited on.
    await localBrainLauncher.stop(waiting: .graceOnly)
    await viewModel.waitForHistoryPersistence()
  }
}

extension AppCoordinator {
  fileprivate func configureStatusItem() {
    let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
    item.button?.image = NSImage(
      systemSymbolName: "sparkles",
      accessibilityDescription: "Evie"
    )
    item.button?.toolTip = "Evie · assistente pessoal"

    let menu = NSMenu()
    menu.delegate = self
    item.menu = menu
    statusItem = item
    rebuildMenu()
  }

  /// Rebuilds the menu so every item shows the shortcut currently bound to it.
  ///
  /// Every action lives here as well as on a key combination: a shortcut the
  /// system refused, or one the user disabled, must never make a feature
  /// unreachable.
  fileprivate func rebuildMenu() {
    guard let menu = statusItem?.menu else {
      return
    }
    menu.removeAllItems()

    add(
      to: menu, title: "Conversar com a Evie…", action: #selector(openQuickText),
      shortcut: .quickText)
    add(to: menu, title: "Falar com a Evie", action: #selector(speakToEvie), shortcut: .pushToTalk)
    add(
      to: menu,
      title: preferences.voice.callModeEnabled ? "Sair do modo ligação" : "Entrar no modo ligação",
      action: #selector(toggleCallModeFromMenu),
      shortcut: .toggleCallMode
    )

    add(
      to: menu, title: "Olhar a tela", action: #selector(lookAtScreen),
      shortcut: .lookAtScreen)
    // A button to start a session, beside push-to-talk: no shortcut, so a
    // key can never begin one by itself.
    let controlItem = NSMenuItem(
      title: "Controlar o Mac…", action: #selector(controlTheMac), keyEquivalent: "")
    controlItem.target = self
    menu.addItem(controlItem)
    // The switch itself, checked while it is on, so the mode can be turned
    // off from wherever the menu bar is.
    let agentItem = NSMenuItem(
      title: "Modo agente", action: #selector(toggleAgentModeFromMenu), keyEquivalent: "")
    agentItem.target = self
    agentItem.state = isAgentModeOn ? .on : .off
    agentItem.isEnabled = !ComputerUseSwitch.forcedOff(
      environment: ProcessInfo.processInfo.environment)
    menu.addItem(agentItem)

    menu.addItem(.separator())
    add(
      to: menu, title: researchMode.isArmed ? "Desativar pesquisa" : "Ativar pesquisa…",
      action: #selector(toggleResearchMode), shortcut: .toggleResearchMode)
    let researchRun = add(
      to: menu, title: "Executar tarefa de pesquisa", action: #selector(runResearchTask),
      shortcut: .runResearchTask)
    researchRun.isEnabled = researchMode.isArmed && !researchMode.isRunning
    let researchStatus = NSMenuItem(
      title: String(researchMode.status.prefix(100)), action: nil, keyEquivalent: "")
    researchStatus.isEnabled = false
    menu.addItem(researchStatus)
    let researchWindow = NSMenuItem(
      title: "Pesquisa e medições…", action: #selector(showResearchWindow), keyEquivalent: "")
    researchWindow.target = self
    menu.addItem(researchWindow)

    menu.addItem(.separator())

    add(
      to: menu, title: "Nova conversa", action: #selector(newConversation),
      shortcut: .newConversation)
    add(to: menu, title: "Histórico…", action: #selector(openHistory), shortcut: .openHistory)
    let visibility = add(
      to: menu,
      title: panelController.isVisible ? "Ocultar Evie" : "Mostrar Evie",
      action: #selector(toggleOverlay),
      shortcut: .toggleOverlay
    )
    visibilityMenuItem = visibility

    menu.addItem(.separator())

    add(
      to: menu, title: "Parar tudo agora", action: #selector(stopEverythingFromMenu),
      shortcut: .emergencyStop)
    add(
      to: menu, title: "Configurações…", action: #selector(openSettingsFromMenu),
      shortcut: .openSettings)

    menu.addItem(.separator())

    let identityItem = NSMenuItem(
      title: "Evie · assistente pessoal",
      action: nil,
      keyEquivalent: ""
    )
    identityItem.isEnabled = false
    menu.addItem(identityItem)

    let quitItem = NSMenuItem(title: "Encerrar Evie", action: #selector(quit), keyEquivalent: "q")
    quitItem.target = self
    menu.addItem(quitItem)
  }

  @discardableResult
  fileprivate func add(
    to menu: NSMenu,
    title: String,
    action: Selector,
    shortcut: EvieShortcutAction
  ) -> NSMenuItem {
    let item = NSMenuItem(title: title, action: action, keyEquivalent: "")
    item.target = self
    if let binding = preferences.shortcuts.shortcut(for: shortcut),
      let character = binding.menuCharacter
    {
      item.keyEquivalent = character
      item.keyEquivalentModifierMask = Self.modifierMask(for: binding.modifiers)
    }
    menu.addItem(item)
    return item
  }

  fileprivate static func modifierMask(
    for modifiers: EvieModifierFlags
  ) -> NSEvent.ModifierFlags {
    var mask: NSEvent.ModifierFlags = []
    if modifiers.contains(.command) { mask.insert(.command) }
    if modifiers.contains(.option) { mask.insert(.option) }
    if modifiers.contains(.control) { mask.insert(.control) }
    if modifiers.contains(.shift) { mask.insert(.shift) }
    return mask
  }

  @objc fileprivate func speakToEvie() {
    viewModel.requestVoiceActivation()
  }

  @objc fileprivate func toggleCallModeFromMenu() {
    toggleCallMode()
  }

  @objc fileprivate func stopEverythingFromMenu() {
    stopEverything()
  }

  @objc fileprivate func toggleOverlay() {
    if panelController.isVisible {
      panelController.hide()
    } else {
      openQuickText()
    }
    updateToggleMenuTitle()
  }

  fileprivate func toggleQuickText() {
    if panelController.isVisible, viewModel.isQuickTextEntryPresented {
      panelController.hide()
    } else {
      openQuickText()
    }
    updateToggleMenuTitle()
  }

  @objc fileprivate func openQuickText() {
    guard !NativeWakeTrainingAccess.isActive else { return }
    wakeSuppressedByStop = false
    updateWakeListening()
    if viewModel.beginQuickText() {
      panelController.showQuickText()
    } else {
      panelController.showPassive()
    }
    updateToggleMenuTitle()
  }

  /// Captures the screen under the pointer for the next question. The
  /// overlay opens first; it is left out of the capture anyway.
  @objc fileprivate func lookAtScreen() {
    openQuickText()
    viewModel.captureScreenForNextQuestion()
  }

  @objc fileprivate func toggleResearchMode() {
    focusCoordinator.recordFrontmost()
    researchMode.toggle()
  }

  @objc fileprivate func runResearchTask() {
    researchMode.run()
  }

  @objc fileprivate func showResearchWindow() {
    focusCoordinator.recordFrontmost()
    researchMode.showWindow()
  }

  /// The next request, said or typed, becomes a session goal; its card
  /// still needs a click on Começar.
  @objc fileprivate func controlTheMac() {
    openQuickText()
    viewModel.askForComputerGoal()
  }

  @objc fileprivate func toggleAgentModeFromMenu() {
    setAgentMode(!preferences.computerUseEnabled)
  }

  @objc fileprivate func newConversation() {
    viewModel.startNewConversation()
    panelController.showQuickText()
    historyWindowController?.close()
    updateToggleMenuTitle()
  }

  @objc fileprivate func openHistory() {
    if historyWindowController == nil {
      let historyViewModel = ConversationHistoryViewModel(
        store: conversationStore,
        // The coordinator's own store, not a second one pointed at the same
        // folder. Two objects owning one directory is how a change made through
        // one becomes invisible to the other.
        mediaStore: mediaStore,
        onContinue: { [weak self] id in
          guard let self else { return }
          Task { @MainActor in
            guard await self.viewModel.openConversation(id: id) else {
              return
            }
            self.panelController.showQuickText()
            self.historyWindowController?.close()
            self.updateToggleMenuTitle()
          }
        },
        onNewConversation: { [weak self] in
          self?.newConversation()
        },
        onPrepareDelete: { [weak self] id in
          await self?.viewModel.prepareForConversationDeletion(id: id)
        },
        onDelete: { [weak self] id in
          self?.viewModel.conversationWasDeleted(id: id)
        }
      )
      historyWindowController = ConversationHistoryWindowController(
        viewModel: historyViewModel
      )
    }
    Task { @MainActor [weak self] in
      guard let self else { return }
      await viewModel.waitForHistoryPersistence()
      historyWindowController?.present()
    }
  }

  @objc fileprivate func quit() {
    NSApp.terminate(nil)
  }

  fileprivate func openPermissionGuide() {
    if permissionGuideWindowController == nil {
      permissionGuideWindowController = PermissionGuideWindowController(
        viewModel: permissionGuide,
        folders: rootsViewModel
      )
    }
    permissionGuideWindowController?.present()
  }

  /// A key was saved, from Settings or from the guide. Everything that showed
  /// the old state reads it again: the readiness cache, so the next turn does
  /// not wait 30 s to learn the PC now accepts it; the guide's rows; the
  /// Cérebro tab's key status.
  private func modelKeySaved(for profile: EvieModelProfile) {
    Task { [modelReadiness] in await modelReadiness.refresh(profile) }
    guideBrainStep.forgetResult()
    permissionGuide.refresh()
    modelSettings?.refreshKeyStatus()
  }

  @objc fileprivate func openSettingsFromMenu() {
    openSettings()
  }

  /// Opens Settings, on `section` when one is given.
  fileprivate func openSettings(on section: EvieSettingsSection? = nil) {
    if settingsWindowController == nil {
      let modelViewModel = ModelSettingsViewModel(
        loaded: brainResolver.configuration,
        repairBaseline: startupConfiguration.profiles,
        store: configurationStore,
        loader: configurationLoader,
        environment: configurationEnvironment,
        onSave: { [weak self] loaded in
          guard let self else { return }
          viewModel.applyConfiguration(loaded, environment: configurationEnvironment)
        },
        onKeySaved: { [weak self] profile in
          self?.modelKeySaved(for: profile)
        }
      )
      modelSettings = modelViewModel
      let preferencesViewModel = EviePreferencesViewModel(
        preferences: preferences,
        store: preferencesStore,
        loadFailure: preferencesLoadFailure,
        onTestVoice: { [weak self] identifier, rate in
          guard let self else { return }
          speechOutput.speak(
            EvieRichText("Oi, Matheus. É assim que eu vou falar com você."),
            using: Self.voice(for: preferences.voice),
            rate: rate
          )
          _ = identifier
        },
        onChange: { [weak self] updated in
          self?.preferencesDidChange(updated)
        }
      )
      self.preferencesViewModel = preferencesViewModel
      let voiceLibraryViewModel = EvieVoiceLibraryViewModel(
        preferences: { [weak self] in self?.preferences.voice ?? EvieVoicePreferences() },
        mutate: { [weak self] change in
          guard let self else { return }
          var updated = preferences
          change(&updated.voice)
          preferencesViewModel.adopt(updated)
          preferencesDidChange(updated)
          try? preferencesStore.save(updated)
        }
      )
      self.voiceLibraryViewModel = voiceLibraryViewModel
      settingsWindowController = SettingsWindowController(
        modelViewModel: modelViewModel,
        preferencesViewModel: preferencesViewModel,
        rootsViewModel: rootsViewModel,
        voiceLibraryViewModel: voiceLibraryViewModel,
        memoryViewModel: memoryViewModel,
        skillsViewModel: skillsViewModel,
        updater: updater,
        wakeListener: wakeListener,
        schedulesViewModel: schedulesViewModel,
        permissionGuide: permissionGuide,
        preferencesPath: preferencesStore.fileURL.path,
        configurationPath: configurationStore.fileURL.path
      )
    }
    settingsWindowController?.present(section: section)
  }

  /// Routes a global shortcut to the thing it names.
  ///
  /// Every route goes through the same methods the menu bar uses, so a shortcut
  /// and a menu item can never drift into doing different things.
  fileprivate func perform(_ action: EvieShortcutAction, phase: GlobalHotKeyController.Phase) {
    switch (action, phase) {
    case (.toggleOverlay, .pressed):
      toggleQuickText()
    case (.quickText, .pressed):
      openQuickText()
    case (.newConversation, .pressed):
      newConversation()
    case (.openHistory, .pressed):
      openHistory()
    case (.openSettings, .pressed):
      openSettings()
    case (.pushToTalk, .pressed):
      isHoldingToTalk = true
      startListening(origin: .pushToTalk)
    case (.pushToTalk, .released):
      guard isHoldingToTalk else {
        break
      }
      isHoldingToTalk = false
      stopListening()
    case (.toggleCallMode, .pressed):
      toggleCallMode()
    case (.emergencyStop, .pressed):
      stopEverything()
    case (.lookAtScreen, .pressed):
      lookAtScreen()
    case (.toggleResearchMode, .pressed):
      toggleResearchMode()
    case (.runResearchTask, .pressed):
      runResearchTask()
    default:
      break
    }
  }

  /// What pressing the mark does.
  ///
  /// With call mode on, the mark switches the whole overlay between voice and
  /// text: press once for the voice-only surface, press again to come back. With
  /// it off, the mark just opens and closes the microphone and the text stays
  /// where it is.
  fileprivate func activateVoice() {
    guard preferences.voice.callModeEnabled else {
      toggleListening()
      return
    }
    if isInCall {
      leaveCall()
    } else {
      enterCall()
    }
  }

  fileprivate func enterCall() {
    guard !isInCall else {
      return
    }
    isInCall = true
    chrome.setCallMode(true)
    viewModel.presentCallSurface()
    startListening(origin: .callMode)
  }

  fileprivate func leaveCall() {
    guard isInCall else {
      return
    }
    isInCall = false
    chrome.setCallMode(false)
    speechOutput.stop()
    viewModel.endSpeaking()
    stopListening()
    openQuickText()
  }

  /// Clicking the mark toggles; holding push-to-talk does not.
  fileprivate func toggleListening() {
    if audioCapture.isCapturing {
      stopListening()
    } else {
      startListening(origin: .clickedMark)
    }
  }

  /// Speaks an answer, if that is what the user asked for.
  ///
  /// Reads the text with its markup already resolved, so no asterisk or hash is
  /// ever pronounced.
  fileprivate func speak(_ answer: EvieRichText) {
    // Speech follows the saved voice preferences, including the owner's
    // enabled default for reading typed answers (ADR 0022).
    guard
      preferences.voice.speaksAnswer(
        toSpokenPrompt: viewModel.answeringSpokenPrompt,
        inCall: isInCall
      )
    else {
      return
    }
    let voice = Self.voice(for: preferences.voice)
    // The visual state follows `onStarted`, not this call: synthesis happens
    // first, and claiming she is speaking before any audio exists would be the
    // exact kind of dishonest indicator this project refuses.
    let rate = preferences.voice.resolvedSpeechRate

    // A trained voice needs its engine, and asking for the voice is the request
    // for the engine. Starting it costs a few seconds once; before this, a voice
    // chosen in settings simply never spoke and there was nothing on screen or in
    // any log to say why.
    guard case .cloned = voice else {
      speechOutput.speak(answer, using: voice, rate: rate)
      return
    }
    Task { @MainActor [weak self] in
      guard let self else {
        return
      }
      do {
        try await voiceEngineLauncher.ensureRunning()
      } catch {
        // Said out loud rather than swallowed, because falling silent is exactly
        // the failure this replaces. The system voice still reads the answer.
        viewModel.reportVoiceEngineFailure(error)
        speechOutput.speak(answer, using: Self.fallbackVoice(for: preferences.voice), rate: rate)
        return
      }
      speechOutput.speak(answer, using: voice, rate: rate)
    }
  }

  /// A cloned voice is used when one is chosen; whether its engine is running is
  /// discovered at synthesis time, and failing there falls silent rather than
  /// pretending a system voice was what you asked for.
  fileprivate static func voice(
    for preferences: EvieVoicePreferences
  ) -> EvieSpeechOutput.Voice {
    if let cloned = preferences.clonedVoiceID, !cloned.isEmpty {
      return .cloned(profileID: cloned)
    }
    // A voice the user removed from the list must not come back as the fallback
    // when nothing is chosen — that is the one place a hidden voice could still
    // speak.
    if let chosen = preferences.voiceIdentifier,
      !preferences.hiddenVoiceIdentifiers.contains(chosen)
    {
      return .system(identifier: chosen)
    }
    return fallbackVoice(for: preferences)
  }

  /// The best system voice available, used when a trained voice was asked for
  /// and its engine could not be brought up.
  fileprivate static func fallbackVoice(
    for preferences: EvieVoicePreferences
  ) -> EvieSpeechOutput.Voice {
    if let chosen = preferences.voiceIdentifier,
      !preferences.hiddenVoiceIdentifiers.contains(chosen)
    {
      return .system(identifier: chosen)
    }
    let firstVisible = EvieSpeechOutput.availableVoices()
      .first { !preferences.hiddenVoiceIdentifiers.contains($0.id) }
    return .system(identifier: firstVisible?.id)
  }

  /// Opens the microphone. `origin` is how it was opened, which decides
  /// whether what is heard may start an agent-mode session: push-to-talk
  /// and a click may, the wake word and a call may not.
  fileprivate func startListening(origin: ComputerUseRequestOrigin) {
    guard !researchMode.isRunning, !NativeWakeTrainingAccess.isActive else { return }
    wakeSuppressedByStop = false
    guard !audioCapture.isCapturing else {
      return
    }
    viewModel.spokenOrigin = origin
    // Only one thing may hold the microphone. Arming and a real turn are the
    // same device, and two owners is a hang inside coreaudiod rather than an
    // error anybody could act on.
    wakeListener.disarm()
    // Barge-in: opening the microphone always cuts whatever she is saying. Being
    // talked over is the whole point of being able to interrupt.
    speechOutput.stop()
    viewModel.endSpeaking()
    Task { @MainActor [weak self] in
      guard let self else { return }
      do {
        let format = try await audioCapture.prepareInputFormat()
        let sink = try await startTranscription(inputFormat: format)
        // Every spoken turn ends itself, except push-to-talk, where releasing
        // the key already says "I finished". Having to click a second time to
        // report that you stopped talking is what made speaking worse than
        // typing, and it is what stopped call mode from behaving like a call.
        audioCapture.detectsEndOfSpeech = !isHoldingToTalk
        try await audioCapture.start(sink: sink)
        viewModel.beginListening()
      } catch {
        isHoldingToTalk = false
        await cancelTranscription()
        viewModel.presentVoiceUnavailable(error)
      }
    }
  }

  /// Starts the recogniser when this Mac has one, and returns the sink the audio
  /// tap should feed. Without recognition the microphone still opens; the level
  /// ring works and the transcript simply does not exist.
  fileprivate func startTranscription(
    inputFormat: AVAudioFormat
  ) async throws -> (any EvieAudioBufferSink)? {
    guard #available(macOS 26, *), EvieSpeechTranscription.isSupported else {
      return nil
    }
    let recogniser = EvieSpeechTranscription()
    recogniser.onTranscriptChanged = { [weak self] settled, volatile in
      self?.viewModel.updateTranscript(settled: settled, volatile: volatile)
    }
    let pump = try await recogniser.start(inputFormat: inputFormat)
    transcription = recogniser
    return pump
  }

  fileprivate func cancelTranscription() async {
    guard #available(macOS 26, *),
      let recogniser = transcription as? EvieSpeechTranscription
    else {
      transcription = nil
      return
    }
    transcription = nil
    await recogniser.cancel()
  }

  fileprivate func stopListening() {
    guard audioCapture.isCapturing else {
      return
    }
    audioCapture.stop()
    // Handed back, so saying the phrase works again without reopening settings.
    updateWakeListening()

    guard #available(macOS 26, *),
      let recogniser = transcription as? EvieSpeechTranscription
    else {
      transcription = nil
      viewModel.endListening(transcript: nil)
      return
    }
    transcription = nil
    viewModel.presentTranscribing()
    Task { @MainActor [weak self] in
      let transcript = await recogniser.finish()
      self?.viewModel.endListening(transcript: transcript)
    }
  }

  /// Cancels the running answer and puts the overlay away.
  ///
  /// Once audio exists this also closes the microphone and cuts playback; the
  /// shortcut is registered now so the reflex is already in the user's hands.
  fileprivate func stopEverything() {
    wakeSuppressedByStop = true
    NativeWakeTrainingAccess.stop()
    wakeListeningTask?.cancel()
    wakeListeningTask = nil
    wakeListener.disarm()
    researchMode.stop()
    // A session first: the grant is revoked and its task cancelled before
    // anything else here, or any indicator, moves.
    let stoppedSession = stopComputerUseSession()
    isHoldingToTalk = false
    if isInCall {
      isInCall = false
      chrome.setCallMode(false)
    }
    audioCapture.stop()
    speechOutput.stop()
    viewModel.endSpeaking()
    Task { @MainActor [weak self] in
      await self?.cancelTranscription()
    }
    guard !stoppedSession else {
      // The overlay stays: its card shows what the session did.
      updateToggleMenuTitle()
      return
    }
    viewModel.cancelCurrentInteraction()
    panelController.hide()
    updateToggleMenuTitle()
  }

  /// Stops an agent session, if one runs — Parar, Esc, ⌥⇧Esc, "para", or the
  /// grant running out — and gives the front back to the app the person was
  /// in. Returns whether one ran.
  @discardableResult
  fileprivate func stopComputerUseSession() -> Bool {
    guard viewModel.stopComputerUse() else {
      return false
    }
    Task { @MainActor [weak self] in
      guard let self else { return }
      await focusCoordinator.restore()
      panelController.showPassive()
      updateToggleMenuTitle()
    }
    return true
  }

  /// The first session's Começar accepted the consent on its card.
  fileprivate func recordComputerUseConsent() {
    var updated = preferences
    updated.computerUseConsentGiven = true
    do {
      try preferencesStore.save(updated)
    } catch {
      // Not saved: the consent is shown again next launch, which is the safe
      // way to fail.
      viewModel.presentRuntimeWarning("Não consegui guardar o seu aceite do modo agente.")
    }
    preferencesDidChange(updated)
  }

  /// The shortcut does what the mark does, and switches the mode on first if it
  /// was off — a shortcut named after the mode should reach it in one press.
  fileprivate func toggleCallMode() {
    if !preferences.voice.callModeEnabled {
      var updated = preferences
      updated.voice.setCallModeEnabled(true)
      do {
        try preferencesStore.save(updated)
        preferencesDidChange(updated)
      } catch {
        viewModel.presentRuntimeError(title: "Não consegui mudar o modo", error: error)
        return
      }
      panelController.showPassive()
      enterCall()
      return
    }
    activateVoice()
  }

  /// Arms or disarms the wake phrase to match the preference.
  ///
  /// Called from everywhere the answer could have changed rather than only where
  /// the switch is flipped, because the microphone is also taken and given back
  /// by ordinary turns. A single place that recomputes the truth beats several
  /// that each remember one case of it.
  /// Ties the media folder to the conversations that name it.
  ///
  /// Deleting a conversation deletes what was attached to it, and anything left
  /// behind by a crash is swept at launch — a folder of pictures nobody can
  /// reach is exactly the kind of thing that quietly fills a disk.
  /// Builds the note index at launch when there is none.
  ///
  /// It used to be built only when a folder was added or removed, which meant a
  /// folder authorised in an earlier session never produced an index at all —
  /// every search of the notes answered "não achei nada" and every question
  /// silently fell through to the web or to memory. The retrieval was fine; it
  /// was never given anything to retrieve from.
  ///
  /// Cheap when a cache exists, since a rebuild only re-embeds files whose
  /// contents changed. The first build over a real vault costs about forty
  /// seconds and runs off the main actor.
  fileprivate func buildVaultIndexIfMissing() {
    let roots = rootsViewModel.roots
    guard !roots.isEmpty, vaultIndex.passageCount == 0 else {
      return
    }
    vaultIndex.rebuild(roots: roots)
  }

  fileprivate func attachMediaLifecycle() {
    let store = mediaStore
    Task { @MainActor [weak self] in
      guard let self else { return }
      await conversationStore.observeOrphanedMedia { orphaned in
        Task { @MainActor in
          store.delete(orphaned)
        }
      }
    }
    Task { @MainActor [weak self] in
      guard let self else { return }
      let summaries = (try? await conversationStore.list()) ?? []
      var kept: [EvieStoredMedia] = []
      for summary in summaries {
        if let conversation = try? await conversationStore.load(id: summary.id) {
          kept.append(contentsOf: conversation.media)
        }
      }
      mediaStore.collectGarbage(keeping: kept)
    }
  }

  fileprivate func updateWakeListening() {
    wakeListeningTask?.cancel()
    wakeListeningTask = nil
    guard preferences.voice.wakeWordEnabled, !wakeSuppressedByStop,
      !NativeWakeTrainingAccess.isActive, !audioCapture.isCapturing, !isInCall,
      !researchMode.isArmed, !researchMode.isRunning
    else {
      wakeListener.disarm()
      return
    }
    wakeListeningTask = Task { @MainActor [weak self] in
      guard let self, !Task.isCancelled, !wakeSuppressedByStop,
        !NativeWakeTrainingAccess.isActive, !researchMode.isArmed
      else { return }
      await wakeListener.arm(
        phrases: preferences.voice.wakePhrase,
        enrollment: NativeWakeTrainingAccess.enrollment(for: preferences.voice.wakePhrase))
    }
  }

  /// Said in the same place a voice failure is said, because it is the same kind
  /// of fact: something about how she speaks changed without you asking.
  /// One block of an answer could not be spoken. The rest still plays.
  struct SpeechGapNotice: LocalizedError {
    var errorDescription: String? {
      "Pulei um trecho que o motor de voz não conseguiu gerar."
    }
  }

  struct VoiceRepairNotice: LocalizedError {
    let names: [String]

    var errorDescription: String? {
      names.count == 1
        ? "Preparei a voz \(names[0]) — agora ela fala na hora."
        : "Preparei \(names.count) vozes — agora elas falam na hora."
    }
  }

  /// Whether agent mode is in effect: the switch, unless the environment
  /// forced it off for this launch.
  fileprivate var isAgentModeOn: Bool {
    ComputerUseSwitch.isEnabled(
      preferences: preferences, environment: ProcessInfo.processInfo.environment)
  }

  /// The agent-mode switch, from the chip's menu or the menu bar: saved, then
  /// applied like any other preference, and said on the status line — the
  /// same words Settings uses.
  fileprivate func setAgentMode(_ enabled: Bool) {
    guard enabled != preferences.computerUseEnabled else {
      return
    }
    var updated = preferences
    updated.computerUseEnabled = enabled
    do {
      try preferencesStore.save(updated)
    } catch {
      viewModel.presentRuntimeError(title: "Não consegui mudar o modo agente", error: error)
      return
    }
    preferencesDidChange(updated)
    viewModel.presentRuntimeWarning(ComputerUseCopy.switchMessage(enabled: enabled))
  }

  fileprivate func preferencesDidChange(_ updated: EviePreferences) {
    viewModel.objectWillChange.send()
    let appearanceChanged = updated.appearance != preferences.appearance
    let shortcutsChanged = updated.shortcuts != preferences.shortcuts
    preferences = updated
    brainResolver.choose(updated.brainChoice)
    if !isAgentModeOn { stopComputerUseSession() }
    if !isAgentModeOn, researchMode.isRunning, researchMode.destination == .controlMac {
      researchMode.stop(message: "Modo agente desativado · pesquisa interrompida")
    }
    speechOutput.setQualitySteps(updated.voice.resolvedQualitySteps)

    if appearanceChanged {
      panelController.applyAppearance(updated.appearance)
    }
    // Switching the mode off while a call is on screen has to end the call; the
    // surface it selected must not outlive the permission to show it.
    if !updated.voice.callModeEnabled, isInCall {
      leaveCall()
    }
    if shortcutsChanged {
      applyShortcuts()
    }
    updateWakeListening()
    refreshMenuShortcuts()
    viewModel.showAgentMode(isAgentModeOn)
    preferencesViewModel?.adopt(updated)
    viewModel.applyCapabilities(
      Self.capabilities(for: updated, hasGrantedFolders: !rootsViewModel.roots.isEmpty)
    )
  }

  fileprivate func setBrainReasoning(_ level: ReasoningLevel, profileID: String) {
    guard !viewModel.hasActiveRequest, !researchMode.isRunning else { return }
    do {
      _ = try configurationStore.saveProfiles(
        reading: configurationLoader, environment: configurationEnvironment,
        otherwise: startupConfiguration.profiles
      ) { profiles, _ in
        try profiles.updateProfile(id: profileID) { $0.defaultReasoning = level }
      }
      let loaded = try configurationLoader.loadProfiles(environment: configurationEnvironment)
      viewModel.applyConfiguration(loaded, environment: configurationEnvironment)
      try modelSettings?.adoptReasoning(level, profileID: profileID)
    } catch {
      viewModel.presentRuntimeError(title: "Não consegui mudar o raciocínio", error: error)
    }
  }

  /// Re-registers every shortcut and reports the ones the system refused.
  ///
  /// A refusal is normal — another application already owns the combination — so
  /// it is surfaced by name rather than silently swallowed.
  fileprivate func applyShortcuts() {
    guard let hotKeyController else {
      return
    }
    let failures = hotKeyController.apply(preferences.shortcuts)
    preferencesViewModel?.reportShortcutAvailability(unavailable: Set(failures.keys))
    if let message = GlobalHotKeyController.failureMessage(
      for: failures,
      preferences: preferences.shortcuts
    ) {
      viewModel.presentRuntimeWarning(message)
    }
  }

  fileprivate func updateToggleMenuTitle() {
    visibilityMenuItem?.title = panelController.isVisible ? "Ocultar Evie" : "Mostrar Evie"
  }

  /// Only the shortcut labels change, but rebuilding is cheap and keeps one
  /// definition of the menu instead of two that can drift.
  fileprivate func refreshMenuShortcuts() {
    rebuildMenu()
    updateToggleMenuTitle()
  }
}

extension AppCoordinator: NSMenuDelegate {
  func menuWillOpen(_ menu: NSMenu) {
    updateToggleMenuTitle()
  }
}
