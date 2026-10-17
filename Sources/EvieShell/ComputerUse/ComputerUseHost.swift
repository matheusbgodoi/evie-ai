import AppKit
import EvieCore

/// What an agent-mode session runs with on this Mac, from the confirm click
/// on its card to its end: the broker, the executor, the pause, the
/// confirmation desk, the takeover monitor and the grant's clock.
///
/// The rules are EvieCore's; this keeps their parts together so every stop
/// — Parar, Esc, ⌥⇧Esc, "para", the grant running out — reaches the same
/// `end()`, which revokes the grant before anything else.
@MainActor
final class ComputerUseHost {
  /// One session's authority. Made fresh for each, with the apps installed
  /// at its start.
  private struct Running {
    let broker: EvieAgentModeBroker
    let grant: EvieAgentModeGrant
    var expiry: Task<Void, Never>?
  }

  let pause = ComputerUsePause()
  let desk = ComputerConfirmationDesk()
  let monitor = TakeoverMonitor()
  let focus: FocusCoordinator
  /// The grant ran out: stop the session as a stop would.
  var onExpired: () -> Void = {}

  private let presence: ScreenPresence
  private let screenPermission: ScreenPermission
  private let accessibility: AccessibilityPermission
  private let preferences: () -> EviePreferences
  private let environment: [String: String]
  private var running: Running?

  init(
    presence: ScreenPresence,
    focus: FocusCoordinator,
    screenPermission: ScreenPermission,
    accessibility: AccessibilityPermission,
    preferences: @escaping () -> EviePreferences,
    environment: [String: String] = ProcessInfo.processInfo.environment
  ) {
    self.presence = presence
    self.focus = focus
    self.screenPermission = screenPermission
    self.accessibility = accessibility
    self.preferences = preferences
    self.environment = environment
    monitor.onTakeover = { [weak self] in self?.personTookOver() }
  }

  /// The Settings switch, unless `EVIE_COMPUTER_USE=0`.
  var isEnabled: Bool {
    ComputerUseSwitch.isEnabled(preferences: preferences(), environment: environment)
  }

  var isRunning: Bool {
    running != nil
  }

  /// The apps installed now, for reading a request ("abre o Notas"). Read
  /// again after a minute, so an app installed meanwhile is known.
  func apps() -> ComputerAppCatalog {
    if let cached = catalog, cached.readAt.timeIntervalSinceNow > -60 {
      return cached.apps
    }
    let apps = InstalledApps.catalog()
    catalog = (apps, Date())
    return apps
  }

  private var catalog: (apps: ComputerAppCatalog, readAt: Date)?

  /// What is missing before a session can act, asking macOS once for each
  /// permission a session needs: Accessibility (reading other apps and
  /// posting input), and Screen Recording for the pictures. Called only from
  /// the confirm click, so a prompt never appears in the middle of a session
  /// or at launch. `nil` when everything is granted.
  func missingPermission() -> String? {
    if !accessibility.isTrusted {
      if !accessibility.wasRequested {
        _ = accessibility.request()
      }
      return "Para controlar o Mac, a Evie precisa da permissão de Acessibilidade. Ligue-a em "
        + "Ajustes do Sistema › Privacidade e Segurança › Acessibilidade e peça de novo."
    }
    if !CGPreflightPostEventAccess(), !CGRequestPostEventAccess() {
      return "Para clicar e digitar, a Evie precisa poder controlar o computador. Ligue-a em "
        + "Ajustes do Sistema › Privacidade e Segurança › Acessibilidade e peça de novo."
    }
    switch ScreenCaptureAccess(
      isGranted: screenPermission.isGranted, wasRequested: screenPermission.wasRequested)
    {
    case .granted:
      return nil
    case .mayAsk:
      if screenPermission.request() {
        return nil
      }
      fallthrough
    case .openSettings:
      return "Para ver a tela, a Evie precisa da Gravação de Tela. Ligue-a em Ajustes do Sistema "
        + "› Privacidade e Segurança › Gravação de Tela, reabra a Evie e peça de novo."
    }
  }

  /// Begins the session after the confirm click: the grant (the click is the
  /// gesture), the executor over this Mac, the monitor, the grant's clock.
  /// `nil` when agent mode is off or the broker refuses.
  func begin(
    goal: String,
    on profile: EvieModelProfile,
    log: ComputerActionLog,
    gesture: UserGesture = .button,
    expiresAt: Date? = nil,
    allowsClipboardWrites: Bool = false
  ) -> ComputerUseSession? {
    end()
    let broker = EvieAgentModeBroker(policy: MacComputerActor.policy())
    guard
      let executor = MacComputerActor.make(
        broker: broker, presence: presence, focus: focus, screenPermission: screenPermission,
        preferences: preferences(), environment: environment),
      let grant = broker.begin(
        goal: goal, gesture: gesture, expiresAt: expiresAt,
        allowsClipboardWrites: allowsClipboardWrites)
    else {
      return nil
    }
    presence.brainLocation = profile.location.statusTag
    presence.stepBudget = ComputerUseBudget.maximumActions
    pause.resume()
    monitor.start()
    let expiry = Task { [weak self] in
      try? await Task.sleep(for: .seconds(max(0, grant.expiresAt.timeIntervalSinceNow)))
      guard !Task.isCancelled else { return }
      self?.onExpired()
    }
    running = Running(broker: broker, grant: grant, expiry: expiry)
    return ComputerUseSession(
      broker: broker,
      grant: grant,
      computer: executor,
      convention: profile.coordinateConvention,
      imageLongEdge: ScreenCapturePlan.longEdge(for: profile.location),
      confirm: { [weak self] request in
        await self?.ask(request) ?? false
      },
      pause: pause,
      log: log
    )
  }

  /// Ends the session: the grant first, so no commit stands from here on,
  /// then the question on screen (a no), the monitor, the pause, the clock.
  /// The caller cancels the session's task right after.
  func end() {
    guard let current = running else {
      return
    }
    running = nil
    current.broker.revoke()
    current.expiry?.cancel()
    desk.withdraw()
    monitor.stop()
    pause.resume()
    // A later one-shot look says nothing about steps or this brain.
    presence.brainLocation = nil
    presence.stepBudget = nil
  }

  /// After `end()` and the task's cancellation, for a stop that did not come
  /// from the presence itself: the glow and pill come down as a stop.
  func takeDownPresence() {
    presence.endStoppedSession()
  }

  /// Shows the confirmation card and waits for a hand on it. The person's
  /// mouse is the answer, so it is not a takeover meanwhile.
  private func ask(_ request: ComputerConfirmationRequest) async -> Bool {
    monitor.hold()
    defer { monitor.release() }
    return await desk.ask(request)
  }

  /// Untagged input: the presence draws the pause (Continuar, Parar, 60 s),
  /// and its `onPause` holds the loop.
  private func personTookOver() {
    guard isRunning, !pause.isPaused else {
      return
    }
    Task { [presence] in
      await presence.show(.paused(reason: ScreenPresenceCopy.paused))
    }
  }

  /// The presence drew the pause.
  func presencePaused() {
    guard isRunning else {
      return
    }
    pause.pause()
  }

  /// Continuar on the pill.
  func presenceResumed() {
    monitor.quiet()
    pause.resume()
  }
}
