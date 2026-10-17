import Foundation
import Synchronization
import Testing

@testable import EvieCore

/// Which brain a conversation runs on, and where it goes when that brain is out.
///
/// No network and no keychain: keys come from a key store the test controls,
/// readiness from a `ModelReadinessCache` whose check is a table, and the Mac
/// brain from a launcher double.
@MainActor
@Suite("Evie brain resolver")
struct EvieBrainResolverTests {
  @Test("a new conversation starts on the PC when it is ready")
  func readyPCIsUsed() async {
    let harness = ResolverHarness(keys: .saved, rungs: [pc: .ready, mac: .modelCold])

    let brain = await harness.resolver.resolve(conversation: UUID())

    #expect(brain.profile.id == pc)
    #expect(brain.rung == .ready)
    #expect(brain.notice == nil)
    #expect(harness.launcher.starts == 0)
    #expect(harness.questions.isEmpty)
  }

  @Test("with no keychain item a new conversation runs on a brain that can answer")
  func missingKeyMovesToTheMac() async throws {
    let harness = ResolverHarness(keys: .none, rungs: [mac: .ready], fallback: .automatic)

    let brain = await harness.resolver.resolve(conversation: UUID())

    #expect(brain.profile.id == mac)
    #expect(brain.rung == .ready)
    #expect(
      brain.notice
        == "Sem a chave do PC — usando o Mac. Importe a chave em Configurações › Cérebro."
    )
    try brain.profile.configuration.validate()
    // The PC's key was never looked for on the network: the probe was not asked.
    #expect(!harness.probed.contains(pc))
  }

  @Test("the pin persists across turns, and a new conversation is resolved afresh")
  func pinPersists() async {
    let harness = ResolverHarness(
      keys: .none, rungs: [pc: .ready, mac: .ready], fallback: .automatic)
    let conversation = UUID()

    let first = await harness.resolver.resolve(conversation: conversation)
    harness.keys.save(pcCredential)
    let second = await harness.resolver.resolve(conversation: conversation)
    let other = await harness.resolver.resolve(conversation: UUID())

    #expect(first.profile.id == mac)
    #expect(second.profile.id == mac)
    #expect(second.notice == nil)
    #expect(other.profile.id == pc)
    #expect(harness.resolver.pinnedProfileID(for: conversation) == mac)
  }

  @Test("the brain a capture is cut for is the pinned one, else the preferred one, asked offline")
  func expectedProfileNeedsNoNetwork() async {
    let harness = ResolverHarness(
      keys: .none, rungs: [pc: .ready, mac: .ready], fallback: .automatic)
    let conversation = UUID()

    #expect(harness.resolver.expectedProfile(for: conversation).id == pc)
    _ = await harness.resolver.resolve(conversation: conversation)
    #expect(harness.resolver.expectedProfile(for: conversation).id == mac)
    #expect(harness.resolver.expectedProfile(for: UUID()).id == pc)
  }

  @Test("a pinned conversation keeps its brain even when the probe says it is out")
  func pinSurvivesABadProbe() async {
    let harness = ResolverHarness(
      keys: .saved, rungs: [pc: .ready, mac: .ready], fallback: .automatic)
    let conversation = UUID()
    _ = await harness.resolver.resolve(conversation: conversation)

    harness.rungs.set(pc, .unreachable)
    await harness.cache.refresh(EvieModelProfileSet.builtIn.preferredProfile)
    let again = await harness.resolver.resolve(conversation: conversation)

    #expect(again.profile.id == pc)
    #expect(again.rung == .unreachable)
  }

  @Test("an unreachable PC moves a new conversation to the Mac when fallback is automatic")
  func unreachablePCAutomatic() async {
    let harness = ResolverHarness(
      keys: .saved, rungs: [pc: .unreachable, mac: .modelCold], fallback: .automatic)

    let brain = await harness.resolver.resolve(conversation: UUID())

    #expect(brain.profile.id == mac)
    #expect(brain.notice == "PC indisponível, usando o Mac")
    #expect(harness.launcher.starts == 1)
    #expect(harness.questions.isEmpty)
    // Started, but the model may still load on the first request.
    #expect(brain.rung == .modelCold)
  }

  @Test(".off never moves: the PC is kept and failover surfaces the error")
  func offIsHonoured() async {
    let harness = ResolverHarness(keys: .none, rungs: [mac: .ready], fallback: .off)
    let conversation = UUID()

    let brain = await harness.resolver.resolve(conversation: conversation)
    let next = await harness.resolver.failover(
      conversation: conversation,
      after: .credentialUnavailable("nada salvo")
    )

    #expect(brain.profile.id == pc)
    #expect(brain.rung == .keyMissing)
    #expect(next == nil)
    #expect(harness.questions.isEmpty)
    #expect(harness.launcher.starts == 0)
  }

  @Test(".ask asks before waking the Mac, with the measured cost, and a no keeps the PC")
  func askDeclined() async {
    let harness = ResolverHarness(
      keys: .saved, rungs: [pc: .ready, mac: .modelCold], fallback: .ask)
    harness.answers = [false]
    let conversation = UUID()
    _ = await harness.resolver.resolve(conversation: conversation)

    let next = await harness.resolver.failover(
      conversation: conversation, after: .unreachable("gateway"))

    #expect(next == nil)
    #expect(
      harness.questions
        == ["O PC está fora. Acordar o cérebro do Mac? (~10 s, ~8 GB de memória)"]
    )
    #expect(harness.launcher.starts == 0)
    #expect(harness.resolver.pinnedProfileID(for: conversation) == pc)
  }

  @Test(".ask: after a no, a PC the cache says is out is not sent the turn, and nobody is asked twice")
  func askDeclinedForAnUnreachablePC() async throws {
    let pcClient = RecordingClient([.fail(.unreachable("gateway"))])
    let harness = ResolverHarness(
      keys: .saved,
      rungs: [pc: .unreachable, mac: .modelCold],
      fallback: .ask,
      clients: [pc: pcClient]
    )
    harness.answers = [false, false]
    let conversation = UUID()

    let brain = await harness.resolver.resolve(conversation: conversation)
    let failure = await streamFailure(brain.client)
    let next = await harness.resolver.failover(
      conversation: conversation, after: .unreachable("gateway"))

    #expect(brain.profile.id == pc)
    #expect(failure == "O PC está fora. O cérebro do Mac continua desligado, como você pediu.")
    #expect(await pcClient.calls.isEmpty)
    #expect(next == nil)
    #expect(harness.questions.count == 1)
    #expect(harness.launcher.starts == 0)
    // Nothing answered, so nothing is pinned: the next turn is resolved afresh.
    #expect(harness.resolver.pinnedProfileID(for: conversation) == nil)
  }

  @Test(".ask: a no is not taken for an outage the person was never asked about")
  func declineFailsTheTurnWithoutAFailover() async throws {
    let pcClient = RecordingClient([.fail(.unreachable("gateway"))])
    let harness = ResolverHarness(
      keys: .saved,
      rungs: [pc: .unreachable, mac: .modelCold],
      fallback: .ask,
      clients: [pc: pcClient]
    )
    harness.answers = [false, true]
    let conversation = UUID()
    let brain = await harness.resolver.resolve(conversation: conversation)

    await #expect(throws: EvieBrainUnavailable.self) {
      try await EvieBrainTurn.run(
        conversation: conversation,
        on: brain,
        resolver: harness.resolver,
        onSwitch: { _ in Issue.record("switched after a no") },
        attempt: { brain in
          for try await _ in brain.client.stream(messages: []) {}
        }
      )
    }
    #expect(harness.questions.count == 1)
    #expect(await pcClient.calls.isEmpty)
  }

  @Test(".ask: a no after a missing key fails the turn with where to import one")
  func declineAfterAMissingKey() async {
    let harness = ResolverHarness(keys: .none, rungs: [mac: .modelCold], fallback: .ask)
    harness.answers = [false]

    let brain = await harness.resolver.resolve(conversation: UUID())

    #expect(
      await streamFailure(brain.client)
        == "Sem a chave do PC. O cérebro do Mac continua desligado, como você pediu. "
        + "Importe a chave em Configurações › Cérebro."
    )
  }

  @Test(".ask: a no holds for the rest of its turn only")
  func declineLastsOneTurn() async {
    let harness = ResolverHarness(
      keys: .saved, rungs: [pc: .ready, mac: .modelCold], fallback: .ask)
    harness.answers = [false, true]
    let conversation = UUID()
    _ = await harness.resolver.resolve(conversation: conversation)

    let declined = await harness.resolver.failover(
      conversation: conversation, after: .unreachable("gateway"))
    let sameTurn = await harness.resolver.failover(
      conversation: conversation, after: .headersTimedOut)
    harness.resolver.turnEnded(conversation: conversation)
    let nextTurn = await harness.resolver.failover(
      conversation: conversation, after: .unreachable("gateway"))

    #expect(declined == nil)
    #expect(sameTurn == nil)
    #expect(nextTurn?.profile.id == mac)
    #expect(harness.questions.count == 2)
  }

  @Test(".ask: a yes wakes the Mac, re-pins, and counts for the rest of the session")
  func askAccepted() async {
    let harness = ResolverHarness(
      keys: .saved, rungs: [pc: .ready, mac: .modelCold], fallback: .ask)
    harness.answers = [true]
    let first = UUID()
    let second = UUID()
    _ = await harness.resolver.resolve(conversation: first)
    _ = await harness.resolver.resolve(conversation: second)

    let moved = await harness.resolver.failover(conversation: first, after: .headersTimedOut)
    let movedAgain = await harness.resolver.failover(conversation: second, after: .unauthorized)

    #expect(moved?.profile.id == mac)
    #expect(moved?.notice == "PC indisponível, usando o Mac")
    #expect(movedAgain?.profile.id == mac)
    #expect(harness.questions.count == 1)
    #expect(harness.resolver.pinnedProfileID(for: first) == mac)
    #expect(harness.resolver.pinnedProfileID(for: second) == mac)
  }

  @Test(".ask does not ask when the Mac brain is already answering")
  func askSkippedWhenAwake() async {
    let harness = ResolverHarness(
      keys: .saved, rungs: [pc: .unreachable, mac: .ready], fallback: .ask)

    let brain = await harness.resolver.resolve(conversation: UUID())

    #expect(brain.profile.id == mac)
    #expect(harness.questions.isEmpty)
    #expect(harness.launcher.starts == 0)
  }

  @Test("the question names the reason the PC cannot answer")
  func questionNamesTheReason() async {
    let harness = ResolverHarness(keys: .none, rungs: [mac: .modelCold], fallback: .ask)
    harness.answers = [false]

    let brain = await harness.resolver.resolve(conversation: UUID())

    #expect(brain.profile.id == pc)
    #expect(
      harness.questions
        == ["Sem a chave do PC. Acordar o cérebro do Mac? (~10 s, ~8 GB de memória)"]
    )
  }

  @Test("only failures before the first byte fail over")
  func failoverOnlyBeforeTheFirstByte() async {
    let eligible: [ModelClientError] = [
      .unreachable("gateway"), .headersTimedOut, .unauthorized,
      .credentialUnavailable("nada salvo"), .server(status: 502, message: ""),
    ]
    let final: [ModelClientError] = [
      .firstTokenTimedOut, .modelNotFound("qwen-daily"), .server(status: 500, message: ""),
      .streamEndedBeforeDone, .emptyStream, .truncated(completionTokens: 1_024),
      .requestTooLarge, .cancelled, .transportRefused("fora da lista"),
    ]
    for error in eligible {
      #expect(error.allowsFailover, "\(error)")
    }
    for error in final {
      #expect(!error.allowsFailover, "\(error)")
      let harness = ResolverHarness(
        keys: .saved, rungs: [pc: .ready, mac: .ready], fallback: .automatic)
      let conversation = UUID()
      _ = await harness.resolver.resolve(conversation: conversation)
      #expect(
        await harness.resolver.failover(conversation: conversation, after: error) == nil, "\(error)"
      )
    }
  }

  @Test("failing over asks the probe again about the brain that failed")
  func failoverRefreshesTheFailedBrain() async {
    let harness = ResolverHarness(
      keys: .saved, rungs: [pc: .ready, mac: .ready], fallback: .automatic)
    let conversation = UUID()
    _ = await harness.resolver.resolve(conversation: conversation)
    let probesBefore = harness.probed.filter { $0 == pc }.count

    harness.rungs.set(pc, .unreachable)
    _ = await harness.resolver.failover(conversation: conversation, after: .unreachable("gateway"))
    let fresh = await harness.cache.readiness(of: EvieModelProfileSet.builtIn.preferredProfile)

    #expect(harness.probed.filter { $0 == pc }.count > probesBefore)
    #expect(fresh.rung == .unreachable)
  }

  @Test("a profile the environment chose is never moved")
  func environmentChoiceIsKept() async {
    let harness = ResolverHarness(
      keys: .none,
      rungs: [mac: .ready],
      fallback: .automatic,
      environment: ["EVIE_MODEL_PROFILE": EvieModelProfile.pcProfileID]
    )
    let conversation = UUID()

    let brain = await harness.resolver.resolve(conversation: conversation)
    let next = await harness.resolver.failover(conversation: conversation, after: .unauthorized)

    #expect(brain.profile.id == pc)
    #expect(next == nil)
  }

  @Test("a Mac brain that cannot wake answers with the launcher's reason and is not pinned")
  func launcherFailure() async {
    let harness = ResolverHarness(
      keys: .saved,
      rungs: [pc: .unreachable, mac: .modelCold],
      fallback: .automatic,
      launcher: LauncherDouble(
        failure: LocalBrainLaunchError.notInstalled(executable: "/x/mlx_vlm.server"))
    )
    let conversation = UUID()

    let brain = await harness.resolver.resolve(conversation: conversation)

    #expect(brain.profile.id == mac)
    #expect(harness.resolver.pinnedProfileID(for: conversation) == nil)
    let failure = await streamFailure(brain.client)
    #expect(
      failure
        == "O PC está fora. O cérebro do Mac não está instalado: falta /x/mlx_vlm.server."
    )
  }

  @Test("the overlay is told the Mac brain is waking, and when it is done")
  func wakingIsAnnounced() async {
    let harness = ResolverHarness(
      keys: .saved, rungs: [pc: .unreachable, mac: .modelCold], fallback: .automatic)
    var states: [Bool] = []
    harness.resolver.onWaking = { states.append($0) }

    _ = await harness.resolver.resolve(conversation: UUID())

    #expect(states == [true, false])
    #expect(EvieBrainResolver.wakingStatus == "Acordando o cérebro do Mac…")
  }

  @Test("a failed wake still ends the waking state")
  func failedWakeEndsWaking() async {
    let harness = ResolverHarness(
      keys: .saved,
      rungs: [pc: .unreachable, mac: .modelCold],
      fallback: .automatic,
      launcher: LauncherDouble(failure: LocalBrainLaunchError.exitedDuringStartup)
    )
    var states: [Bool] = []
    harness.resolver.onWaking = { states.append($0) }

    _ = await harness.resolver.resolve(conversation: UUID())

    #expect(states == [true, false])
  }

  @Test("a Mac brain the probe found answering is checked before use, and not started")
  func readyMacIsVerified() async {
    let harness = ResolverHarness(
      keys: .saved, rungs: [pc: .unreachable, mac: .ready], fallback: .automatic)
    var states: [Bool] = []
    harness.resolver.onWaking = { states.append($0) }

    let brain = await harness.resolver.resolve(conversation: UUID())

    #expect(brain.profile.id == mac)
    #expect(brain.rung == .ready)
    #expect(harness.launcher.verifications == 1)
    #expect(harness.launcher.starts == 0)
    #expect(states.isEmpty)
  }

  @Test("another process on the Mac brain's port is never sent the turn")
  func foreignListenerIsRefused() async {
    let launcher = LauncherDouble()
    launcher.serving = .failure(LocalBrainLaunchError.portHeld(port: 38_480))
    let harness = ResolverHarness(
      keys: .saved,
      rungs: [pc: .unreachable, mac: .ready],
      fallback: .automatic,
      launcher: launcher
    )
    let conversation = UUID()

    let brain = await harness.resolver.resolve(conversation: conversation)

    #expect(harness.resolver.pinnedProfileID(for: conversation) == nil)
    #expect(launcher.starts == 0)
    #expect(
      await streamFailure(brain.client)
        == "O PC está fora. A porta 38480 está ocupada por outro processo."
    )
  }

  @Test(
    "a Mac turn goes to the address the launcher answers on, not to the profile's own",
    arguments: [ReadinessRung.ready, .modelCold])
  func macClientUsesTheLaunchersAddress(rung: ReadinessRung) async {
    let launched = URL(string: "http://127.0.0.1:38480/v1")!
    var moved = EvieModelProfileSet.builtIn.profile(id: EvieModelProfile.macProfileID)!
    moved.endpoint = URL(string: "http://127.0.0.1:9999/v1")!
    let launcher = LauncherDouble()
    launcher.servedEndpoint = launched
    let harness = ResolverHarness(
      keys: .saved,
      rungs: [pc: .unreachable, mac: rung],
      fallback: .automatic,
      launcher: launcher,
      profiles: [moved]
    )

    let brain = await harness.resolver.resolve(conversation: UUID())

    #expect(brain.profile.id == mac)
    #expect(brain.profile.endpoint == launched)
    #expect(brain.client.configuration.endpoint == launched)
  }

  @Test("a Mac brain that stopped since the probe saw it is woken again")
  func stoppedMacIsWoken() async {
    let launcher = LauncherDouble()
    launcher.serving = .success(false)
    let harness = ResolverHarness(
      keys: .saved,
      rungs: [pc: .unreachable, mac: .ready],
      fallback: .automatic,
      launcher: launcher
    )

    let brain = await harness.resolver.resolve(conversation: UUID())

    #expect(launcher.starts == 1)
    #expect(brain.profile.id == mac)
  }

  @Test("after a wake the rung is the probe's: ready once the model is loaded")
  func rungAfterWakeFollowsTheProbe() async {
    let harness = ResolverHarness(
      keys: .saved, rungs: [pc: .unreachable, mac: .modelCold], fallback: .automatic)
    let rungs = harness.rungs
    harness.launcher.onStart = { rungs.set(EvieModelProfile.macProfileID, .ready) }

    let brain = await harness.resolver.resolve(conversation: UUID())

    #expect(brain.rung == .ready)
  }

  @Test("every turn on the Mac brain restarts its idle clock, at the start and at the end")
  func turnsRestartTheIdleClock() async {
    let harness = ResolverHarness(
      keys: .saved, rungs: [pc: .unreachable, mac: .ready], fallback: .automatic)
    let onMac = UUID()

    _ = await harness.resolver.resolve(conversation: onMac)
    harness.resolver.turnEnded(conversation: onMac)

    #expect(harness.launcher.uses == 2)
  }

  @Test("a turn on the PC leaves the Mac brain's idle clock alone")
  func pcTurnsDoNotTouchTheMac() async {
    let harness = ResolverHarness(keys: .saved, rungs: [pc: .ready, mac: .ready])
    let onPC = UUID()

    _ = await harness.resolver.resolve(conversation: onPC)
    harness.resolver.turnEnded(conversation: onPC)
    harness.resolver.turnEnded(conversation: UUID())

    #expect(harness.launcher.uses == 0)
    #expect(harness.launcher.verifications == 0)
  }

  @Test("a settings save is picked up on the next turn, and the pin survives it")
  func adoptKeepsPins() async {
    let harness = ResolverHarness(keys: .saved, rungs: [pc: .ready, mac: .ready])
    let conversation = UUID()
    _ = await harness.resolver.resolve(conversation: conversation)

    var profiles = EvieModelProfileSet.builtIn
    try? profiles.updateProfile(id: pc) { $0.requestTimeout = 45 }
    harness.resolver.adopt(
      EvieLoadedConfiguration(profiles: profiles, activeProfile: profiles.preferredProfile),
      environment: [:]
    )
    let brain = await harness.resolver.resolve(conversation: conversation)

    #expect(brain.profile.id == pc)
    #expect(brain.profile.requestTimeout == 45)
    #expect(brain.client.configuration.requestTimeout == 45)
  }
}

