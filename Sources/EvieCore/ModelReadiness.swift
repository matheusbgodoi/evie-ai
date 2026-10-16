import Foundation

/// How far a model endpoint is from answering, cheapest check first.
///
/// A turn carries it in `TurnOptions` so its deadlines match the model's state;
/// `ModelReadinessProbe` measures it. A turn sent with no rung keeps the
/// configured request timeout.
public enum ReadinessRung: Sendable, Equatable {
  case unreachable
  case keyMissing
  case keyRejected
  case modelUnknown
  /// Known and authorised, but not loaded: the first request will wait for the
  /// load (measured 33–45 s for qwen-daily on the PC). For a brain on this Mac it
  /// also means "not running", which the launcher can fix.
  case modelCold
  case ready
}

/// What one probe found.
public struct ModelReadiness: Sendable, Equatable {
  public let rung: ReadinessRung
  /// What the server says the model can do (`metadata.vision` and
  /// `metadata.tools` on the PC gateway), when it says both. For display and for
  /// the resolver to weigh; it never overwrites the saved profile by itself.
  public let observedCapabilities: EvieModelProfile.Capabilities?

  public init(rung: ReadinessRung, observedCapabilities: EvieModelProfile.Capabilities? = nil) {
    self.rung = rung
    self.observedCapabilities = observedCapabilities
  }
}

/// Finds out whether a profile's model can answer now, without asking it
/// anything.
///
/// Every request is a `GET`, and none of them can load a model: on the PC only a
/// chat request makes llama-swap load (and evict whatever is resident), so the
/// probe is safe to run at any moment. In order, for the PC gateway:
///
/// 1. `GET {origin}/health`, no key, 3 s. The gateway answers it itself —
///    `/v1/health` is a 404 — so it says the PC, Tailscale and gateway-edge are
///    up even while llama-swap is not. Measured 2026-10-16: 200 in 37 ms.
/// 2. `GET {endpoint}/models` with the key, 5 s. A 401 is a rejected key; the
///    entry whose `id` is the profile's model says whether it is loaded
///    (`metadata.active`, then `metadata.loadState`, then llama-swap's own
///    `status.value`) and what it can do.
/// 3. `GET {origin}/running` with the key, only when the entry says nothing
///    about loading — llama-swap without the gateway's metadata.
///
/// A brain on this Mac gets only step 1, on loopback, with its per-launch key:
/// no answer means it is not running, which is `modelCold` because the launcher
/// can start it.
///
/// Built by `ModelClientFactory`, so it obeys the same transport policy and reads
/// the same keychain as the client: nothing goes to a host the client could not
/// reach, the key goes only where the client would send it, and redirects are
/// refused so the key cannot follow one.
public struct ModelReadinessProbe: Sendable {
  public struct Deadlines: Sendable, Equatable {
    /// For `/health`: a PC that is off, asleep or in gaming mode never answers,
    /// and this is how long a turn waits to learn that.
    public var health: Duration
    /// For `/v1/models` and `/running`, which go through llama-swap.
    public var catalog: Duration

    public init(health: Duration, catalog: Duration) {
      self.health = health
      self.catalog = catalog
    }

    public static let standard = Deadlines(health: .seconds(3), catalog: .seconds(5))
  }

  private let credentials: any EvieCredentialProviding
  private let transportPolicy: ModelTransportPolicy
  private let session: URLSession
  private let deadlines: Deadlines
  private let localBrainKey: LocalBrainKeyFile

  init(
    credentials: any EvieCredentialProviding,
    transportPolicy: ModelTransportPolicy,
    session: URLSession,
    deadlines: Deadlines,
    localBrainKey: LocalBrainKeyFile
  ) {
    self.credentials = credentials
    self.transportPolicy = transportPolicy
    self.session = session
    self.deadlines = deadlines
    self.localBrainKey = localBrainKey
  }

