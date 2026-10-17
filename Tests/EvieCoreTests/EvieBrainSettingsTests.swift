import Foundation
import Testing

@testable import EvieCore

/// What the "Cérebro" settings tab decides: the copy it shows per profile, the
/// edits a draft makes to a profile, the endpoint check, and the save that
/// writes the whole set.
@Suite("Brain settings")
struct EvieBrainSettingsTests {
  private let pc = EvieModelProfileSet.builtIn.preferredProfile
  private let mac = EvieModelProfileSet.builtIn.profile(id: EvieModelProfile.macProfileID)!

  // MARK: Copy

  @Test("editing a label preserves a larger existing server window")
  func unrelatedEditPreservesServerWindow() throws {
    var configured = mac
    configured.contextTokens = 32_768
    if case .localOnDemand(var runtime) = configured.runtime {
      runtime.maxKVSize = 65_536
      configured.runtime = .localOnDemand(runtime)
    }
    var draft = EvieProfileDraft(configured)
    draft.displayName = "Minha Evie local"
    let changed = try draft.applied(to: configured)
    #expect(changed.runtime == configured.runtime)
    #expect(changed.contextTokens == configured.contextTokens)
  }

  @Test("changing local context changes the launched server capacity too")
  func localContextUpdatesRuntime() throws {
    var configured = mac
    configured.serverContextTokens = 65_536
    var draft = EvieProfileDraft(configured)
    draft.contextTokens = 65_536
    let changed = try draft.applied(to: configured)
    guard case .localOnDemand(let runtime) = changed.runtime else {
      Issue.record("The local runtime was lost")
      return
    }
    #expect(runtime.maxKVSize == 65_536)
    #expect(changed.contextTokens == runtime.maxKVSize)
  }

  @Test("sampling recipes belong to the actual model family")
  func modelSamplingRecipes() {
    let pc = EvieModelProfile.builtInPC.recommendedSampling
    #expect(pc.temperature == nil && pc.topP == nil)
    let lens = EvieModelProfile.builtInMac.recommendedSampling
    #expect(lens.temperature == 0 && lens.topP == 1)
    var unknown = EvieModelProfile.builtInPC
    unknown.model = "my-other-model"
    #expect(unknown.recommendedSampling.temperature == EvieProfileDraft.recommendedTemperature)
  }

  @Test("the context line gives the server's figure and the cap Evie uses")
  func contextLine() {
    var unlabelled = pc
    unlabelled.serverContextTokens = nil
    unlabelled.contextTokens = 65_536

    // A no-break space between the groups, so the figure never wraps in two.
    #expect(pc.contextLine == "servidor: 200\u{A0}704 · Evie usa: 200\u{A0}704")
    #expect(mac.contextLine == "servidor: 131\u{A0}072 · Evie usa: 131\u{A0}072")
    #expect(unlabelled.contextLine == "Evie usa: 65\u{A0}536")
  }

