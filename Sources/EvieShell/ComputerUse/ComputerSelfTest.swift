import AppKit
import ApplicationServices
import EvieCore

/// `evie-shell --cu-selftest`: the input executor, end to end, on TextEdit.
///
/// It opens TextEdit, makes a new untitled document (⌘N), types
/// "Teste de pesquisa — ação ✓" through the executor — the first part as key
/// events, the second pasted, the last set through the field's value, so all
/// three routes run — reads the document back through Accessibility, closes
/// it with ⌘W and the sheet's discard button found by Accessibility, quits
/// TextEdit, gives the front back to the app that had it, and checks the
/// clipboard came back as it was.
///
/// Everything goes through the real broker, policy and executor, under a
/// grant this command begins: running it is the person's gesture, and the two
/// confirmations it raises (⌘W, and the discard button when it is named
/// "Apagar") are approved by it, since they are the steps it was run for.
/// It refuses to start while TextEdit is open, so no document of the
/// person's can be touched; it never captures pixels (the observations are
/// accessibility lists only) and asks for no permission — without
/// Accessibility it says so and stops.
@MainActor
enum ComputerSelfTest {
  static let phrase = "Teste de pesquisa — ação ✓"
  /// The phrase in three parts, one per typing route.
  static let parts: [(text: String, mode: TypingMode)] = [
    ("Teste de pesquisa", .keys), (" — ação", .paste), (" ✓", .accessibility),
  ]
  static let textEdit = "com.apple.TextEdit"
  static let goal =
    "Abra o TextEdit, escreva um texto de teste num documento novo e feche sem salvar."
  /// The sheet's button that closes without saving, as macOS names it in
  /// Portuguese and English, before and after documents autosaved.
  static let discardTitles: Set<String> = [
    "Não Salvar", "Não salvar", "Don’t Save", "Don't Save", "Apagar", "Delete",
  ]

  enum Failure: Error, LocalizedError {
    case refused(String)
    case notConfirmed
    case timedOut(String)

    var errorDescription: String? {
      switch self {
      case .refused(let reason): "A política recusou: \(reason)"
      case .notConfirmed: "Uma confirmação não virou autorização."
      case .timedOut(let what): "Esperei demais por \(what)."
      }
    }
  }

  static func run() async {
    guard AXIsProcessTrusted(), CGPreflightPostEventAccess() else {
      say(
        "Este processo não tem a permissão de Acessibilidade, então não controla outros apps. "
          + "Nada foi pedido e nada foi feito.")
      return
    }
    let preferences = EviePreferencesStore().load()
    if let reason = ComputerUseSwitch.unavailableReason(
      preferences: preferences, environment: ProcessInfo.processInfo.environment)
    {
      say(reason + " Nada foi feito.")
      return
    }
    guard NSRunningApplication.runningApplications(withBundleIdentifier: textEdit).isEmpty else {
      say(
        "O TextEdit está aberto. Feche-o e rode de novo: o teste só usa um TextEdit que ele "
          + "mesmo abre, para nunca tocar num documento seu.")
      return
    }
    NSApp.setActivationPolicy(.accessory)

    let focus = FocusCoordinator()
    focus.recordFrontmost()
    let pasteboard = SystemPasteboard()
    let clipboardBefore = pasteboard.items()
    let presence = ScreenPresence(usesEscapeKey: false)
    let broker = EvieAgentModeBroker(policy: MacComputerActor.policy())
    guard let grant = broker.begin(goal: goal, gesture: .button),
      let executor = MacComputerActor.make(
        broker: broker, presence: presence, focus: focus,
        screenPermission: NoScreenRecording(), preferences: preferences)
    else {
      say("Não consegui começar a sessão.")
      return
    }
    let run = Run(broker: broker, grant: grant, executor: executor)
    say("Antes: na frente estava \(focus.personsApp?.localizedName ?? "nenhum app").")

    var passed = false
    do {
      passed = try await run.drive()
    } catch {
      say("Falhou: \(error.localizedDescription)")
    }
    broker.revoke()
    await executor.endObserving(succeeded: passed)

    await quitTextEditIfOurs(run.textEdit)
    let restored = await focus.restore()
    say("Foco devolvido ao \(focus.personsApp?.localizedName ?? "app anterior"): \(yes(restored))")
    let clipboardBack = pasteboard.items() == clipboardBefore
    say("Área de transferência igual à de antes: \(yes(clipboardBack))")
    say(passed && restored && clipboardBack ? "RESULTADO: passou" : "RESULTADO: falhou")
    // Lets the glow fade before the process quits.
    try? await Task.sleep(for: .seconds(1.2))
  }