  public func check(_ profile: EvieModelProfile) async -> ModelReadiness {
    await connectionReport(for: profile).readiness
  }

  /// The same probe, with what each step found and how long its request took:
  /// what Settings shows as "Testar conexão". `check` is this report's
  /// readiness, so the two can never disagree.
  public func connectionReport(for profile: EvieModelProfile) async -> ModelConnectionReport {
    var log = ConnectionLog()
    // `/health` carries neither the conversation nor the key, so only the
    // host-and-scheme half of the policy applies to it. A host the client could
    // never reach is not contacted at all.
    guard
      let urls = ReadinessURLs(endpoint: profile.endpoint),
      transportPolicy.evaluate(urls.health, credentialHost: urls.health.host) == .allowed
    else {
      log.record(.reachable, .failed)
      return log.report(.unreachable)
    }
    switch profile.runtime {
    case .localOnDemand(let runtime):
      return await checkLocalBrain(
        health: urls.health, port: runtime.port, model: profile.model, log: &log)
    case .remoteGateway:
      return await checkGateway(profile, urls: urls, log: &log)
    }
  }

  private func checkLocalBrain(
    health: URL,
    port: Int,
    model: String,
    log: inout ConnectionLog
  ) async -> ModelConnectionReport {
    // The person has no key to give this brain: the one it takes is Evie's
    // own, made when it started (ADR 0017), and mlx-vlm wants it on `/health`
    // too. A server that refuses it is not one Evie can use, which the
    // launcher sorts out; to the probe it is not running.
    log.record(.key, .notNeeded)
    let (answer, elapsed) = await timedGet(
      health,
      bearerToken: OpenAICompatibleClient.localBrainToken(
        for: health, port: port, from: localBrainKey),
      within: deadlines.health
    )
    guard case .answered(let status, let body) = answer, (200...299).contains(status) else {
      log.record(.reachable, .failed, after: elapsed)
      return log.report(.modelCold)
    }
    log.record(.reachable, .passed, after: elapsed)
    // mlx-vlm names the model it holds; another one, or none yet, means the
    // first request loads it. A server that does not say is taken at its word.
    switch LocalBrainHealth.loadedModel(in: body) {
    case .some(let loaded) where loaded != model:
      log.record(.model, .failed, after: elapsed)
      return log.report(.modelCold)
    default:
      log.record(.model, .passed, after: elapsed)
      return log.report(.ready)
    }
  }

  private func checkGateway(
    _ profile: EvieModelProfile,
    urls: ReadinessURLs,
    log: inout ConnectionLog
  ) async -> ModelConnectionReport {
    let (health, healthElapsed) = await timedGet(urls.health, within: deadlines.health)
    guard case .answered(let status, _) = health, (200...299).contains(status) else {
      log.record(.reachable, .failed, after: healthElapsed)
      return log.report(.unreachable)
    }
    log.record(.reachable, .passed, after: healthElapsed)

    // `/health` already passed the host-and-scheme half, so a refusal here is
    // the key half: no reference, or one saved for another host.
    guard
      transportPolicy.evaluate(urls.models, credentialHost: profile.credential?.boundHost)
        == .allowed
    else {
      log.record(.key, .failed)
      return log.report(.keyMissing)
    }
    let bearerToken: String?
    do {
      bearerToken = try await OpenAICompatibleClient.bearerToken(
        for: urls.models,
        credential: profile.credential,
        from: credentials
      )
    } catch {
      log.record(.key, .failed)
      return log.report(.keyMissing)
    }

    let (list, listElapsed) = await timedGet(
      urls.models,
      bearerToken: bearerToken,
      within: deadlines.catalog
    )
    guard case .answered(let status, let body) = list else {
      log.record(.key, .failed, after: listElapsed)
      return log.report(.unreachable)
    }
    if status == 401 || status == 403 {
      if bearerToken != nil, let credential = profile.credential {
        // As in the client: the next read goes to the keychain, where the key
        // may have been replaced.
        await credentials.invalidate(credential)
      }
      log.record(.key, .failed, after: listElapsed)
      return log.report(.keyRejected)
    }
    guard (200...299).contains(status) else {
      log.record(.key, .failed, after: listElapsed)
      return log.report(.unreachable)
    }
    // No token at this point means none applies — a loopback server with no
    // key reference — and its list answered without one.
    log.record(.key, bearerToken == nil ? .notNeeded : .passed, after: listElapsed)
    log.availableModels = GatewayModelEntry.ids(in: body)
    guard let entry = GatewayModelEntry.find(profile.model, in: body) else {
      log.record(.model, .failed, after: listElapsed)
      return log.report(.modelUnknown)
    }

    let isLoaded: Bool
    let loadElapsed: Duration
    if let stated = entry.isLoaded {
      (isLoaded, loadElapsed) = (stated, listElapsed)
    } else {
      (isLoaded, loadElapsed) = await isResident(
        entry,
        running: urls.running,
        bearerToken: bearerToken
      )
    }
    log.record(.model, isLoaded ? .passed : .failed, after: loadElapsed)
    return log.report(
      ModelReadiness(
        rung: isLoaded ? .ready : .modelCold,
        observedCapabilities: entry.capabilities
      )
    )
  }

