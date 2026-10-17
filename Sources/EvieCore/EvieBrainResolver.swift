import Foundation

/// The brain one turn runs on, decided before the turn builds anything.
public struct ResolvedBrain: Sendable {
  public let profile: EvieModelProfile
  public let client: any AgentClient
  /// What the key store or the readiness probe last said about it. The turn
  /// carries it in `TurnOptions`, so its deadlines match the model's state.
  public let rung: ReadinessRung
  /// What to tell the person about the choice — that the preferred brain was
  /// passed over, and why — or nil when there is nothing to say.
  public let notice: String?

  public init(
    profile: EvieModelProfile, client: any AgentClient, rung: ReadinessRung, notice: String?
  ) {
    self.profile = profile
    self.client = client
    self.rung = rung
    self.notice = notice
  }
}

/// What is asked before waking a brain on this Mac for a turn the preferred one
/// cannot take, when the Mac fallback is `.ask`.
public struct EvieBrainWakeQuestion: Sendable, Equatable {
  public let passingOver: EvieModelProfile
  public let reason: ReadinessRung
  public let candidate: EvieModelProfile

  /// "O PC está fora. Acordar o cérebro do Mac? (~10 s, ~8 GB de memória)".
  public var text: String {
    EvieBrainCopy.wakeQuestion(passingOver: passingOver, because: reason, waking: candidate)
  }
}

/// Decides, per conversation, which profile answers.
///
/// It runs before a turn builds its prompt, because everything a turn builds
/// depends on the answer: the character budget, the persona's "where you run",
/// whether tools are declared and whether pictures are sent. A switch inside
/// `stream()` would come after all of that was fixed for the wrong brain.
///
/// **A conversation is pinned** to the profile its first turn ran on and never
/// moves mid-thread: a history written by one model and continued by another
/// reads as two people, and the Mac's 32K budget would silently drop most of a
/// PC conversation. The pin lives in memory, for the app session.
///
/// **A new conversation** starts on the preferred profile (the loader's choice:
/// `EVIE_MODEL_PROFILE` or the preference order) unless it cannot answer —
/// a key that is not saved (known without the network, `EvieProfileSelector`'s
/// `offlineRung`), or the cached probe finding it unreachable, its key refused
/// or its model unknown. Then it walks the preference order for one that can.
///
/// **Failover** happens only when a turn failed before its first delta (see
/// `ModelClientError.allowsFailover`): the caller rebuilds the turn for the new
/// profile and tries once more. After a delta the text is on screen, and a
/// second model cannot continue it. There is no failover for a slow load, nor
/// to another alias on the PC, since loading one evicts `qwen-daily`.
///
/// **Moving at all** follows `macFallback`: `.off` never moves, `.automatic`
/// moves, and `.ask` asks before waking a brain on this Mac — it costs memory
/// the person may be using — and a yes holds for the rest of the app session. A
/// no holds for the rest of that conversation's turn: the card is not shown a
/// second time when the turn it refused then fails over, and a turn whose
/// preferred brain the cache already knows cannot answer fails with the reason
/// instead of being sent there. A profile the environment chose is never
/// moved: someone asked for it by name.
///
/// **A choice** from the overlay's brain chip (`choose(_:)`) narrows the
/// preference order to one place for every conversation not yet pinned —
/// "Sempre o PC" is the order without the Mac. It is made after launch, by the
/// person, so it wins over the environment's profile; the conversation on
/// screen keeps its pin. Choosing the Mac is the consent to wake it, so
/// nothing is asked. In memory, for the app session, like the pins.
@MainActor
public final class EvieBrainResolver {
  /// The profiles in use and the preferred one, with environment overrides.
  public private(set) var configuration: EvieLoadedConfiguration
  /// Asked before waking the Mac brain; nobody to ask is a no.
  public var askToWake: @MainActor (EvieBrainWakeQuestion) async -> Bool = { _ in false }
  /// Told `true` when the Mac brain starts waking for a turn and `false` once
  /// it answers or failed to, so the overlay can say "Acordando o cérebro do
  /// Mac…" through a start that takes seconds.
  public var onWaking: @MainActor (Bool) -> Void = { _ in }