  /// One session's state.
  @MainActor
  final class Run {
    let broker: EvieAgentModeBroker
    let grant: EvieAgentModeGrant
    let executor: ComputerExecutor
    var textEdit: ComputerAppIdentity?
    private var step = 0
    private let clock = ContinuousClock()

    init(broker: EvieAgentModeBroker, grant: EvieAgentModeGrant, executor: ComputerExecutor) {
      self.broker = broker
      self.grant = grant
      self.executor = executor
    }

    func drive() async throws -> Bool {
      try await act("abrir o TextEdit") { _ in .openApp(name: "TextEdit", url: nil) }
      let app = try await observe().frontApp
      guard app.bundleID == ComputerSelfTest.textEdit else {
        throw Failure.refused("o TextEdit não ficou na frente (\(app.name))")
      }
      textEdit = app

      try await act("⌘N") { _ in .pressKeys(KeyChord(parsing: "cmd+n")!) }
      let document = try await waitForEmptyDocument(app)
      say("Documento novo: “\(document)”.")

      for part in ComputerSelfTest.parts {
        executor.typingMode = part.mode
        try await act("digitar “\(part.text)” (\(part.mode.rawValue))") { _ in
          .typeText(part.text)
        }
      }
      executor.typingMode = .auto
      let readBack = await AccessibilityActions().focusedValue(ofProcess: app.processID)
      let matches = readBack == ComputerSelfTest.phrase
      say("Lido de volta pela Acessibilidade: “\(readBack ?? "nada")” — igual: \(yes(matches))")

      try await act("⌘W", approving: true) { _ in .pressKeys(KeyChord(parsing: "cmd+w")!) }
      // The sheet slides in; the executor refuses a window still moving, so
      // the button is acted on once the sheet has come to rest.
      try await waitForDiscardButton()
      try await Task.sleep(for: .milliseconds(600))
      try await act("botão de não salvar", approving: true) { observation in
        guard let button = ComputerSelfTest.discardButton(in: observation) else {
          throw Failure.timedOut("o botão de não salvar")
        }
        say("  botão: “\(button.title)”")
        return .click(
          .element(observationID: observation.id, index: button.index), button: .left, count: 1)
      }

      let closed = await waitUntilClosed(document, in: app)
      say("Documento fechado sem salvar: \(yes(closed))")
      return matches && closed
    }

    /// Observes, has the broker commit `make`'s action (approving when it
    /// asks and `approving` is set), and carries it out.
    @discardableResult
    func act(
      _ name: String,
      approving: Bool = false,
      _ make: (ComputerObservation) throws -> ComputerAction
    ) async throws -> ActionResult {
      if let next = broker.nextActionAllowedAt(grant), next > Date() {
        try await Task.sleep(for: .seconds(next.timeIntervalSinceNow))
      }
      let observation = try await observe()
      let action = try make(observation)

      let started = clock.now
      var clearance = broker.authorize(
        action, grant: grant, observation: observation, live: await executor.liveState())
      if case .needsConfirmation(let question) = clearance {
        guard approving else {
          throw Failure.refused("pediu confirmação: \(question.text)")
        }
        say("  confirmação aprovada pelo teste: \(question.text)")
        clearance = broker.approve(question, grant: grant, gesture: .button)
      }
      guard case .commit(let commit) = clearance else {
        if case .refused(let reason) = clearance {
          throw Failure.refused(reason)
        }
        throw Failure.notConfirmed
      }
      let result = try await executor.perform(action, commit: commit)
      say("\(name): \(result.outcome) em \(milliseconds(clock.now - started)) ms — \(result.detail)")
      guard result.outcome != .failed else {
        throw Failure.refused(result.detail)
      }
      return result
    }

    func observe() async throws -> ComputerObservation {
      step += 1
      let observation = try await executor.observe(
        ComputerObservationRequest(
          target: .screen, withImage: false, step: step,
          maxLongEdge: ScreenCapturePlan.longEdge(for: .yourPC)))
      broker.register(observation, grant: grant)
      return observation
    }

    private func waitForDiscardButton() async throws {
      let deadline = clock.now + .seconds(4)
      while clock.now < deadline {
        if ComputerSelfTest.discardButton(in: try await observe()) != nil {
          return
        }
        try await Task.sleep(for: .milliseconds(200))
      }
      throw Failure.timedOut("a folha de fechar o documento")
    }