  /// llama-swap's `/running` lists only what is resident. A server without it
  /// has no notion of loading, and a model it lists is one it serves.
  private func isResident(
    _ entry: GatewayModelEntry,
    running: URL,
    bearerToken: String?
  ) async -> (Bool, Duration) {
    let (answer, elapsed) = await timedGet(
      running,
      bearerToken: bearerToken,
      within: deadlines.catalog
    )
    guard
      case .answered(let status, let body) = answer,
      (200...299).contains(status),
      let states = RunningModels.states(in: body)
    else {
      return (true, elapsed)
    }
    let names = [entry.id, entry.physicalModelID].compactMap { $0 }
    return (names.contains { states[$0] == "ready" }, elapsed)
  }

  private enum Answer {
    case answered(status: Int, body: Data)
    case noAnswer
  }

  /// `get`, and how long it took to answer or be given up on.
  private func timedGet(
    _ url: URL,
    bearerToken: String? = nil,
    within deadline: Duration
  ) async -> (Answer, Duration) {
    let clock = ContinuousClock()
    let started = clock.now
    let answer = await get(url, bearerToken: bearerToken, within: deadline)
    return (answer, clock.now - started)
  }

  /// One `GET`, given up on at `deadline`. The idle timeout alone would not do:
  /// it is a gap between bytes, and it is the probe's own deadline that makes a
  /// silent PC cost 3 s and no more.
  private func get(
    _ url: URL,
    bearerToken: String? = nil,
    within deadline: Duration
  ) async -> Answer {
    var request = URLRequest(url: url)
    request.httpMethod = "GET"
    request.timeoutInterval = deadline.timeInterval
    request.setValue("application/json", forHTTPHeaderField: "Accept")
    if let bearerToken {
      request.setValue("Bearer \(bearerToken)", forHTTPHeaderField: "Authorization")
    }
    let session = session
    let sent = request
    return await withTaskGroup(of: Answer.self) { group in
      group.addTask {
        do {
          let (body, response) = try await session.data(for: sent, delegate: RedirectRefusal())
          guard let response = response as? HTTPURLResponse else { return .noAnswer }
          return .answered(status: response.statusCode, body: body)
        } catch {
          return .noAnswer
        }
      }
      group.addTask {
        try? await Task.sleep(for: deadline)
        return .noAnswer
      }
      let first = await group.next() ?? .noAnswer
      group.cancelAll()
      return first
    }
  }
}

extension ModelClientFactory {
  /// A probe with this factory's policy, keychain and session.
  public func makeReadinessProbe(
    deadlines: ModelReadinessProbe.Deadlines = .standard
  ) -> ModelReadinessProbe {
    ModelReadinessProbe(
      credentials: credentials,
      transportPolicy: transportPolicy,
      session: session,
      deadlines: deadlines,
      localBrainKey: localBrainKey
    )
  }
}