  /// What the overlay shows while the Mac brain wakes.
  public static let wakingStatus = "Acordando o cérebro do Mac…"

  private var environmentChoseProfile: Bool
  private let selector: EvieProfileSelector
  private let readiness: ModelReadinessCache
  private let localBrain: any LocalBrainStarting
  private let makeClient: @Sendable (EvieModelProfile) -> any AgentClient
  private var pins: [UUID: String] = [:]
  /// The chip's choice; `.automatic` is the preference order as saved.
  public private(set) var choice: EvieBrainChoice = .automatic
  private var wakeAccepted = false
  /// Conversations whose current turn was answered "Agora não".
  private var wakeDeclined: Set<UUID> = []

  public convenience init(
    configuration: EvieLoadedConfiguration,
    environment: [String: String],
    factory: ModelClientFactory,
    readiness: ModelReadinessCache,
    localBrain: any LocalBrainStarting
  ) {
    self.init(
      configuration: configuration,
      environment: environment,
      factory: factory,
      readiness: readiness,
      localBrain: localBrain,
      makeClient: { factory.makeClient(configuration: $0.configuration) }
    )
  }

  init(
    configuration: EvieLoadedConfiguration,
    environment: [String: String],
    factory: ModelClientFactory,
    readiness: ModelReadinessCache,
    localBrain: any LocalBrainStarting,
    makeClient: @escaping @Sendable (EvieModelProfile) -> any AgentClient
  ) {
    self.configuration = configuration
    environmentChoseProfile = EvieProfileSelector.environmentChoseTheProfile(environment)
    selector = factory.makeProfileSelector()
    self.readiness = readiness
    self.localBrain = localBrain
    self.makeClient = makeClient
  }

  /// Takes the profiles a settings save produced. Pins are kept: a pinned
  /// conversation gets its profile's new values on its next turn.
  public func adopt(_ configuration: EvieLoadedConfiguration, environment: [String: String]) {
    self.configuration = configuration
    environmentChoseProfile = EvieProfileSelector.environmentChoseTheProfile(environment)
  }

  /// The profile a conversation is pinned to, if any.
  public func pinnedProfileID(for conversation: UUID) -> String? {
    pins[conversation]
  }

  /// Where a conversation with no pin yet would start, known without the
  /// network.
  public var newConversationProfile: EvieModelProfile {
    preferredProfile
  }

  /// The profile a conversation is pinned to, with its current values.
  public func pinnedProfile(for conversation: UUID) -> EvieModelProfile? {
    pins[conversation].flatMap(profile(id:))
  }

  /// Narrows where conversations without a pin start. A place with no
  /// profile cannot be chosen (`canChoose(_:)`); asking for one changes
  /// nothing.
  public func choose(_ choice: EvieBrainChoice, for conversation: UUID? = nil) {
    guard canChoose(choice) else {
      return
    }
    self.choice = choice
    if let conversation {
      pins.removeValue(forKey: conversation)
      wakeDeclined.remove(conversation)
    }
  }

  /// Whether some profile runs where `choice` points.
  public func canChoose(_ choice: EvieBrainChoice) -> Bool {
    choice.location == nil || !profiles(allowedBy: choice).isEmpty
  }

  /// The brain the conversation's next turn goes to and what is known about
  /// it now: the key store, then the cached probe (which probes when stale).
  /// For the chip, which must never wait on more than the probe does.
  public func status(for conversation: UUID) async -> (
    profile: EvieModelProfile, rung: ReadinessRung
  ) {
    let profile = expectedProfile(for: conversation)
    return (profile, await rung(of: profile))
  }

  /// `status(for:)` after a fresh probe, whatever the cache held: the chip's
  /// "Testar conexão".
  public func checkConnection(for conversation: UUID) async -> (
    profile: EvieModelProfile, rung: ReadinessRung
  ) {
    let profile = expectedProfile(for: conversation)
    if await selector.offlineRung(for: profile) == nil {
      await readiness.refresh(profile)
    }
    return (profile, await rung(of: profile))
  }

