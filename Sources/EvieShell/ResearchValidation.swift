import AppKit
import ApplicationServices
import EvieCore

/// Explicit, one-shot integration diagnostic. It drives only the offline app
/// it launches, never approves a confirmation, and never uses general clipboard.
@MainActor
enum ResearchValidation {
  static let bundleID = "com.matheusbgodoi.evie.research-fixture"

  enum Failure: LocalizedError {
    case stopped(String)
    var errorDescription: String? {
      switch self {
      case .stopped(let reason): reason
      }
    }
  }

  static func run(fixturePath: String, agentPlansActions: Bool = false) async {
    setvbuf(stdout, nil, _IOLBF, 0)
    NSApp.setActivationPolicy(.accessory)
    let reportName =
      agentPlansActions ? "research-agent-validation.log" : "research-validation.log"
    var lines = [
      agentPlansActions
        ? "Evie research: native fixture → real model plans → isolated clipboard → executor"
        : "Evie research: native fixture → screenshot → real model → isolated clipboard → executor"
    ]
    func report(_ line: String) {
      lines.append(line)
      print(line)
    }
    defer { EvieDiagnostics.writeLog(lines, named: reportName) }
    guard AXIsProcessTrusted(), CGPreflightPostEventAccess(), CGPreflightScreenCaptureAccess()
    else {
      report(
        "RESULTADO: falhou — este processo precisa de Acessibilidade, eventos e Gravação de Tela; nada foi solicitado."
      )
      return
    }
    let url = URL(fileURLWithPath: fixturePath)
    guard Bundle(url: url)?.bundleIdentifier == bundleID,
      NSRunningApplication.runningApplications(withBundleIdentifier: bundleID).isEmpty
    else {
      report("RESULTADO: falhou — fixture inválida ou já aberta; nenhum app foi controlado.")
      return
    }
    let preferences = EviePreferencesStore().load()
    guard
      ComputerUseSwitch.isEnabled(
        preferences: preferences, environment: ProcessInfo.processInfo.environment)
    else {
      report("RESULTADO: falhou — modo agente desligado.")
      return
    }
    let focus = FocusCoordinator()
    focus.recordFrontmost()
    let directory = FileManager.default.temporaryDirectory
      .appendingPathComponent("evie-research-validation-\(UUID().uuidString)", isDirectory: true)
    let board = NSPasteboard(name: .init("evie-research-validation-\(UUID().uuidString)"))
    defer {
      board.releaseGlobally()
      try? FileManager.default.removeItem(at: directory)
    }
    var fixture: NSRunningApplication?
    let presence = ScreenPresence(usesEscapeKey: false)
    let broker = EvieAgentModeBroker(policy: MacComputerActor.policy())
    presence.onStop = { broker.revoke() }
    var executor: ComputerExecutor?
    var passed = false
    let start = ContinuousClock.now
    do {
      try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
      let stateURL = directory.appendingPathComponent("state.json")
      let nonce = UUID().uuidString
      let launch = NSWorkspace.OpenConfiguration()
      launch.createsNewApplicationInstance = true
      launch.arguments = [stateURL.path, nonce]
      let launched = try await NSWorkspace.shared.openApplication(at: url, configuration: launch)
      fixture = launched
      let pid = launched.processIdentifier
      guard launched.bundleIdentifier == bundleID,
        await focus.bringToFront(
          ComputerAppIdentity(bundleID: bundleID, name: "Evie Research Fixture", processID: pid))
      else { throw Failure.stopped("A fixture não ficou na frente.") }
      let initial = try await waitForState(stateURL, nonce: nonce, pid: pid)
      guard initial.answer.isEmpty, initial.selected.isEmpty else {
        throw Failure.stopped("A fixture não começou vazia.")
      }
      let locator = ComputerScreenLocator()
      let observer = ComputerObserver(
        capturer: ResearchValidationCapture(processID: pid), locator: locator,
        accessibility: AccessibilitySnapshotter(), indicator: presence,
        screenPermission: ResearchValidationPermission())
      let actor = ComputerExecutor(
        observer: observer, broker: broker,
        mac: .init(
          input: SyntheticInput(), accessibility: AccessibilityActions(), focus: focus,
          launcher: AppLauncher(), indicator: presence, locator: locator,
          clipboard: ClipboardSession(pasteboard: SystemPasteboard(pasteboard: board))))
      executor = actor
      let goal =
        agentPlansActions
        ? ResearchModeController.agentGoal(
          "Na janela Evie Research Fixture, resolva a questão visível; no campo informe apenas "
            + "o número, sem letra, e selecione a alternativa correspondente.")
        : "Na Evie Research Fixture, resolva a questão, copie o resultado, preencha o campo e selecione a alternativa."
      guard
        let grant = broker.begin(
          goal: goal,
          gesture: .researchShortcut, allowsClipboardWrites: true)
      else { throw Failure.stopped("O broker recusou a sessão de diagnóstico.") }
      let run = Run(executor: actor, broker: broker, grant: grant, processID: pid)
      let profile = EvieConfigurationLoader().loadWithDiagnostics().loaded.profiles.preferredProfile
      var configuration = profile.configuration
      actor.typingMode = .accessibility
      if agentPlansActions {
        var confirmationsRequested = 0
        let session = ComputerUseSession(
          broker: broker, grant: grant, computer: run,
          convention: profile.coordinateConvention,
          imageLongEdge: ScreenCapturePlan.longEdge(for: profile.location),
          confirm: { _ in
            confirmationsRequested += 1
            return false
          })
        report(
          "model: \(configuration.model); planning: real computer-use loop; reasoning: production computerStep"
        )
        let inference = ContinuousClock.now
        let outcome = try await EvieAgentLoop(readiness: .ready).runComputerUse(
          messages: [ChatMessage(role: .user, content: goal)],
          client: ModelClientFactory.live.makeClient(configuration: configuration),
          session: session, emit: { _ in })
        report("agent ending: \(outcome.ending); inference: \(inference.duration(to: .now))")
        report(
          "actions: \(run.actions); observations: \(outcome.observations); confirmations requested: \(confirmationsRequested); confirmations approved: 0; general clipboard writes: 0"
        )
        guard outcome.ending == .finished(.success), outcome.actions > 0,
          run.actions == outcome.actions
        else { throw Failure.stopped("O agente não concluiu a tarefa com ações reais.") }
      } else {
        let observation = try await run.observe(withImage: true)
        guard let image = observation.image else {
          throw Failure.stopped("A captura não produziu imagem.")
        }
        configuration.defaultReasoning = .off
        report(
          "model: \(configuration.model); reasoning: off; image: \(Int(image.pixelSize.width))×\(Int(image.pixelSize.height))"
        )
        let inference = ContinuousClock.now
        let answer = try await EvieResearchAnswer.read(
          image: image,
          goal:
            "Resolva a questão matemática visível. Responda somente com o resultado numérico, sem a letra da alternativa.",
          client: ModelClientFactory.live.makeClient(configuration: configuration),
          readiness: .ready)
        report("model answer: \(answer); inference: \(inference.duration(to: .now))")
        // The oracle checks accuracy; it never supplies text to the action.
        guard answer == "68" else {
          throw Failure.stopped("Resposta incorreta; nenhuma entrada foi feita na fixture.")
        }
        try await run.act { _ in .writeClipboard(answer) }
        guard let copied = board.string(forType: .string), copied == answer else {
          throw Failure.stopped("O clipboard isolado não devolveu a resposta do modelo.")
        }
        report("isolated clipboard roundtrip: true")
        try await run.act { observation in
          guard let field = observation.elements.first(where: { $0.role == "AXTextField" }) else {
            throw Failure.stopped("Campo de resposta não encontrado na fixture.")
          }
          return .click(
            .element(observationID: observation.id, index: field.index), button: .left, count: 1)
        }
        // AX insertion verifies the actual target value; no temporary general
        // clipboard is required for this route.
        try await run.act { _ in .typeText(copied) }
        let fieldValue = await AccessibilityActions().focusedValue(ofProcess: pid)
        guard fieldValue == answer else {
          throw Failure.stopped("O campo lido pela AX não confere.")
        }
        report("field AX readback equals model answer: true")
        try await run.act { observation in
          guard
            let option = observation.elements.first(where: {
              $0.role == "AXRadioButton" && $0.title.hasSuffix(") " + copied)
            })
          else { throw Failure.stopped("Alternativa correspondente à resposta não encontrada.") }
          return .click(
            .element(observationID: observation.id, index: option.index), button: .left, count: 1)
        }
      }
      // The oracle is only independent readback; it is never sent to the planner.
      let final = try await waitForState(
        stateURL, nonce: nonce, pid: pid,
        matching: {
          $0.answer == "68" && $0.selected == "B) 68"
        })
      guard broker.activeGrant?.id == grant.id else {
        throw Failure.stopped("O diagnóstico foi interrompido; o grant foi revogado.")
      }
      let copied = board.string(forType: .string)
      passed =
        final.answer == "68" && final.selected == "B) 68"
        && copied == final.answer && run.actions > 0
      report("isolated clipboard equals independent fixture answer: \(copied == final.answer)")
      report("fixture process readback: answer=\(final.answer); selected=\(final.selected)")
      if !agentPlansActions {
        report("actions: \(run.actions); confirmations approved: 0; general clipboard writes: 0")
      }
    } catch {
      report("failure: \(error.localizedDescription)")
    }
    broker.revoke()
    if let executor { await executor.endObserving(succeeded: passed) }
    if let fixture, !fixture.isTerminated {
      fixture.terminate()
      let deadline = ContinuousClock.now + .seconds(3)
      while !fixture.isTerminated, ContinuousClock.now < deadline {
        try? await Task.sleep(for: .milliseconds(50))
      }
      if !fixture.isTerminated { passed = false }
      report("own fixture terminated: \(fixture.isTerminated)")
    }
    if focus.personsApp != nil { report("previous focus restored: \(await focus.restore())") }
    report("total: \(start.duration(to: .now))")
    report(passed ? "RESULTADO: passou" : "RESULTADO: falhou")
  }