/// Keeps each profile's readiness for 30 s, so a turn does not pay for a probe
/// the previous turn already made.
///
/// Callers asking at the same time share one probe. `refresh` starts a new one
/// regardless — the app calls it on activation and when the network changes,
/// the two moments a cached answer is most likely wrong — and anyone still
/// waiting on the older probe gets the newer answer. A result is kept only for
/// the exact profile it was measured for, so an edited endpoint or model is
/// probed again rather than served the old answer.
public actor ModelReadinessCache {
  public static let defaultFreshness: Duration = .seconds(30)

  private struct Entry {
    let profile: EvieModelProfile
    let generation: Int
    let probe: Task<ModelReadiness, Never>
    var settledAt: ContinuousClock.Instant?
    var result: ModelReadiness?
  }

  private let freshness: Duration
  private let now: @Sendable () -> ContinuousClock.Instant
  private let check: @Sendable (EvieModelProfile) async -> ModelReadiness
  private var entries: [String: Entry] = [:]
  private var generation = 0

  public init(
    freshness: Duration = ModelReadinessCache.defaultFreshness,
    now: @escaping @Sendable () -> ContinuousClock.Instant = { .now },
    check: @escaping @Sendable (EvieModelProfile) async -> ModelReadiness
  ) {
    self.freshness = freshness
    self.now = now
    self.check = check
  }

  public init(probe: ModelReadinessProbe) {
    self.init(check: { await probe.check($0) })
  }

  /// The cached answer while it is fresh, otherwise a new probe's.
  public func readiness(of profile: EvieModelProfile) async -> ModelReadiness {
    if let entry = entries[profile.id], entry.profile == profile {
      guard let result = entry.result, let settledAt = entry.settledAt else {
        return await newestResult(for: profile)
      }
      if now() - settledAt < freshness {
        return result
      }
    }
    startProbe(of: profile)
    return await newestResult(for: profile)
  }

  /// Starts a new probe now, whatever is cached or in flight.
  public func refresh(_ profile: EvieModelProfile) {
    startProbe(of: profile)
  }

  private func startProbe(of profile: EvieModelProfile) {
    generation += 1
    let generation = generation
    let check = check
    // The probe stores its own result, so a refresh nobody awaits still
    // leaves a fresh answer for the next turn.
    let probe = Task {
      let result = await check(profile)
      self.settle(profile.id, generation: generation, with: result)
      return result
    }
    entries[profile.id] = Entry(profile: profile, generation: generation, probe: probe)
  }

  private func settle(_ id: String, generation: Int, with result: ModelReadiness) {
    guard entries[id]?.generation == generation else { return }
    entries[id]?.result = result
    entries[id]?.settledAt = now()
  }

  /// Waits for the profile's probe; if a refresh replaced it meanwhile, waits
  /// for that one instead.
  private func newestResult(for profile: EvieModelProfile) async -> ModelReadiness {
    var awaited = entries[profile.id]!
    while true {
      let result = await awaited.probe.value
      guard let current = entries[profile.id],
        current.profile == profile,
        current.generation != awaited.generation
      else {
        return result
      }
      awaited = current
    }
  }
}

/// The three addresses a probe uses, from a profile's endpoint.
private struct ReadinessURLs {
  let health: URL
  let running: URL
  let models: URL

  /// `/health` and `/running` sit at the origin; the model list sits beside
  /// `chat/completions`, under the endpoint's own path.
  init?(endpoint: URL) {
    guard var origin = URLComponents(url: endpoint, resolvingAgainstBaseURL: false) else {
      return nil
    }
    origin.query = nil
    origin.fragment = nil
    origin.path = "/health"
    guard let health = origin.url else { return nil }
    origin.path = "/running"
    guard let running = origin.url else { return nil }

    var base = endpoint
    if base.path.hasSuffix("/chat/completions") {
      base = base.deletingLastPathComponent().deletingLastPathComponent()
    }
    self.health = health
    self.running = running
    models = base.appendingPathComponent("models")
  }
}