// MARK: - ResolverHarness

extension EvieBrainResolverTests {
  fileprivate var pc: String { EvieModelProfile.pcProfileID }
  fileprivate var mac: String { EvieModelProfile.macProfileID }
  fileprivate var pcCredential: CredentialReference {
    EvieModelProfileSet.builtIn.preferredProfile.credential!
  }

  fileprivate func streamFailure(_ client: any AgentClient) async -> String? {
    do {
      for try await _ in client.stream(messages: []) {}
      return nil
    } catch {
      return error.localizedDescription
    }
  }
}

/// One resolver over the built-in profiles, with every dependency a double.
@MainActor
final class ResolverHarness {
  enum Keys { case none, saved }

  let keys: MutableKeys
  let rungs: RungTable
  let cache: ModelReadinessCache
  let launcher: LauncherDouble
  let resolver: EvieBrainResolver
  /// Each question the resolver asked, in order.
  private(set) var questions: [String] = []
  /// What each question is answered with, in order; an unscripted one is a no.
  var answers: [Bool] = []

  var probed: [String] { rungs.probed }

  init(
    keys: Keys,
    rungs table: [String: ReadinessRung],
    fallback: MacFallback = .ask,
    environment: [String: String] = [:],
    launcher: LauncherDouble = LauncherDouble(),
    profiles replacements: [EvieModelProfile] = [],
    clients: [String: any AgentClient] = [:]
  ) {
    let credential = EvieModelProfileSet.builtIn.preferredProfile.credential!
    self.keys = MutableKeys(saved: keys == .saved ? [credential] : [])
    rungs = RungTable(table)
    let rungs = rungs
    cache = ModelReadinessCache { profile in
      ModelReadiness(rung: rungs.check(profile.id))
    }
    self.launcher = launcher
    var profiles = EvieModelProfileSet.builtIn
    profiles.macFallback = fallback
    for replacement in replacements {
      try? profiles.updateProfile(id: replacement.id) { $0 = replacement }
    }
    let active =
      environment["EVIE_MODEL_PROFILE"].flatMap(profiles.profile(id:)) ?? profiles.preferredProfile
    let factory = ModelClientFactory(credentials: self.keys)
    resolver = EvieBrainResolver(
      configuration: EvieLoadedConfiguration(profiles: profiles, activeProfile: active),
      environment: environment,
      factory: factory,
      readiness: cache,
      localBrain: launcher,
      makeClient: { profile in
        clients[profile.id] ?? factory.makeClient(configuration: profile.configuration)
      }
    )
    resolver.askToWake = { [weak self] question in
      guard let self else { return false }
      questions.append(question.text)
      return answers.isEmpty ? false : answers.removeFirst()
    }
  }
}