  /// The brain a conversation's next turn most likely runs on — its pin, or
  /// the preferred profile — known without the network. A screen capture is
  /// cut for it before the turn resolves, because the capture must show the
  /// screen as it was when asked, not after a probe or a wake.
  public func expectedProfile(for conversation: UUID) -> EvieModelProfile {
    pins[conversation].flatMap(profile(id:)) ?? preferredProfile
  }

  /// A turn on the conversation ended. When it ran on the Mac brain, the
  /// brain's idle clock starts from now rather than from the turn's start, so
  /// a long answer does not count as idle time.
  public func turnEnded(conversation: UUID) {
    wakeDeclined.remove(conversation)
    guard let pinned = pins[conversation].flatMap(profile(id:)), pinned.startsOnDemand else {
      return
    }
    localBrain.noteUse()
  }

  /// The brain for the conversation's next turn.
  public func resolve(conversation: UUID) async -> ResolvedBrain {
    if let pinned = pins[conversation].flatMap(profile(id:)) {
      return await prepare(pinned, rung: await rung(of: pinned), for: conversation)
    }
    let preferred = preferredProfile
    let preferredRung = await rung(of: preferred)
    if !preferredRung.isAnswerable, mayMove {
      if let moved = await move(conversation, from: preferred, because: preferredRung) {
        return moved
      }
      if wakeDeclined.contains(conversation) {
        // He was told the PC cannot answer and chose not to wake the Mac;
        // sending the turn there anyway would only fail the same way, after
        // the network's own timeout.
        return unavailable(
          preferred,
          rung: preferredRung,
          because: EvieBrainCopy.declinedWake(passingOver: preferred, because: preferredRung)
        )
      }
    }
    return await prepare(preferred, rung: preferredRung, for: conversation)
  }

  /// The next brain after a turn on the conversation's brain failed with
  /// `error`, re-pinned to it, or nil when the error is final, moving is not
  /// allowed, or nothing else can answer.
  public func failover(conversation: UUID, after error: ModelClientError) async -> ResolvedBrain? {
    guard error.allowsFailover, mayMove else {
      return nil
    }
    let failed = pins[conversation].flatMap(profile(id:)) ?? preferredProfile
    // Whatever the cache said about it was just proved wrong.
    await readiness.refresh(failed)
    return await move(conversation, from: failed, because: EvieBrainCopy.reason(for: error))
  }

  /// A chosen place moves only within itself, so neither the environment nor
  /// `macFallback` — which is about moving to the Mac — stops it.
  private var mayMove: Bool {
    choice != .automatic
      || (!environmentChoseProfile && configuration.profiles.macFallback != .off)
  }

  /// Where a conversation without a pin starts: the loader's profile, or under
  /// a choice the first profile of the narrowed order.
  private var preferredProfile: EvieModelProfile {
    guard choice != .automatic else {
      return configuration.activeProfile
    }
    return profiles(allowedBy: choice).first ?? configuration.activeProfile
  }

  /// The preference order narrowed to `choice`, followed by any profile in
  /// that place the order does not name (a migrated `custom`), so a place with
  /// a profile can always be chosen.
  private func profiles(allowedBy choice: EvieBrainChoice) -> [EvieModelProfile] {
    let set = configuration.profiles
    let ordered = set.preferenceOrder.compactMap(profile(id:))
    let unordered = set.profiles.filter { !set.preferenceOrder.contains($0.id) }
      .compactMap { profile(id: $0.id) }
    return (ordered + unordered).filter(choice.allows)
  }

  /// The first profile after `failed` in the preference order that can answer,
  /// with the person's consent where waking it needs one.
  private func move(
    _ conversation: UUID,
    from failed: EvieModelProfile,
    because reason: ReadinessRung
  ) async -> ResolvedBrain? {
    for id in configuration.profiles.preferenceOrder where id != failed.id {
      guard let candidate = profile(id: id), choice.allows(candidate),
        await selector.offlineRung(for: candidate) == nil
      else {
        continue
      }
      let rung = await readiness.readiness(of: candidate).rung
      guard rung.isAnswerable else {
        continue
      }
      if needsConsent(toWake: candidate, rung: rung) {
        // Asked once a turn: the answer stands until the turn ends.
        guard !wakeDeclined.contains(conversation) else {
          continue
        }
        let question = EvieBrainWakeQuestion(
          passingOver: failed, reason: reason, candidate: candidate)
        guard await askToWake(question) else {
          wakeDeclined.insert(conversation)
          continue
        }
        wakeAccepted = true
      }
      return await prepare(candidate, rung: rung, for: conversation, passingOver: (failed, reason))
    }
    return nil
  }

