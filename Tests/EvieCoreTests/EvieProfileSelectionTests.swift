import Foundation
import Testing

@testable import EvieCore

/// Which profile Evie starts on when the preferred one cannot be asked.
///
/// On 2026-10-16 the built-in PC profile pointed at a keychain item nothing had
/// created yet (`security find-generic-password` returned 44, not found), so
/// every question stopped with "no saved key" before anything was sent. Nothing
/// here touches the keychain or the network: keys come from
/// `StaticCredentialProvider`, and the selection reads only the policy and the
/// key store.
@Suite("Evie profile selection")
struct EvieProfileSelectionTests {
  @Test("with no keychain item the active profile is one that can answer")
  func noKeychainItem() async throws {
    let launched = EvieConfigurationLoader(fileURL: missingFileURL()).loadWithDiagnostics(
      environment: [:]
    )
    #expect(launched.failure == nil)
    #expect(launched.loaded.activeProfile.id == EvieModelProfile.pcProfileID)
    let selector = factory(tokens: [:]).makeProfileSelector()

    let choice = await selector.choose(launched.loaded, environment: [:])

    let active = choice.loaded.activeProfile
    #expect(active.id == EvieModelProfile.macProfileID)
    #expect(await selector.offlineRung(for: active) == nil)
    let configuration = choice.loaded.configuration
    try configuration.validate()
    #expect(
      ModelTransportPolicy().evaluate(
        configuration.chatCompletionsURL,
        credentialHost: configuration.credential?.boundHost
      ) == .allowed
    )
    #expect(choice.loaded.profiles == launched.loaded.profiles)
    #expect(choice.passedOver == .init(profileID: EvieModelProfile.pcProfileID, rung: .keyMissing))
    #expect(
      choice.notice
        == "Sem a chave do PC — usando o Mac. Importe a chave em Configurações › Cérebro."
    )
    #expect(choice.environment == ["EVIE_MODEL_PROFILE": EvieModelProfile.macProfileID])
  }

  @Test("a saved key keeps the PC, with no notice")
  func savedKeyKeepsThePC() async {
    let selector = factory(tokens: [pcCredential: "test-token-not-a-secret"]).makeProfileSelector()

    let choice = await selector.choose(.builtIn, environment: [:])

    #expect(choice.loaded == .builtIn)
    #expect(choice.passedOver == nil)
    #expect(choice.notice == nil)
    #expect(choice.environment.isEmpty)
    #expect(await selector.offlineRung(for: EvieModelProfileSet.builtIn.preferredProfile) == nil)
  }

  @Test("a keychain that cannot be read counts as a missing key")
  func unreadableKeychain() async {
    let selector = ModelClientFactory(credentials: FailingCredentials()).makeProfileSelector()

    #expect(await selector.offlineRung(for: EvieModelProfileSet.builtIn.preferredProfile) == .keyMissing)
    let choice = await selector.choose(.builtIn, environment: [:])
    #expect(choice.loaded.activeProfile.id == EvieModelProfile.macProfileID)
  }

  @Test("a profile the environment chose is kept, key or not")
  func environmentChoiceIsKept() async throws {
    let fileURL = missingFileURL()
    let selector = factory(tokens: [:]).makeProfileSelector()

    for environment in [
      ["EVIE_MODEL_PROFILE": EvieModelProfile.pcProfileID],
      ["EVIE_MODEL_NAME": "qwen-uncensored"],
    ] {
      let loaded = try EvieConfigurationLoader(fileURL: fileURL).loadProfiles(environment: environment)
      let choice = await selector.choose(loaded, environment: environment)

      #expect(choice.loaded == loaded, "\(environment)")
      #expect(choice.notice == nil, "\(environment)")
      #expect(choice.environment == environment, "\(environment)")
    }
  }

  @Test("with the Mac fallback off the PC stays, and its own error explains")
  func macFallbackOff() async {
    var profiles = EvieModelProfileSet.builtIn
    profiles.macFallback = .off
    let loaded = EvieLoadedConfiguration(profiles: profiles, activeProfile: profiles.preferredProfile)

    let choice = await factory(tokens: [:]).makeProfileSelector().choose(loaded, environment: [:])

    #expect(choice.loaded == loaded)
    #expect(choice.notice == nil)
  }

  @Test("the next profile must pass the transport policy, and with none the preferred stays")
  func nextProfileMustPassThePolicy() async {
    let offList = EvieModelProfile(
      id: "elsewhere",
      displayName: "Outro servidor",
      endpoint: URL(string: "https://evil.example/v1")!,
      model: "qwen-daily",
      contextTokens: 8_192,
      maxCompletionTokens: 1_024,
      capabilities: .init(vision: false, tools: false),
      thinkingStyle: .none,
      credential: CredentialReference(service: "test", account: "x", boundHost: "evil.example"),
      runtime: .remoteGateway,
      location: .yourPC,
      family: .qwen,
      coordinateConvention: .pixels
    )
    var profiles = EvieModelProfileSet.builtIn
    profiles.profiles.append(offList)
    profiles.preferenceOrder = [EvieModelProfile.pcProfileID, "elsewhere", EvieModelProfile.macProfileID]
    let selector = factory(tokens: [offList.credential!: "test-token-not-a-secret"])
      .makeProfileSelector()

    #expect(await selector.offlineRung(for: offList) == .unreachable)
    let skipping = await selector.choose(
      EvieLoadedConfiguration(profiles: profiles, activeProfile: profiles.preferredProfile),
      environment: [:]
    )
    #expect(skipping.loaded.activeProfile.id == EvieModelProfile.macProfileID)

    profiles.preferenceOrder = [EvieModelProfile.pcProfileID, "elsewhere"]
    let stuck = EvieLoadedConfiguration(profiles: profiles, activeProfile: profiles.preferredProfile)
    let none = await selector.choose(stuck, environment: [:])
    #expect(none.loaded == stuck)
    #expect(none.notice == nil)
  }

  @Test("after the move, a settings save edits the profile in use, not the PC")
  func settingsSaveFollowsTheMove() async throws {
    let fileURL = missingFileURL()
    let store = EvieConfigurationStore(fileURL: fileURL)
    try store.save(.builtIn)
    let loader = EvieConfigurationLoader(fileURL: fileURL)
    let choice = await factory(tokens: [:]).makeProfileSelector().choose(
      try loader.loadProfiles(environment: [:]),
      environment: [:]
    )

    _ = try store.saveActiveProfile(
      reading: loader,
      environment: choice.environment,
      otherwise: .builtIn
    ) { profile in
      profile.requestTimeout = 45
    }

    let reread = try loader.loadProfiles(environment: choice.environment)
    #expect(reread.activeProfile.id == EvieModelProfile.macProfileID)
    #expect(reread.activeProfile.requestTimeout == 45)
    #expect(
      reread.profiles.profile(id: EvieModelProfile.pcProfileID)
        == EvieModelProfileSet.builtIn.profile(id: EvieModelProfile.pcProfileID)
    )
  }

  @Test("the notice names both profiles when they are not the PC and the Mac")
  func genericNotice() {
    var gateway = EvieModelProfileSet.builtIn.preferredProfile
    gateway.displayName = "Servidor do escritório"
    var other = EvieModelProfileSet.builtIn.preferredProfile
    other.displayName = "Outro PC"

    #expect(
      EvieProfileChoice.notice(passingOver: gateway, for: other)
        == "Sem a chave de Servidor do escritório — usando Outro PC."
    )
  }
}

extension EvieProfileSelectionTests {
  fileprivate var pcCredential: CredentialReference {
    EvieModelProfileSet.builtIn.preferredProfile.credential!
  }

  fileprivate func factory(tokens: [CredentialReference: String]) -> ModelClientFactory {
    ModelClientFactory(credentials: StaticCredentialProvider(tokens: tokens))
  }

  fileprivate func missingFileURL() -> URL {
    FileManager.default.temporaryDirectory
      .appendingPathComponent(UUID().uuidString, isDirectory: true)
      .appendingPathComponent("config.json", isDirectory: false)
  }
}

/// A key store whose every read fails, as a locked or damaged keychain does.
private struct FailingCredentials: EvieCredentialProviding {
  struct Failure: Error {}

  func bearerToken(for reference: CredentialReference) async throws -> String? {
    throw Failure()
  }

  func invalidate(_ reference: CredentialReference) async {}
}
