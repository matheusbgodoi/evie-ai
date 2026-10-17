import Foundation
import Synchronization
import Testing

@testable import EvieCore

/// The readiness probe against a stubbed gateway and a stubbed local brain.
///
/// Every request is answered by `ReadinessStubURLProtocol`, which claims every
/// URL its session is given, so no host here is resolved or contacted. Each test
/// owns a host (remote) or a port (loopback) of its own and registers what that
/// server answers, so the shared request log can be read per test while suites
/// run in parallel.
@Suite("Model readiness probe")
struct ModelReadinessProbeTests {
  private let token = "test-token-not-a-secret"

  // MARK: Remote gateway

  @Test("a /health that never answers gives unreachable, and nothing else is asked")
  func healthTimeoutIsUnreachable() async {
    let server = StubServer.remote()
    server.answer("/health", with: .hang)
    let (probe, _) = makeProbe(for: server, tokens: [server.credential: token])

    let readiness = await probe.check(server.profile(model: "qwen-daily"))

    #expect(readiness.rung == .unreachable)
    #expect(server.sent.map(\.path) == ["/health"])
  }

  @Test("a connection that fails gives unreachable")
  func connectionFailureIsUnreachable() async {
    let server = StubServer.remote()
    server.answer("/health", with: .fail(.cannotConnectToHost))
    let (probe, _) = makeProbe(for: server, tokens: [server.credential: token])

    let readiness = await probe.check(server.profile(model: "qwen-daily"))

    #expect(readiness.rung == .unreachable)
  }

  @Test("/health is asked at the origin, without the key, before anything else")
  func healthAtOriginWithoutKey() async {
    let server = StubServer.remote()
    server.answerLikeTheGateway()
    let (probe, _) = makeProbe(for: server, tokens: [server.credential: token])

    _ = await probe.check(server.profile(model: "qwen-daily"))

    let health = server.sent.first
    #expect(health?.path == "/health")
    #expect(health?.authorization == nil)
    #expect(server.sent.dropFirst().first?.path == "/v1/models")
    #expect(server.sent.dropFirst().first?.authorization == "Bearer \(token)")
  }

  @Test("no saved key gives keyMissing, and the model list is never asked")
  func noKeyIsKeyMissing() async {
    let server = StubServer.remote()
    server.answerLikeTheGateway()
    let (probe, _) = makeProbe(for: server, tokens: [:])

    let readiness = await probe.check(server.profile(model: "qwen-daily"))

    #expect(readiness.rung == .keyMissing)
    #expect(server.sent.map(\.path) == ["/health"])
  }

  @Test("a remote profile with no key reference at all gives keyMissing")
  func noCredentialReferenceIsKeyMissing() async {
    let server = StubServer.remote()
    server.answerLikeTheGateway()
    let (probe, _) = makeProbe(for: server, tokens: [:])

    let readiness = await probe.check(server.profile(model: "qwen-daily", referencesKey: false))

    #expect(readiness.rung == .keyMissing)
    #expect(server.sent.map(\.path) == ["/health"])
  }

  @Test("a 401 gives keyRejected and drops the cached key")
  func unauthorizedIsKeyRejected() async {
    let server = StubServer.remote()
    server.answer("/health", with: .json(200, GatewayReadinessFixtures.health))
    server.answer("/v1/models", with: .json(401, GatewayReadinessFixtures.unauthorizedBody))
    let (probe, credentials) = makeProbe(for: server, tokens: [server.credential: token])

    let readiness = await probe.check(server.profile(model: "qwen-daily"))

    #expect(readiness.rung == .keyRejected)
    #expect(await credentials.invalidated == [server.credential])
  }

  @Test("an id the gateway does not list gives modelUnknown")
  func unknownIDIsModelUnknown() async {
    let server = StubServer.remote()
    server.answerLikeTheGateway()
    let (probe, _) = makeProbe(for: server, tokens: [server.credential: token])

    // Retired on 2026-08-20; the gateway answers it with 404 "no router".
    let readiness = await probe.check(server.profile(model: "qwen-turbo"))

    #expect(readiness.rung == .modelUnknown)
    #expect(readiness.observedCapabilities == nil)
  }