  /// Asked only to wake: a brain on this Mac that already answers costs nothing
  /// more, and the PC is never "woken".
  private func needsConsent(toWake candidate: EvieModelProfile, rung: ReadinessRung) -> Bool {
    choice != .alwaysMac && configuration.profiles.macFallback == .ask && !wakeAccepted
      && candidate.startsOnDemand && rung != .ready
  }

  /// Makes sure a Mac brain is the configured server and is serving — starting
  /// it when it is not — then pins the conversation. A brain that cannot be
  /// used is returned with a client that fails with the reason, and nothing is
  /// pinned to it: a conversation that has no pin yet is resolved from the top
  /// again on its next turn.
  private func prepare(
    _ profile: EvieModelProfile,
    rung: ReadinessRung,
    for conversation: UUID,
    passingOver skipped: (profile: EvieModelProfile, reason: ReadinessRung)? = nil
  ) async -> ResolvedBrain {
    var profile = profile
    var rung = rung
    if profile.startsOnDemand {
      do {
        let served = try await wakeIfNeeded(profile, rung: rung)
        // The turn goes where the launcher checked who listens, whatever the
        // profile says; the two agree for every profile that validates.
        profile.endpoint = served.endpoint
        rung = served.rung
        localBrain.noteUse()
      } catch {
        let reason = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
        let message =
          skipped.map {
            EvieBrainCopy.reasonSentence(passingOver: $0.profile, because: $0.reason) + " " + reason
          } ?? reason
        return unavailable(profile, rung: rung, because: message)
      }
    }
    pins[conversation] = profile.id
    return ResolvedBrain(
      profile: profile,
      client: makeClient(profile),
      rung: rung,
      notice: skipped.map {
        EvieBrainCopy.notice(passingOver: $0.profile, because: $0.reason, for: profile)
      }
    )
  }

  /// A brain whose every request fails with `message`, sending nothing, and
  /// with nothing pinned to it.
  private func unavailable(
    _ profile: EvieModelProfile, rung: ReadinessRung, because message: String
  )
    -> ResolvedBrain
  {
    ResolvedBrain(
      profile: profile,
      client: UnavailableBrainClient(
        configuration: profile.configuration,
        failure: EvieBrainUnavailable(message: message)
      ),
      rung: rung,
      notice: nil
    )
  }

  /// Where a Mac brain answers and its rung, once it is known to be the
  /// configured server and serving. The probe's "ready" only says that
  /// something answered `/health` on the port, so who answered is checked
  /// first; a brain that stopped since the probe (its idle timer, a crash) is
  /// woken again.
  private func wakeIfNeeded(_ profile: EvieModelProfile, rung: ReadinessRung) async throws
    -> (endpoint: URL, rung: ReadinessRung)
  {
    if rung == .ready, let endpoint = try await localBrain.isServing(profile) {
      return (endpoint, .ready)
    }
    onWaking(true)
    defer { onWaking(false) }
    let endpoint = try await localBrain.ensureRunning(profile)
    await readiness.refresh(profile)
    // The launcher names the model on the command line, so it is loaded once
    // `/health` answers; a probe that says otherwise leaves the cold
    // deadlines in place for the first request.
    let probed = await readiness.readiness(of: profile).rung
    return (endpoint, probed == .ready ? .ready : .modelCold)
  }

  /// The key store first, since it needs no network and a missing key makes
  /// the probe's answer moot; then the cached probe.
  private func rung(of profile: EvieModelProfile) async -> ReadinessRung {
    if let offline = await selector.offlineRung(for: profile) {
      return offline
    }
    return await readiness.readiness(of: profile).rung
  }