    /// The new document is the focused window once its text area is focused
    /// and empty; its title is how it is told apart when it closes.
    private func waitForEmptyDocument(_ app: ComputerAppIdentity) async throws -> String {
      let deadline = clock.now + .seconds(5)
      while clock.now < deadline {
        if await AccessibilityActions().focusedValue(ofProcess: app.processID) == "",
          let title = ComputerSelfTest.focusedWindowTitle(of: app.processID)
        {
          return title
        }
        try await Task.sleep(for: .milliseconds(100))
      }
      throw Failure.timedOut("um documento novo e vazio")
    }

    private func waitUntilClosed(_ title: String, in app: ComputerAppIdentity) async -> Bool {
      let deadline = clock.now + .seconds(3)
      while clock.now < deadline {
        if !ComputerSelfTest.windowTitles(of: app.processID).contains(title) {
          return true
        }
        try? await Task.sleep(for: .milliseconds(100))
      }
      return false
    }
  }

  /// Quits the TextEdit this test opened: it was not running before, so
  /// nothing of the person's is in it. When a failure left the test's
  /// document open, it is first discarded through Accessibility — the
  /// window's close button, then the sheet's discard button — never saved.
  /// A polite quit only; if TextEdit still asks something, it is left open.
  private static func quitTextEditIfOurs(_ app: ComputerAppIdentity?) async {
    guard let app, let running = NSRunningApplication(processIdentifier: app.processID) else {
      return
    }
    for _ in 0..<3 where !windowTitles(of: app.processID).isEmpty {
      discardOpenDocument(of: app.processID)
      try? await Task.sleep(for: .milliseconds(500))
    }
    running.terminate()
    let deadline = ContinuousClock.now + .seconds(4)
    while !running.isTerminated, ContinuousClock.now < deadline {
      try? await Task.sleep(for: .milliseconds(100))
    }
    say("TextEdit encerrado: \(yes(running.isTerminated))")
  }

  static func discardButton(in observation: ComputerObservation) -> AXElementSummary? {
    observation.elements.first { $0.role == "AXButton" && discardTitles.contains($0.title) }
  }

  /// One step of closing the test's document without saving: the sheet's
  /// discard button when a sheet is up, else the window's close button.
  private static func discardOpenDocument(of processID: Int32) {
    let app = AXUIElementCreateApplication(processID)
    var value: CFTypeRef?
    guard AXUIElementCopyAttributeValue(app, "AXWindows" as CFString, &value) == .success,
      let windows = value as? [AXUIElement]
    else {
      return
    }
    for window in windows {
      if let discard = descendants(of: window, depth: 4).first(where: {
        AXTree.string($0, "AXRole") == "AXButton"
          && discardTitles.contains(AXTree.string($0, "AXTitle") ?? "")
      }) {
        AXUIElementPerformAction(discard, "AXPress" as CFString)
      } else if let close = AXTree.element(window, "AXCloseButton") {
        AXUIElementPerformAction(close, "AXPress" as CFString)
      }
    }
  }

  private static func descendants(of element: AXUIElement, depth: Int) -> [AXUIElement] {
    var value: CFTypeRef?
    guard depth > 0,
      AXUIElementCopyAttributeValue(element, "AXChildren" as CFString, &value) == .success,
      let children = value as? [AXUIElement]
    else {
      return []
    }
    return children + children.flatMap { descendants(of: $0, depth: depth - 1) }
  }

  static func focusedWindowTitle(of processID: Int32) -> String? {
    let app = AXUIElementCreateApplication(processID)
    return AXTree.element(app, "AXFocusedWindow").flatMap { AXTree.string($0, "AXTitle") }
  }

  static func windowTitles(of processID: Int32) -> [String] {
    let app = AXUIElementCreateApplication(processID)
    var value: CFTypeRef?
    guard AXUIElementCopyAttributeValue(app, "AXWindows" as CFString, &value) == .success,
      let windows = value as? [AXUIElement]
    else {
      return []
    }
    return windows.compactMap { AXTree.string($0, "AXTitle") }
  }
}

private func say(_ line: String) {
  print(line)
  fflush(stdout)
}

private func yes(_ value: Bool) -> String {
  value ? "sim" : "não"
}

private func milliseconds(_ duration: Duration) -> Int {
  Int(
    (Double(duration.components.seconds) * 1_000
      + Double(duration.components.attoseconds) / 1e15).rounded())
}