  @Test("where each brain runs, said plainly")
  func whereItRuns() {
    #expect(
      ModelLocation.yourPC.placeDescription == "No seu PC, pela sua rede Tailscale (criptografada)")
    #expect(ModelLocation.thisMac.placeDescription == "Somente neste Mac")
  }

  @Test("the status line and the failure name the brain that answered")
  func perProfileTurnCopy() {
    #expect(ModelLocation.yourPC.statusTag == "no seu PC")
    #expect(ModelLocation.thisMac.statusTag == "somente neste Mac")
    #expect(ModelLocation.yourPC.noAnswer == "O PC não respondeu")
    #expect(ModelLocation.thisMac.noAnswer == "O cérebro do Mac não respondeu")
    #expect(ModelLocation.yourPC.processedLine == "Processado no seu PC")
    #expect(ModelLocation.thisMac.processedLine == "Processado somente neste Mac")
    #expect(
      ModelLocation.yourPC.failureRecovery
        == "O PC não respondeu. Abra Configurações › Cérebro e use Testar conexão."
    )
    #expect(
      ModelLocation.thisMac.failureRecovery
        == "O cérebro do Mac não respondeu. Abra Configurações › Cérebro e use Testar conexão."
    )
    for location in [ModelLocation.yourPC, .thisMac] {
      #expect(!location.failureRecovery.contains("local"))
    }
  }

  @Test(
    "the persona calls her personal, not local, on either brain",
    arguments: [ModelLocation.yourPC, .thisMac])
  func personaIsNotLocal(location: ModelLocation) {
    var capabilities = EvieCapabilitySnapshot.allEnabled
    capabilities.whereItRuns = location

    let prompt = EviePersona.evie.systemPrompt(capabilities: capabilities)

    #expect(prompt.contains("assistente pessoal de Matheus"))
    #expect(!prompt.contains("assistente pessoal local"))
  }

  @Test("reasoning levels and the Mac fallback have Portuguese names")
  func choiceTitles() {
    #expect(ReasoningLevel.allCases.map(\.title) == ["Desligado", "Baixo", "Médio", "Máximo"])
    #expect(
      [MacFallback.off, .ask, .automatic].map(\.title)
        == ["Não usar o Mac", "Perguntar", "Usar o Mac automaticamente"]
    )
  }

  // MARK: Drafts

  @Test("an untouched draft applies back to the same profile", arguments: ["pc", "mac"])
  func untouchedDraftIsTheProfile(which: String) throws {
    let profile = which == "pc" ? pc : mac

    #expect(try EvieProfileDraft(profile).applied(to: profile) == profile)
  }

  @Test("a draft applies what was edited, and nothing else")
  func draftAppliesEdits() throws {
    var draft = EvieProfileDraft(pc)
    draft.endpoint = "  https://models.example.invalid/v1/  "
    draft.model = " qwen-uncensored "
    draft.contextTokens = 100_000
    draft.maxCompletionTokens = 8_192
    draft.defaultReasoning = .low
    draft.usesServerTemperature = false
    draft.temperature = 0.4
    draft.requestTimeout = 120

    let edited = try draft.applied(to: pc)

    #expect(edited.endpoint.absoluteString == "https://models.example.invalid/v1/")
    #expect(edited.model == "qwen-uncensored")
    #expect(edited.contextTokens == 100_000)
    #expect(edited.maxCompletionTokens == 8_192)
    #expect(edited.defaultReasoning == .low)
    #expect(edited.temperature == 0.4)
    #expect(edited.topP == nil)
    #expect(edited.requestTimeout == 120)
    #expect(edited.credential == pc.credential)
    #expect(edited.capabilities == pc.capabilities)
    #expect(edited.serverContextTokens == pc.serverContextTokens)
  }

  @Test("a draft the profile could not run with is refused in Portuguese")
  func draftRefusesWhatCannotRun() {
    var notAURL = EvieProfileDraft(pc)
    notAURL.endpoint = "example-workstation"
    var noModel = EvieProfileDraft(pc)
    noModel.model = "  "
    var outputOverCap = EvieProfileDraft(mac)
    outputOverCap.maxCompletionTokens = mac.contextTokens + 1

    #expect(throws: EvieProfileDraft.Problem.invalidEndpoint) { try notAURL.applied(to: pc) }
    #expect(throws: EvieProfileDraft.Problem.emptyModel) { try noModel.applied(to: pc) }
    #expect(throws: EvieProfileDraft.Problem.outputOverContext) {
      try outputOverCap.applied(to: mac)
    }
    #expect(
      EvieProfileDraft.Problem.outputOverContext.errorDescription
        == "A resposta máxima não pode passar do contexto que a Evie usa."
    )
  }

  @Test("the Mac brain's address is fixed: the field is locked and an edit is not applied")
  func macEndpointIsFixed() throws {
    var draft = EvieProfileDraft(mac)
    draft.endpoint = "http://127.0.0.1:9999/v1"

    let edited = try draft.applied(to: mac)

    #expect(edited.endpoint == mac.endpoint)
    #expect(
      mac.fixedEndpointExplanation
        == "A Evie inicia o cérebro do Mac só neste endereço, 127.0.0.1 na porta 38480."
    )
    #expect(pc.fixedEndpointExplanation == nil)
  }

  @Test("fields an EVIE_MODEL_* variable set are left as the file has them")
  func managedFieldsAreKept() throws {
    let managed = EvieManagedField.managed(by: [
      "EVIE_MODEL_CONTEXT": "4096",
      "EVIE_MODEL_NAME": "from-the-environment",
      "EVIE_CONFIG_FILE": "/tmp/x.json",
    ])
    var draft = EvieProfileDraft(pc)
    draft.contextTokens = 4_096
    draft.model = "from-the-environment"
    draft.maxCompletionTokens = 2_048

    let edited = try draft.applied(to: pc, keeping: managed)

    #expect(managed == [.contextTokens, .model])
    #expect(edited.contextTokens == pc.contextTokens)
    #expect(edited.model == pc.model)
    #expect(edited.maxCompletionTokens == 2_048)
  }

  @Test("the endpoint is checked against the transport policy as it is typed")
  func endpointCheck() {
    let policy = ModelTransportPolicy()
    var draft = EvieProfileDraft(pc)

    #expect(draft.endpointProblem(credential: pc.credential, policy: policy) == nil)

    draft.endpoint = "https://evil.example/v1"
    #expect(
      draft.endpointProblem(credential: pc.credential, policy: policy)
        == "evil.example não está na lista de servidores que a Evie pode usar."
    )

    draft.endpoint = "http://models.example.invalid/v1"
    #expect(
      draft.endpointProblem(credential: pc.credential, policy: policy)
        == "models.example.invalid precisa de https: http só vale para este Mac."
    )

    draft.endpoint = "https://models.example.invalid/v1"
    #expect(
      draft.endpointProblem(credential: nil, policy: policy)
        == "models.example.invalid precisa de uma chave antes de a Evie mandar qualquer coisa."
    )

    draft.endpoint = "https://other.example-tailnet.ts.net/v1"
    #expect(
      draft.endpointProblem(
        credential: pc.credential,
        policy: ModelTransportPolicy(allowedRemoteHosts: ["*.example-tailnet.ts.net"])
      ) == "A chave salva é de outro servidor, não de other.example-tailnet.ts.net."
    )

    draft.endpoint = "ftp://127.0.0.1/v1"
    #expect(
      draft.endpointProblem(credential: nil, policy: policy)
        == "O endereço precisa começar com http:// ou https://."
    )

    draft.endpoint = "https://user:secret@models.example.invalid/v1"
    let withPassword = draft.endpointProblem(credential: pc.credential, policy: policy)
    #expect(withPassword == "O endereço não pode levar usuário ou senha.")

    draft.endpoint = "not a url"
    #expect(
      draft.endpointProblem(credential: nil, policy: policy)
        == "Isso não é um endereço. Use algo como https://servidor/v1."
    )

    let loopback = EvieProfileDraft(mac)
    #expect(loopback.endpointProblem(credential: nil, policy: policy) == nil)
  }

  @Test("the policy's own refusals keep their wording for the client and the logs")
  func policyRefusalsUnchanged() {
    let policy = ModelTransportPolicy()

    #expect(
      policy.evaluate(URL(string: "https://evil.example/v1")!, credentialHost: "evil.example")
        == .refused("evil.example is not on the list of model hosts Evie may use.")
    )
  }

  // MARK: The set

  @Test("preferring a profile puts it first and keeps the others in their order")
  func preferring() {
    var set = EvieModelProfileSet.builtIn
    let custom = EvieModelProfile(
      id: "custom", displayName: "Personalizado", endpoint: mac.endpoint, model: "m",
      contextTokens: 8_192, maxCompletionTokens: 1_024, capabilities: mac.capabilities,
      thinkingStyle: .none, runtime: .remoteGateway, location: .thisMac, family: .unknown,
      coordinateConvention: .pixels
    )
    set.profiles.append(custom)

    #expect(set.preferring("mac-local").preferenceOrder == ["mac-local", "pc-3090"])
    #expect(set.preferring("pc-3090").preferenceOrder == ["pc-3090", "mac-local"])
    #expect(set.preferring("custom").preferenceOrder == ["custom", "pc-3090", "mac-local"])
    #expect(set.preferring("custom").preferredProfile.id == "custom")
  }

  @Test("the settings save writes the order, the fallback and every edited profile as v2")
  func saveWritesTheWholeSet() throws {
    let fileURL = FileManager.default.temporaryDirectory
      .appendingPathComponent(UUID().uuidString, isDirectory: true)
      .appendingPathComponent("config.json", isDirectory: false)
    let store = EvieConfigurationStore(fileURL: fileURL)
    try store.save(.builtIn)

    var activeSeen: String?
    let saved = try store.saveProfiles(
      reading: EvieConfigurationLoader(fileURL: fileURL),
      environment: ["EVIE_MODEL_NAME": "never-written"],
      otherwise: .builtIn
    ) { set, activeID in
      activeSeen = activeID
      set = set.preferring("mac-local")
      set.macFallback = .automatic
      try set.updateProfile(id: "pc-3090") { $0.contextTokens = 100_000 }
      try set.updateProfile(id: "mac-local") { $0.defaultReasoning = .low }
    }

    let reread = try EvieConfigurationLoader(fileURL: fileURL).loadProfiles(environment: [:])
    #expect(activeSeen == "pc-3090")
    #expect(reread.profiles == saved)
    #expect(reread.profiles.preferenceOrder == ["mac-local", "pc-3090"])
    #expect(reread.profiles.macFallback == .automatic)
    #expect(reread.activeProfile.id == "mac-local")
    #expect(reread.profiles.profile(id: "pc-3090")?.contextTokens == 100_000)
    #expect(reread.profiles.profile(id: "pc-3090")?.model == "qwen-daily")
    #expect(reread.profiles.profile(id: "mac-local")?.defaultReasoning == .low)
    let text = try String(contentsOf: fileURL, encoding: .utf8)
    #expect(text.contains(#""schema_version" : 2"#))
    #expect(!text.contains("never-written"))
  }
}