  private struct State: Decodable {
    let nonce: String
    let pid: Int32
    let answer: String
    let selected: String
  }

  private static func waitForState(
    _ url: URL, nonce: String, pid: Int32, matching: (State) -> Bool = { _ in true }
  ) async throws -> State {
    let deadline = ContinuousClock.now + .seconds(3)
    while ContinuousClock.now < deadline {
      try Task.checkCancellation()
      if let data = try? Data(contentsOf: url),
        let state = try? JSONDecoder().decode(State.self, from: data),
        state.nonce == nonce, state.pid == pid, matching(state)
      {
        return state
      }
      try await Task.sleep(for: .milliseconds(50))
    }
    throw Failure.stopped("A fixture não confirmou o estado esperado no prazo.")
  }

  @MainActor
  private final class Run: EvieComputerActing {
    let executor: ComputerExecutor
    let broker: EvieAgentModeBroker
    let grant: EvieAgentModeGrant
    let processID: Int32
    private var step = 0
    private(set) var actions = 0

    init(
      executor: ComputerExecutor, broker: EvieAgentModeBroker, grant: EvieAgentModeGrant,
      processID: Int32
    ) {
      self.executor = executor
      self.broker = broker
      self.grant = grant
      self.processID = processID
    }

    func observe(withImage: Bool = false) async throws -> ComputerObservation {
      try ensureFixture()
      step += 1
      let observation = try await observe(
        .init(
          target: .frontWindow, withImage: withImage, step: step, maxLongEdge: 1_024))
      guard broker.register(observation, grant: grant) else {
        throw Failure.stopped("Sessão da fixture revogada.")
      }
      return observation
    }