  @Test("an unloaded alias gives modelCold, with what the gateway says it can do")
  func unloadedIsModelCold() async {
    let server = StubServer.remote()
    server.answerLikeTheGateway()
    let (probe, _) = makeProbe(for: server, tokens: [server.credential: token])

    let ornith = await probe.check(server.profile(model: "ornith-turbo"))
    let gemma = await probe.check(server.profile(model: "gemma-write"))

    #expect(ornith.rung == .modelCold)
    #expect(ornith.observedCapabilities == .init(vision: true, tools: true))
    #expect(gemma.rung == .modelCold)
    #expect(gemma.observedCapabilities == .init(vision: false, tools: false))
  }

  @Test("the resident model gives ready, and so does an alias of its weights")
  func loadedIsReady() async {
    let server = StubServer.remote()
    server.answerLikeTheGateway()
    let (probe, _) = makeProbe(for: server, tokens: [server.credential: token])

    let daily = await probe.check(server.profile(model: "qwen-daily"))
    let uncensored = await probe.check(server.profile(model: "qwen-uncensored"))

    #expect(daily.rung == .ready)
    #expect(daily.observedCapabilities == .init(vision: true, tools: true))
    #expect(uncensored.rung == .ready)
  }

  @Test("a model list with no load state is settled by /running")
  func runningSettlesAListWithoutLoadState() async {
    let server = StubServer.remote()
    server.answer("/health", with: .json(200, GatewayReadinessFixtures.health))
    server.answer(
      "/v1/models",
      with: .json(200, GatewayReadinessFixtures.modelsWithoutLoadState)
    )
    server.answer("/running", with: .json(200, #"{"running":[]}"#))
    let (probe, _) = makeProbe(for: server, tokens: [server.credential: token])

    let notResident = await probe.check(server.profile(model: "qwen-daily"))
    server.answer("/running", with: .json(200, GatewayReadinessFixtures.running))
    let resident = await probe.check(server.profile(model: "qwen-daily"))

    #expect(notResident.rung == .modelCold)
    #expect(resident.rung == .ready)
    #expect(resident.observedCapabilities == nil)
    #expect(server.sent.filter { $0.path == "/running" }.allSatisfy { $0.authorization != nil })
  }

  @Test("a listed model on a server with neither load state nor /running is ready")
  func listedWithoutAnyLoadNotionIsReady() async {
    let server = StubServer.remote()
    server.answer("/health", with: .json(200, GatewayReadinessFixtures.health))
    server.answer(
      "/v1/models",
      with: .json(200, GatewayReadinessFixtures.modelsWithoutLoadState)
    )
    server.answer("/running", with: .json(404, "404 page not found"))
    let (probe, _) = makeProbe(for: server, tokens: [server.credential: token])

    let readiness = await probe.check(server.profile(model: "qwen-daily"))

    #expect(readiness.rung == .ready)
  }

  @Test("/running is not asked when the model list already says")
  func runningSkippedWhenListSays() async {
    let server = StubServer.remote()
    server.answerLikeTheGateway()
    let (probe, _) = makeProbe(for: server, tokens: [server.credential: token])

    _ = await probe.check(server.profile(model: "qwen-daily"))

    #expect(server.sent.map(\.path) == ["/health", "/v1/models"])
  }

  @Test("a model list that never answers gives unreachable")
  func modelListTimeoutIsUnreachable() async {
    let server = StubServer.remote()
    server.answer("/health", with: .json(200, GatewayReadinessFixtures.health))
    server.answer("/v1/models", with: .hang)
    let (probe, _) = makeProbe(for: server, tokens: [server.credential: token])

    let readiness = await probe.check(server.profile(model: "qwen-daily"))

    #expect(readiness.rung == .unreachable)
  }

  @Test("a gateway that answers 502 gives unreachable")
  func badGatewayIsUnreachable() async {
    // Gaming mode: the gateway service is stopped and Tailscale Serve answers 502.
    let server = StubServer.remote()
    server.answer("/health", with: .json(502, ""))
    let (probe, _) = makeProbe(for: server, tokens: [server.credential: token])

    let readiness = await probe.check(server.profile(model: "qwen-daily"))

    #expect(readiness.rung == .unreachable)
    #expect(server.sent.map(\.path) == ["/health"])
  }

  @Test("an endpoint off the allowlist is unreachable and is never contacted")
  func unlistedHostIsNeverContacted() async {
    let server = StubServer.remote()
    server.answerLikeTheGateway()
    let (probe, _) = makeProbe(
      for: server,
      tokens: [server.credential: token],
      allowedRemoteHosts: ["someone-else.evie.test"]
    )

    let readiness = await probe.check(server.profile(model: "qwen-daily"))

    #expect(readiness.rung == .unreachable)
    #expect(server.sent.isEmpty)
  }

  @Test("a redirect is not followed, so the key cannot go with it")
  func redirectIsNotFollowed() async {
    let server = StubServer.remote()
    server.answer("/health", with: .json(200, GatewayReadinessFixtures.health))
    server.answer("/v1/models", with: .redirect(to: "redirected.evie.test"))
    let (probe, _) = makeProbe(for: server, tokens: [server.credential: token])

    let readiness = await probe.check(server.profile(model: "qwen-daily"))

    #expect(readiness.rung == .unreachable)
    #expect(ReadinessStubURLProtocol.requests(to: "redirected.evie.test").isEmpty)
  }

  @Test("the probe never sends a POST, whatever the server answers")
  func neverPosts() async {
    let scenarios: [(StubServer) -> Void] = [
      { $0.answerLikeTheGateway() },
      {
        $0.answer("/health", with: .json(200, GatewayReadinessFixtures.health))
        $0.answer("/v1/models", with: .json(401, GatewayReadinessFixtures.unauthorizedBody))
      },
      {
        $0.answer("/health", with: .json(200, GatewayReadinessFixtures.health))
        $0.answer("/v1/models", with: .json(200, GatewayReadinessFixtures.modelsWithoutLoadState))
        $0.answer("/running", with: .json(200, GatewayReadinessFixtures.running))
      },
    ]
    var methods: [String] = []
    for scenario in scenarios {
      let server = StubServer.remote()
      scenario(server)
      let (probe, _) = makeProbe(for: server, tokens: [server.credential: token])
      for model in ["qwen-daily", "ornith-turbo", "qwen-turbo"] {
        _ = await probe.check(server.profile(model: model))
      }
      methods += server.sent.map(\.method)
    }
    let local = StubServer.loopback()
    local.answer("/health", with: .fail(.cannotConnectToHost))
    let (localProbe, _) = makeProbe(for: local, tokens: [:])
    _ = await localProbe.check(local.localProfile())
    methods += local.sent.map(\.method)

    #expect(!methods.isEmpty)
    #expect(methods.allSatisfy { $0 == "GET" })
  }

  // MARK: Local brain

  @Test("a local brain that is not running is modelCold, which a launch can fix")
  func localNotRunningIsCold() async {
    let server = StubServer.loopback()
    server.answer("/health", with: .fail(.cannotConnectToHost))
    let (probe, _) = makeProbe(for: server, tokens: [:])

    let readiness = await probe.check(server.localProfile())

    #expect(readiness.rung == .modelCold)
    #expect(server.sent.map(\.path) == ["/health"])
  }

  @Test("a local brain that answers /health with its model is ready")
  func localHealthyIsReady() async {
    let server = StubServer.loopback()
    let profile = server.localProfile()
    server.answer(
      "/health",
      with: .json(200, LocalBrainHealthFixtures.health(loadedModel: profile.model))
    )
    let (probe, _) = makeProbe(for: server, tokens: [:])

    let readiness = await probe.check(profile)

    #expect(readiness.rung == .ready)
    #expect(server.sent.map(\.path) == ["/health"])
    #expect(server.sent.first?.authorization == nil)
  }

  @Test("a local brain holding another model, or none yet, is modelCold")
  func localWithOtherModelIsCold() async {
    let server = StubServer.loopback()
    let profile = server.localProfile()
    let (probe, _) = makeProbe(for: server, tokens: [:])

    server.answer(
      "/health",
      with: .json(200, LocalBrainHealthFixtures.health(loadedModel: "some/other-model"))
    )
    let other = await probe.check(profile)
    server.answer("/health", with: .json(200, LocalBrainHealthFixtures.health(loadedModel: nil)))
    let none = await probe.check(profile)
    server.answer("/health", with: .json(200, #"{"status":"ok"}"#))
    let silent = await probe.check(profile)

    #expect(other.rung == .modelCold)
    #expect(none.rung == .modelCold)
    // A server that does not say which model it holds is taken at its word.
    #expect(silent.rung == .ready)
  }

  @Test("a local brain that never answers /health is modelCold")
  func localHangIsCold() async {
    let server = StubServer.loopback()
    server.answer("/health", with: .hang)
    let (probe, _) = makeProbe(for: server, tokens: [:])

    let readiness = await probe.check(server.localProfile())

    #expect(readiness.rung == .modelCold)
  }
}

extension ModelReadinessProbeTests {
  fileprivate func makeProbe(
    for server: StubServer,
    tokens: [CredentialReference: String],
    allowedRemoteHosts: [String]? = nil,
    localBrainKey: LocalBrainKeyFile? = nil
  ) -> (ModelReadinessProbe, RecordingCredentialProvider) {
    let configuration = URLSessionConfiguration.ephemeral
    configuration.protocolClasses = [ReadinessStubURLProtocol.self]
    let credentials = RecordingCredentialProvider(tokens: tokens)
    let probe = ModelClientFactory(
      credentials: credentials,
      transportPolicy: ModelTransportPolicy(
        allowedRemoteHosts: allowedRemoteHosts ?? [server.host]
      ),
      session: URLSession(configuration: configuration),
      // Never the real file beside brain.pid.
      localBrainKey: localBrainKey ?? LocalBrainKeyFile(
        url: FileManager.default.temporaryDirectory.appendingPathComponent("\(UUID().uuidString).key"))
    ).makeReadinessProbe(
      deadlines: ModelReadinessProbe.Deadlines(
        health: .milliseconds(200),
        catalog: .milliseconds(200)
      )
    )
    return (probe, credentials)
  }
}

// MARK: - Connection test

/// "Testar conexão": the same probe, step by step, with a time for each step.
extension ModelReadinessProbeTests {
  @Test("a ready PC passes all three steps, each with a time, and lists its models")
  func connectionTestOnAReadyGateway() async {
    let server = StubServer.remote()
    server.answerLikeTheGateway()
    let (probe, _) = makeProbe(for: server, tokens: [server.credential: token])
    let profile = server.profile(model: "qwen-daily")

    let report = await probe.connectionReport(for: profile)

    #expect(report.readiness == (await probe.check(profile)))
    #expect(report.lines.map(\.step) == [.reachable, .key, .model])
    #expect(report.lines.map(\.outcome) == [.passed, .passed, .passed])
    #expect(report.lines.allSatisfy { $0.elapsed != nil })
    #expect(
      report.availableModels == ["gemma-write", "ornith-turbo", "qwen-daily", "qwen-uncensored"]
    )
    #expect(report.summary(for: profile) == "Tudo certo: qwen-daily está carregado.")
  }

  @Test("with no saved key the key step fails, nothing carries the key, and the list is never asked")
  func connectionTestWithoutKey() async {
    let server = StubServer.remote()
    server.answerLikeTheGateway()
    let (probe, _) = makeProbe(for: server, tokens: [:])
    let profile = server.profile(model: "qwen-daily")

    let report = await probe.connectionReport(for: profile)

    #expect(report.readiness.rung == .keyMissing)
    #expect(report.lines.map(\.outcome) == [.passed, .failed, .notRun])
    #expect(report.line(.key).elapsed == nil)
    #expect(server.sent.map(\.path) == ["/health"])
    #expect(report.availableModels.isEmpty)
  }

  @Test("a refused key fails the key step after the list answered")
  func connectionTestWithRefusedKey() async {
    let server = StubServer.remote()
    server.answer("/health", with: .json(200, GatewayReadinessFixtures.health))
    server.answer("/v1/models", with: .json(401, GatewayReadinessFixtures.unauthorizedBody))
    let (probe, _) = makeProbe(for: server, tokens: [server.credential: token])
    let profile = server.profile(model: "qwen-daily")

    let report = await probe.connectionReport(for: profile)

    #expect(report.readiness.rung == .keyRejected)
    #expect(report.lines.map(\.outcome) == [.passed, .failed, .notRun])
    #expect(report.line(.key).elapsed != nil)
    #expect(report.summary(for: profile) == "O PC recusou a chave salva. Cole ou importe a chave de novo.")
  }

  @Test("a model the PC does not list fails the model step, and the list is still offered")
  func connectionTestWithUnknownModel() async {
    let server = StubServer.remote()
    server.answerLikeTheGateway()
    let (probe, _) = makeProbe(for: server, tokens: [server.credential: token])
    let profile = server.profile(model: "qwen-turbo")

    let report = await probe.connectionReport(for: profile)

    #expect(report.readiness.rung == .modelUnknown)
    #expect(report.lines.map(\.outcome) == [.passed, .passed, .failed])
    #expect(report.availableModels.contains("qwen-daily"))
    #expect(report.summary(for: profile) == "O PC não tem o modelo qwen-turbo. Escolha um da lista.")
  }

  @Test("an unloaded model fails only the model step: the first question waits for the load")
  func connectionTestWithColdModel() async {
    let server = StubServer.remote()
    server.answerLikeTheGateway()
    let (probe, _) = makeProbe(for: server, tokens: [server.credential: token])
    let profile = server.profile(model: "ornith-turbo")

    let report = await probe.connectionReport(for: profile)

    #expect(report.readiness.rung == .modelCold)
    #expect(report.lines.map(\.outcome) == [.passed, .passed, .failed])
  }

  @Test("a PC that does not answer fails the first step and runs no other")
  func connectionTestOnASilentPC() async {
    let server = StubServer.remote()
    server.answer("/health", with: .hang)
    let (probe, _) = makeProbe(for: server, tokens: [server.credential: token])
    let profile = server.profile(model: "qwen-daily")

    let report = await probe.connectionReport(for: profile)

    #expect(report.readiness.rung == .unreachable)
    #expect(report.lines.map(\.outcome) == [.failed, .notRun, .notRun])
    #expect(report.line(.reachable).elapsed != nil)
    #expect(report.summary(for: profile) == "O PC não respondeu. Ele está ligado e no Tailscale?")
  }

  @Test("a host off the allowlist fails the first step without being contacted")
  func connectionTestOffTheAllowlist() async {
    let server = StubServer.remote()
    server.answerLikeTheGateway()
    let (probe, _) = makeProbe(
      for: server,
      tokens: [server.credential: token],
      allowedRemoteHosts: ["someone.else.test"]
    )

    let report = await probe.connectionReport(for: server.profile(model: "qwen-daily"))

    #expect(report.lines.map(\.outcome) == [.failed, .notRun, .notRun])
    #expect(report.line(.reachable).elapsed == nil)
    #expect(server.sent.isEmpty)
  }

  @Test("a loopback server with no key reference shows the key step as not needed")
  func connectionTestOnALoopbackGateway() async {
    let server = StubServer.loopback()
    server.answer("/health", with: .json(200, GatewayReadinessFixtures.health))
    server.answer("/v1/models", with: .json(200, GatewayReadinessFixtures.modelsWithoutLoadState))
    server.answer("/running", with: .json(200, GatewayReadinessFixtures.running))
    let (probe, _) = makeProbe(for: server, tokens: [:])
    var profile = server.profile(model: "qwen-daily", referencesKey: false)
    profile.endpoint = URL(string: "http://\(server.authority)/v1")!

    let report = await probe.connectionReport(for: profile)

    #expect(report.readiness.rung == .ready)
    #expect(report.lines.map(\.outcome) == [.passed, .notNeeded, .passed])
    #expect(server.sent.allSatisfy { $0.authorization == nil })
  }

  @Test("a running Mac brain needs no key and passes with its model")
  func connectionTestOnARunningMacBrain() async {
    let server = StubServer.loopback()
    let profile = server.localProfile()
    server.answer(
      "/health",
      with: .json(200, LocalBrainHealthFixtures.health(loadedModel: profile.model))
    )
    let (probe, _) = makeProbe(for: server, tokens: [:])

    let report = await probe.connectionReport(for: profile)

    #expect(report.readiness.rung == .ready)
    #expect(report.lines.map(\.outcome) == [.passed, .notNeeded, .passed])
    #expect(report.title(of: .reachable, for: profile) == "Servidor do Mac rodando")
  }

  @Test("a Mac brain's /health carries its per-launch key, and the key step stays the person's")
  func macBrainHealthCarriesTheKey() async throws {
    let server = StubServer.loopback()
    let profile = server.localProfile()
    server.answer(
      "/health",
      with: .json(200, LocalBrainHealthFixtures.health(loadedModel: profile.model))
    )
    let keyFile = try LocalBrainKeyTests.temporaryKeyFile()
    let key = LocalBrainKeyFile.makeKey()
    try keyFile.write(key)
    let (probe, _) = makeProbe(for: server, tokens: [:], localBrainKey: keyFile)

    let report = await probe.connectionReport(for: profile)

    #expect(report.readiness.rung == .ready)
    // Nothing for the person to paste or import: the key is Evie's own.
    #expect(report.lines.map(\.outcome) == [.passed, .notNeeded, .passed])
    #expect(server.sent.map(\.authorization) == ["Bearer \(key)"])
  }

  @Test("a Mac brain that refuses the key is modelCold, which the launcher then checks")
  func macBrainRefusingTheKey() async throws {
    let server = StubServer.loopback()
    server.answer("/health", with: .json(401, #"{"detail":"Invalid API key"}"#))
    let (probe, _) = makeProbe(
      for: server, tokens: [:], localBrainKey: try LocalBrainKeyTests.temporaryKeyFile())

    let readiness = await probe.check(server.localProfile())

    #expect(readiness.rung == .modelCold)
  }

  @Test("a Mac brain that is not running fails the first step and is still modelCold")
  func connectionTestOnAStoppedMacBrain() async {
    let server = StubServer.loopback()
    server.answer("/health", with: .fail(.cannotConnectToHost))
    let (probe, _) = makeProbe(for: server, tokens: [:])
    let profile = server.localProfile()

    let report = await probe.connectionReport(for: profile)

    #expect(report.readiness.rung == .modelCold)
    #expect(report.lines.map(\.outcome) == [.failed, .notNeeded, .notRun])
    #expect(
      report.summary(for: profile)
        == "O cérebro do Mac não está rodando."
    )
  }

  @Test("step titles name the PC's steps in order")
  func connectionTestTitles() {
    let pc = EvieModelProfileSet.builtIn.preferredProfile
    let report = ModelConnectionReport(
      readiness: ModelReadiness(rung: .ready),
      lines: [],
      availableModels: []
    )

    #expect(
      ModelConnectionReport.Step.allCases.map { report.title(of: $0, for: pc) }
        == ["PC alcançável", "Chave aceita", "Modelo carregado"]
    )
  }

  @Test("times read in milliseconds under a second and in seconds above")
  func connectionTestTimes() {
    #expect(ModelConnectionReport.formatted(.milliseconds(37)) == "37 ms")
    #expect(ModelConnectionReport.formatted(.milliseconds(1_240)) == "1,2 s")
    #expect(ModelConnectionReport.formatted(.microseconds(400)) == "<1 ms")
  }
}

// MARK: - Cache

@Suite("Model readiness cache")
struct ModelReadinessCacheTests {
  @Test("a result is reused for 30 s and checked again after")
  func reusedForThirtySeconds() async {
    let clock = ManualInstant()
    let checks = CheckCounter(answer: .ready)
    let cache = ModelReadinessCache(now: clock.now, check: checks.check)
    let profile = EvieModelProfileSet.builtIn.preferredProfile

    _ = await cache.readiness(of: profile)
    clock.advance(by: .seconds(29))
    let reused = await cache.readiness(of: profile)
    clock.advance(by: .seconds(2))
    _ = await cache.readiness(of: profile)

    #expect(reused.rung == .ready)
    #expect(checks.count == 2)
  }

  @Test("an edited profile is checked again, not served the old result")
  func editedProfileIsCheckedAgain() async {
    let checks = CheckCounter(answer: .ready)
    let cache = ModelReadinessCache(now: ManualInstant().now, check: checks.check)
    var profile = EvieModelProfileSet.builtIn.preferredProfile

    _ = await cache.readiness(of: profile)
    profile.model = "ornith-turbo"
    _ = await cache.readiness(of: profile)

    #expect(checks.count == 2)
  }

  @Test("a refresh checks again even while the result is fresh")
  func refreshChecksAgain() async {
    let checks = CheckCounter(answer: .ready)
    let cache = ModelReadinessCache(now: ManualInstant().now, check: checks.check)
    let profile = EvieModelProfileSet.builtIn.preferredProfile

    _ = await cache.readiness(of: profile)
    await cache.refresh(profile)
    _ = await cache.readiness(of: profile)

    #expect(checks.count == 2)
  }

  @Test("callers asking at the same time share one check")
  func concurrentCallersShareOneCheck() async {
    let checks = CheckCounter(answer: .modelCold, delay: .milliseconds(50))
    let cache = ModelReadinessCache(now: ManualInstant().now, check: checks.check)
    let profile = EvieModelProfileSet.builtIn.preferredProfile

    async let first = cache.readiness(of: profile)
    async let second = cache.readiness(of: profile)
    let rungs = await [first.rung, second.rung]

    #expect(rungs == [.modelCold, .modelCold])
    #expect(checks.count == 1)
  }

  @Test("a caller waiting on a check that a refresh replaced gets the newer result")
  func waiterGetsTheRefreshedResult() async {
    let checks = CheckSequence(
      answers: [.unreachable, .ready],
      delay: .milliseconds(250)
    )
    let cache = ModelReadinessCache(now: ManualInstant().now, check: checks.check)
    let profile = EvieModelProfileSet.builtIn.preferredProfile

    async let waiting = cache.readiness(of: profile)
    // The refresh must land while the first probe is in flight, not before it.
    while checks.count == 0 {
      await Task.yield()
    }
    await cache.refresh(profile)
    let result = await waiting

    #expect(result.rung == .ready)
  }
}

// MARK: - Stubs

/// One stubbed server: a unique remote host, or a unique loopback port, and what
/// it answers at each path.
private final class StubServer: Sendable {
  let host: String
  let port: Int?

  private init(host: String, port: Int?) {
    self.host = host
    self.port = port
  }

  static func remote() -> StubServer {
    StubServer(host: "r\(UUID().uuidString.prefix(8).lowercased()).stub.evie.test", port: nil)
  }

  static func loopback() -> StubServer {
    StubServer(host: "127.0.0.1", port: ReadinessStubURLProtocol.uniquePort())
  }

  var authority: String {
    port.map { "\(host):\($0)" } ?? host
  }

  var credential: CredentialReference {
    CredentialReference(service: "test", account: authority, boundHost: host)
  }

  var sent: [ReadinessStubURLProtocol.Sent] {
    ReadinessStubURLProtocol.requests(to: authority)
  }

  func answer(_ path: String, with response: ReadinessStubURLProtocol.Response) {
    ReadinessStubURLProtocol.register(response, at: path, on: authority)
  }

  func answerLikeTheGateway() {
    answer("/health", with: .json(200, GatewayReadinessFixtures.health))
    answer("/v1/models", with: .json(200, GatewayReadinessFixtures.models))
    answer("/running", with: .json(200, GatewayReadinessFixtures.running))
  }

  func profile(model: String, referencesKey: Bool = true) -> EvieModelProfile {
    var profile = EvieModelProfileSet.builtIn.preferredProfile
    profile.endpoint = URL(string: "https://\(authority)/v1")!
    profile.model = model
    profile.credential = referencesKey ? credential : nil
    return profile
  }

  /// The Mac profile with its runtime on this stub's port, so its endpoint is
  /// the runtime's, as validation requires.
  func localProfile() -> EvieModelProfile {
    var profile = EvieModelProfileSet.builtIn.profile(id: EvieModelProfile.macProfileID)!
    if case .localOnDemand(var runtime) = profile.runtime, let port {
      runtime.port = port
      profile.runtime = .localOnDemand(runtime)
    }
    profile.endpoint = URL(string: "http://\(authority)/v1")!
    return profile
  }
}

/// Answers each request by its server and path, and remembers what it was sent.
private final class ReadinessStubURLProtocol: URLProtocol, @unchecked Sendable {
  enum Response: Sendable {
    case json(Int, String)
    case fail(URLError.Code)
    /// Never answers; only the probe's own deadline ends the request.
    case hang
    case redirect(to: String)
  }

  struct Sent: Sendable {
    let method: String
    let path: String
    let authorization: String?
  }

  private struct Registry {
    var responses: [String: [String: Response]] = [:]
    var log: [String: [Sent]] = [:]
    var nextPort = 20_000 + Int.random(in: 0..<20_000)
  }

  private static let registry = Mutex(Registry())

  static func uniquePort() -> Int {
    registry.withLock { registry in
      registry.nextPort += 1
      return registry.nextPort
    }
  }

  static func register(_ response: Response, at path: String, on authority: String) {
    registry.withLock { $0.responses[authority, default: [:]][path] = response }
  }

  static func requests(to authority: String) -> [Sent] {
    registry.withLock { $0.log[authority] ?? [] }
  }

  override class func canInit(with request: URLRequest) -> Bool {
    true
  }

  override class func canonicalRequest(for request: URLRequest) -> URLRequest {
    request
  }

  override func startLoading() {
    guard let url = request.url, let host = url.host else {
      client?.urlProtocol(self, didFailWithError: URLError(.badURL))
      return
    }
    let authority = url.port.map { "\(host):\($0)" } ?? host
    let sent = Sent(
      method: request.httpMethod ?? "GET",
      path: url.path,
      authorization: request.value(forHTTPHeaderField: "Authorization")
    )
    let response = Self.registry.withLock { registry in
      registry.log[authority, default: []].append(sent)
      return registry.responses[authority]?[url.path]
    }

    switch response {
    case .json(let status, let body):
      let reply = HTTPURLResponse(
        url: url,
        statusCode: status,
        httpVersion: "HTTP/1.1",
        headerFields: ["Content-Type": "application/json"]
      )!
      client?.urlProtocol(self, didReceive: reply, cacheStoragePolicy: .notAllowed)
      client?.urlProtocol(self, didLoad: Data(body.utf8))
      client?.urlProtocolDidFinishLoading(self)
    case .fail(let code):
      client?.urlProtocol(self, didFailWithError: URLError(code))
    case .hang:
      break
    case .redirect(let target):
      var components = URLComponents(url: url, resolvingAgainstBaseURL: false)!
      components.host = target
      let reply = HTTPURLResponse(
        url: url,
        statusCode: 302,
        httpVersion: "HTTP/1.1",
        headerFields: ["Location": components.url!.absoluteString]
      )!
      client?.urlProtocol(
        self,
        wasRedirectedTo: URLRequest(url: components.url!),
        redirectResponse: reply
      )
      client?.urlProtocol(self, didReceive: reply, cacheStoragePolicy: .notAllowed)
      client?.urlProtocolDidFinishLoading(self)
    case nil:
      let reply = HTTPURLResponse(
        url: url,
        statusCode: 404,
        httpVersion: "HTTP/1.1",
        headerFields: nil
      )!
      client?.urlProtocol(self, didReceive: reply, cacheStoragePolicy: .notAllowed)
      client?.urlProtocolDidFinishLoading(self)
    }
  }

  override func stopLoading() {}
}

/// Fixed tokens, and a record of which references were invalidated.
private actor RecordingCredentialProvider: EvieCredentialProviding {
  let tokens: [CredentialReference: String]
  private(set) var invalidated: [CredentialReference] = []

  init(tokens: [CredentialReference: String]) {
    self.tokens = tokens
  }

  func bearerToken(for reference: CredentialReference) -> String? {
    tokens[reference]
  }

  func invalidate(_ reference: CredentialReference) {
    invalidated.append(reference)
  }
}

/// A clock the test moves by hand.
private final class ManualInstant: Sendable {
  private let instant = Mutex(ContinuousClock.now)

  var now: @Sendable () -> ContinuousClock.Instant {
    { [self] in instant.withLock { $0 } }
  }

  func advance(by duration: Duration) {
    instant.withLock { $0 = $0.advanced(by: duration) }
  }
}

/// A check that always answers the same rung, and counts how often it ran.
private final class CheckCounter: Sendable {
  private let answer: ReadinessRung
  private let delay: Duration
  private let calls = Mutex(0)

  init(answer: ReadinessRung, delay: Duration = .zero) {
    self.answer = answer
    self.delay = delay
  }

  var count: Int {
    calls.withLock { $0 }
  }

  var check: @Sendable (EvieModelProfile) async -> ModelReadiness {
    { [self] _ in
      calls.withLock { $0 += 1 }
      try? await Task.sleep(for: delay)
      return ModelReadiness(rung: answer)
    }
  }
}

/// A check that answers the given rungs in order, one per run.
private final class CheckSequence: Sendable {
  private let answers: [ReadinessRung]
  private let delay: Duration
  private let calls = Mutex(0)

  init(answers: [ReadinessRung], delay: Duration) {
    self.answers = answers
    self.delay = delay
  }

  var count: Int {
    calls.withLock { $0 }
  }

  var check: @Sendable (EvieModelProfile) async -> ModelReadiness {
    { [self] _ in
      let index = calls.withLock { calls in
        defer { calls += 1 }
        return calls
      }
      try? await Task.sleep(for: delay)
      return ModelReadiness(rung: answers[min(index, answers.count - 1)])
    }
  }
}