/// One entry of the gateway's `/v1/models`, read tolerantly: the shape is
/// llama-swap's plus gateway-edge's additions, and any field may be missing or
/// of another type on another server.
struct GatewayModelEntry: Equatable {
  let id: String
  let physicalModelID: String?
  let active: Bool?
  let loadState: String?
  let statusValue: String?
  let vision: Bool?
  let tools: Bool?

  /// The states gateway-edge itself counts as resident when it derives
  /// `active` from `status.value`.
  private static let residentStates: Set<String> = ["ready", "loaded", "running"]

  /// `nil` when the entry says nothing about loading.
  var isLoaded: Bool? {
    if let active {
      return active
    }
    if let state = loadState ?? statusValue {
      return Self.residentStates.contains(state.lowercased())
    }
    return nil
  }

  var capabilities: EvieModelProfile.Capabilities? {
    guard let vision, let tools else { return nil }
    return EvieModelProfile.Capabilities(vision: vision, tools: tools)
  }

  /// Every model id the list names, in its order; empty when the body is not
  /// a model list. Settings offers these as the profile's model.
  static func ids(in body: Data) -> [String] {
    guard
      let object = try? JSONSerialization.jsonObject(with: body) as? [String: Any],
      let data = object["data"] as? [[String: Any]]
    else {
      return []
    }
    return data.compactMap { $0["id"] as? String }
  }

  /// The entry whose `id` is `model`, or `nil` when the body lists no such
  /// model or is not a model list at all.
  static func find(_ model: String, in body: Data) -> GatewayModelEntry? {
    guard
      let object = try? JSONSerialization.jsonObject(with: body) as? [String: Any],
      let data = object["data"] as? [[String: Any]],
      let entry = data.first(where: { $0["id"] as? String == model })
    else {
      return nil
    }
    let metadata = entry["metadata"] as? [String: Any] ?? [:]
    let status = entry["status"] as? [String: Any] ?? [:]
    return GatewayModelEntry(
      id: model,
      physicalModelID: metadata["physicalModelId"] as? String,
      active: metadata["active"] as? Bool,
      loadState: metadata["loadState"] as? String,
      statusValue: status["value"] as? String,
      vision: metadata["vision"] as? Bool,
      tools: metadata["tools"] as? Bool
    )
  }
}

/// llama-swap's `GET /running`: `{"running":[{"model","state",…}]}`.
enum RunningModels {
  /// Each resident model's state, or `nil` when the body is not that shape.
  static func states(in body: Data) -> [String: String]? {
    guard
      let object = try? JSONSerialization.jsonObject(with: body) as? [String: Any],
      let running = object["running"] as? [[String: Any]]
    else {
      return nil
    }
    var states: [String: String] = [:]
    for model in running {
      if let name = model["model"] as? String, let state = model["state"] as? String {
        states[name] = state
      }
    }
    return states
  }
}

/// A local brain's `GET /health`. mlx-vlm 0.7.8 answers
/// `{"status":"healthy","loaded_model":…,…}`.
enum LocalBrainHealth {
  /// `.some(nil)` when the server says it holds no model yet, `nil` when it
  /// does not say.
  static func loadedModel(in body: Data) -> String?? {
    guard
      let object = try? JSONSerialization.jsonObject(with: body) as? [String: Any],
      let loaded = object["loaded_model"]
    else {
      return nil
    }
    return .some(loaded as? String)
  }
}

extension Duration {
  fileprivate var timeInterval: TimeInterval {
    let (seconds, attoseconds) = components
    return TimeInterval(seconds) + TimeInterval(attoseconds) / 1e18
  }
}