    func observe(_ request: ComputerObservationRequest) async throws -> ComputerObservation {
      try ensureFixture()
      var bounded = request
      bounded.target = .frontWindow
      let observation = try await executor.observe(bounded)
      try ensureFixture()
      guard observation.frontApp.processID == processID,
        observation.frontApp.bundleID == ResearchValidation.bundleID
      else { throw Failure.stopped("Observação fora da fixture.") }
      return observation
    }

    func liveState() async -> ComputerLiveState {
      do {
        try ensureFixture()
        let live = await executor.liveState()
        try ensureFixture()
        return live
      } catch {
        broker.revoke()
        return .init(frontApp: nil, secureInputEnabled: true, focusedFieldIsSecure: true)
      }
    }

    func perform(_ action: ComputerAction, commit: CapabilityCommit) async throws -> ActionResult {
      try ensureFixture()
      let result = try await executor.perform(action, commit: commit)
      actions += 1
      try ensureFixture()
      return result
    }

    func endObserving(succeeded: Bool) async {
      await executor.endObserving(succeeded: succeeded)
    }

    func act(_ make: (ComputerObservation) throws -> ComputerAction) async throws {
      if let next = broker.nextActionAllowedAt(grant), next > Date() {
        try await Task.sleep(for: .seconds(next.timeIntervalSinceNow))
      }
      let observation = try await observe()
      let action = try make(observation)
      let live = await liveState()
      try ensureFixture()
      let clearance = broker.authorize(action, grant: grant, observation: observation, live: live)
      guard case .commit(let commit) = clearance else {
        throw Failure.stopped(
          "Política recusou ou pediu confirmação; diagnóstico não aprova: \(clearance)")
      }
      let result = try await perform(action, commit: commit)
      guard result.outcome == .changed || result.outcome == .carriedOut else {
        throw Failure.stopped("Executor: \(result.detail)")
      }
    }

    private func ensureFixture() throws {
      try Task.checkCancellation()
      guard let app = NSWorkspace.shared.frontmostApplication,
        app.processIdentifier == processID, app.bundleIdentifier == ResearchValidation.bundleID
      else { throw Failure.stopped("O foco saiu da fixture; diagnóstico interrompido.") }
    }
  }
}

@MainActor
private final class ResearchValidationPermission: ScreenCapturePermission {
  var isGranted: Bool { CGPreflightScreenCaptureAccess() }
  var wasRequested: Bool { true }
  func request() -> Bool { false }
  func openSettings() {}
}