  /// The preferred profile is the loader's, with its environment overrides;
  /// every other one is the file's.
  private func profile(id: String) -> EvieModelProfile? {
    id == configuration.activeProfile.id
      ? configuration.activeProfile
      : configuration.profiles.profile(id: id)
  }
}

/// Why a brain could not be used, said as it is to the person.
public struct EvieBrainUnavailable: LocalizedError, Equatable, Sendable {
  public let message: String

  public init(message: String) {
    self.message = message
  }

  public var errorDescription: String? { message }
}

extension ReadinessRung {
  /// A brain a request can be sent to now: loaded, or one the request (or the
  /// launcher) will load.
  var isAnswerable: Bool {
    self == .ready || self == .modelCold
  }
}

extension EvieModelProfile {
  var startsOnDemand: Bool {
    if case .localOnDemand = runtime { true } else { false }
  }
}

/// The words the resolver uses, in one place.
enum EvieBrainCopy {
  /// Measured 2026-10-16 on this Mac (M5, 24 GB, macOS 27.2): LensVLM under
  /// `mlx_vlm.server` 0.7.8 holds 8,164 MB (10 GB at peak) and gave its first
  /// text answer 6.69 s after the request. Started by `Scripts/evie-brain`
  /// with the model in the page cache, `/health` answered 5.4 s after launch
  /// and a tiny-image answer took 2.2 s more. The spec's "~90 s" was an
  /// estimate for a launcher that did not exist yet.
  static let macWakeCost = "(~10 s, ~8 GB de memória)"

  static func wakeQuestion(
    passingOver skipped: EvieModelProfile,
    because reason: ReadinessRung,
    waking candidate: EvieModelProfile
  ) -> String {
    let brain = candidate.location == .thisMac ? "o cérebro do Mac" : candidate.displayName
    return reasonSentence(passingOver: skipped, because: reason)
      + " Acordar \(brain)? \(macWakeCost)"
  }

  /// One sentence on why the profile cannot answer.
  static func reasonSentence(passingOver skipped: EvieModelProfile, because reason: ReadinessRung)
    -> String
  {
    let isPC = skipped.location == .yourPC
    let subject = isPC ? "O PC" : skipped.displayName
    switch reason {
    case .keyMissing:
      return isPC ? "Sem a chave do PC." : "Sem a chave de \(skipped.displayName)."
    case .keyRejected:
      return "\(subject) recusou a chave."
    case .modelUnknown:
      return "\(subject) não tem o modelo configurado."
    case .unreachable, .modelCold, .ready:
      return "\(subject) está fora."
    }
  }

  /// Why a turn fails when the preferred brain cannot answer and the person
  /// chose not to wake the one that could: "O PC está fora. O cérebro do Mac
  /// continua desligado, como você pediu." A missing PC key also says where
  /// to put one.
  static func declinedWake(passingOver skipped: EvieModelProfile, because reason: ReadinessRung)
    -> String
  {
    let fix =
      reason == .keyMissing && skipped.location == .yourPC
      ? " Importe a chave em Configurações › Cérebro." : ""
    return reasonSentence(passingOver: skipped, because: reason)
      + " O cérebro do Mac continua desligado, como você pediu." + fix
  }

  /// The status line after a move.
  static func notice(
    passingOver skipped: EvieModelProfile,
    because reason: ReadinessRung,
    for chosen: EvieModelProfile
  ) -> String {
    if reason == .keyMissing {
      return EvieProfileChoice.notice(passingOver: skipped, for: chosen)
    }
    switch (skipped.location, chosen.location) {
    case (.yourPC, .thisMac):
      return "PC indisponível, usando o Mac"
    default:
      return "\(skipped.displayName) indisponível, usando \(chosen.displayName)."
    }
  }

  /// The rung a failed request stands for.
  static func reason(for error: ModelClientError) -> ReadinessRung {
    switch error {
    case .unauthorized: .keyRejected
    case .credentialUnavailable: .keyMissing
    default: .unreachable
    }
  }
}
