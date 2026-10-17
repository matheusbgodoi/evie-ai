import Foundation

/// The profile Evie starts on, and why it is not the preferred one when it is
/// not.
public struct EvieProfileChoice: Sendable, Equatable {
  /// A profile left out of the choice, and what ruled it out.
  public struct PassedOver: Sendable, Equatable {
    public let profileID: String
    public let rung: ReadinessRung

    public init(profileID: String, rung: ReadinessRung) {
      self.profileID = profileID
      self.rung = rung
    }
  }

  /// The loaded set with `activeProfile` set to the choice.
  public let loaded: EvieLoadedConfiguration
  /// The preferred profile, when the choice moved past it.
  public let passedOver: PassedOver?
  /// The environment that resolves to the choice: unchanged when it did not
  /// move, otherwise with `EVIE_MODEL_PROFILE` pinned to it, so a settings save
  /// and its reload edit and read the profile actually in use rather than the
  /// preferred one.
  public let environment: [String: String]
  /// What to tell the person when the choice moved; nil when it did not.
  public let notice: String?

  /// The notice for starting on `chosen` because `skipped` has no usable key.
  public static func notice(
    passingOver skipped: EvieModelProfile,
    for chosen: EvieModelProfile
  ) -> String {
    switch (skipped.location, chosen.location) {
    case (.yourPC, .thisMac):
      "Sem a chave do PC — usando o Mac. Importe a chave em Configurações › Cérebro."
    default:
      "Sem a chave de \(skipped.displayName) — usando \(chosen.displayName)."
    }
  }
}

/// Chooses the profile Evie starts on: the preferred one, unless it needs a key
/// that is not saved, in which case the next profile in the preference order
/// that nothing rules out before sending.
///
/// Before this, a fresh install answered nothing: the preferred profile is the
/// PC, its key lives in a keychain item only the key import (v2 S2d) creates,
/// and the client refuses to send without it. Moving on is better than a
/// refusal per question, and the notice says how to get the PC back.
///
/// Only what is known **without the network** is weighed — the transport policy
/// and the key store — so the choice costs a keychain read and can be made at
/// launch. An unreachable PC, a rejected key or a cold model are the readiness
/// probe's findings, and acting on them per conversation is the per-turn
/// resolver's job.
///
/// Since v2 S2c the app no longer calls `choose`: `EvieBrainResolver` makes
/// this decision per conversation, starting from `offlineRung` and the same
/// preference walk, with the cached probe and `macFallback` — including the
/// `.ask` question — on top. `choose` stays the network-free form of that walk.
///
/// The preferred profile is kept, key or not, when:
/// - the environment chose it — `EVIE_MODEL_PROFILE`, or any `EVIE_MODEL_*`
///   override, which applies to the preferred profile and would not fit another;
/// - `macFallback` is `.off`: the person asked never to be moved, and the
///   client's own "no saved key" error explains what to do.
///
/// `.ask` moves without asking here, because nothing here wakes anything. The
/// resolver asks before waking the Mac brain, whatever the reason the PC was
/// passed over.
public struct EvieProfileSelector: Sendable {
  private let credentials: any EvieCredentialProviding
  private let transportPolicy: ModelTransportPolicy

  init(credentials: any EvieCredentialProviding, transportPolicy: ModelTransportPolicy) {
    self.credentials = credentials
    self.transportPolicy = transportPolicy
  }

  /// What rules a profile out before anything is sent, or nil when nothing
  /// does. `.unreachable`: the policy refuses its host or scheme outright.
  /// `.keyMissing`: its key applies but has no reference, is bound to another
  /// host, is not saved, or the keychain could not be read — the same rule the
  /// client and the readiness probe use, so the three cannot disagree.
  public func offlineRung(for profile: EvieModelProfile) async -> ReadinessRung? {
    let url = profile.configuration.chatCompletionsURL
    guard transportPolicy.evaluate(url, credentialHost: url.host) == .allowed else {
      return .unreachable
    }
    guard
      transportPolicy.evaluate(url, credentialHost: profile.credential?.boundHost) == .allowed
    else {
      return .keyMissing
    }
    do {
      _ = try await OpenAICompatibleClient.bearerToken(
        for: url,
        credential: profile.credential,
        from: credentials
      )
    } catch {
      return .keyMissing
    }
    return nil
  }

  /// The profile to start on, from what the loader resolved and the
  /// environment it resolved it with.
  public func choose(
    _ loaded: EvieLoadedConfiguration,
    environment: [String: String]
  ) async -> EvieProfileChoice {
    let kept = EvieProfileChoice(
      loaded: loaded,
      passedOver: nil,
      environment: environment,
      notice: nil
    )
    guard !Self.environmentChoseTheProfile(environment),
      loaded.profiles.macFallback != .off,
      await offlineRung(for: loaded.activeProfile) == .keyMissing
    else {
      return kept
    }

    let preferred = loaded.activeProfile
    for id in loaded.profiles.preferenceOrder where id != preferred.id {
      guard let candidate = loaded.profiles.profile(id: id),
        (try? candidate.configuration.validate()) != nil,
        await offlineRung(for: candidate) == nil
      else {
        continue
      }
      var pinned = environment
      pinned["EVIE_MODEL_PROFILE"] = candidate.id
      return EvieProfileChoice(
        loaded: EvieLoadedConfiguration(profiles: loaded.profiles, activeProfile: candidate),
        passedOver: .init(profileID: preferred.id, rung: .keyMissing),
        environment: pinned,
        notice: EvieProfileChoice.notice(passingOver: preferred, for: candidate)
      )
    }
    return kept
  }

  /// Whether a variable picked the profile or edited it for this run.
  /// `EVIE_CONFIG_FILE` only picks the file.
  static func environmentChoseTheProfile(_ environment: [String: String]) -> Bool {
    environment.contains { name, value in
      name.hasPrefix("EVIE_MODEL_") && !value.isEmpty
    }
  }
}

extension ModelClientFactory {
  /// A selector with this factory's policy and key store, so it rules out
  /// exactly what this factory's clients would refuse.
  public func makeProfileSelector() -> EvieProfileSelector {
    EvieProfileSelector(credentials: credentials, transportPolicy: transportPolicy)
  }
}