/// A key store whose saved keys can change during a test, as an import would.
final class MutableKeys: EvieCredentialProviding {
  private let saved: Mutex<Set<CredentialReference>>

  init(saved: Set<CredentialReference>) {
    self.saved = Mutex(saved)
  }

  func save(_ reference: CredentialReference) {
    saved.withLock { _ = $0.insert(reference) }
  }

  func bearerToken(for reference: CredentialReference) async throws -> String? {
    saved.withLock { $0.contains(reference) } ? "test-token-not-a-secret" : nil
  }

  func invalidate(_ reference: CredentialReference) async {}
}

/// What the probe answers per profile id, and which ids it was asked about.
final class RungTable: Sendable {
  private let state: Mutex<(table: [String: ReadinessRung], probed: [String])>

  init(_ table: [String: ReadinessRung]) {
    state = Mutex((table, []))
  }

  var probed: [String] { state.withLock { $0.probed } }

  func set(_ id: String, _ rung: ReadinessRung) {
    state.withLock { $0.table[id] = rung }
  }

  func check(_ id: String) -> ReadinessRung {
    state.withLock { state in
      state.probed.append(id)
      return state.table[id] ?? .unreachable
    }
  }
}

/// A Mac launcher that counts its starts, checks and uses, and succeeds unless
/// told otherwise.
@MainActor
final class LauncherDouble: LocalBrainStarting {
  private let failure: (any Error)?
  private(set) var starts = 0
  private(set) var verifications = 0
  private(set) var uses = 0
  /// What `isServing` answers: by default the configured server is serving.
  var serving: Result<Bool, any Error> = .success(true)
  /// The address the launcher answers on; the profile's own when nil.
  var servedEndpoint: URL?
  /// Run on each start, before it returns.
  var onStart: () -> Void = {}

  nonisolated init(failure: (any Error)? = nil) {
    self.failure = failure
  }

  func ensureRunning(_ profile: EvieModelProfile) async throws -> URL {
    starts += 1
    if let failure {
      throw failure
    }
    onStart()
    return servedEndpoint ?? profile.endpoint
  }

  func isServing(_ profile: EvieModelProfile) async throws -> URL? {
    verifications += 1
    return try serving.get() ? servedEndpoint ?? profile.endpoint : nil
  }

  func noteUse() {
    uses += 1
  }
}
