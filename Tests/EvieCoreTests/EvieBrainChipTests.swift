import Foundation
import Testing

@testable import EvieCore

/// The words on the overlay's brain chip, its dot, its menu and the label
/// under an answer.
@Suite("Evie brain chip")
struct EvieBrainChipTests {
  private let pc = EvieModelProfile.builtInPC
  private let mac = EvieModelProfile.builtInMac

  @Test("the built-in brains are named for their models, not their profiles")
  func builtInNames() {
    #expect(pc.displayModelName == "Qwen 3.8")
    #expect(mac.displayModelName == "LensVLM")
    #expect(pc.chipTitle == "Qwen 3.8 · PC")
    #expect(mac.chipTitle == "LensVLM · Mac")
    #expect(pc.answerLabel == "Qwen 3.8 · no seu PC")
    #expect(mac.answerLabel == "LensVLM · neste Mac")
  }

  @Test(
    "a model nobody mapped is shown as its id without the publisher",
    arguments: [
      ("qwen-turbo", "qwen-turbo"),
      ("mlx-community/Gemma-4-12B-4bit", "Gemma-4-12B-4bit"),
      ("  QWEN-DAILY ", "Qwen 3.8"),
      ("someone/LensVLM-12B-bf16", "LensVLM"),
      ("trailing/", "trailing"),
    ])
  func unmappedNames(model: String, expected: String) {
    #expect(EvieModelProfile.displayModelName(forModel: model) == expected)
  }

  @Test("a chosen profile name appears without changing the model identifier")
  func customProfileName() throws {
    var draft = EvieProfileDraft(pc)
    draft.displayName = "  Minha IA  "
    let profile = try draft.applied(to: pc)
    #expect(profile.model == pc.model)
    #expect(profile.chipTitle == "Minha IA · PC")
    #expect(profile.answerLabel == "Minha IA · no seu PC")
    let restored = try JSONDecoder().decode(
      EvieModelProfile.self, from: JSONEncoder().encode(profile))
    #expect(restored.displayName == "Minha IA")
  }

  @Test("an edited model id renames the brain")
  func editedModel() {
    var edited = pc
    edited.model = "qwen-quality"
    #expect(edited.chipTitle == "qwen-quality · PC")
  }

  @Test(
    "each rung maps to one dot, and waking wins over whatever the probe said",
    arguments: [
      (ReadinessRung?.none, false, EvieBrainChipState.checking),
      (.ready, false, .ready),
      (.modelCold, false, .cold),
      (.unreachable, false, .unreachable),
      (.keyMissing, false, .unreachable),
      (.keyRejected, false, .unreachable),
      (.modelUnknown, false, .unreachable),
      (.modelCold, true, .waking),
      (.ready, true, .waking),
    ])
  func stateMapping(rung: ReadinessRung?, waking: Bool, expected: EvieBrainChipState) {
    #expect(EvieBrainChipState(rung: rung, isWaking: waking) == expected)
  }

  @Test("the chip says why a brain cannot answer, in the resolver's words")
  func unreachableDescriptions() {
    #expect(EvieBrainChip(profile: pc, rung: .unreachable).stateDescription == "O PC está fora.")
    #expect(EvieBrainChip(profile: pc, rung: .keyMissing).stateDescription == "Sem a chave do PC.")
    #expect(
      EvieBrainChip(profile: pc, rung: .keyRejected).stateDescription == "O PC recusou a chave.")
  }

  @Test("a cold brain is described for where it is")
  func coldDescriptions() {
    #expect(
      EvieBrainChip(profile: pc, rung: .modelCold).stateDescription
        == "conectado; o modelo carrega na primeira pergunta")
    #expect(
      EvieBrainChip(profile: mac, rung: .modelCold).stateDescription
        == "dormindo; acorda na primeira pergunta (~10 s, ~8 GB de memória)")
  }

  @Test("VoiceOver hears the brain, its state and agent mode")
  func accessibility() {
    let ready = EvieBrainChip(profile: pc, rung: .ready)
    var acting = ready
    acting.isAgentModeOn = true

    #expect(ready.accessibilityLabel == "Qwen 3.8 no seu PC: pronto.")
    #expect(acting.accessibilityLabel == "Qwen 3.8 no seu PC: pronto. Modo agente ligado.")
    #expect(
      EvieBrainChip(profile: pc, rung: .unreachable).accessibilityLabel
        == "Qwen 3.8 no seu PC: O PC está fora.")
  }

  @Test("Testar conexão reports the brain, and where to put a missing PC key")
  func connectionSummary() {
    #expect(
      EvieBrainChip(profile: pc, rung: .ready).connectionSummary == "Qwen 3.8 no seu PC: pronto.")
    #expect(
      EvieBrainChip(profile: pc, rung: .keyMissing).connectionSummary
        == "Sem a chave do PC. Importe a chave em Configurações › Cérebro.")
    #expect(
      EvieBrainChip(profile: mac, rung: .modelCold).connectionSummary
        == "LensVLM neste Mac: dormindo; acorda na primeira pergunta (~10 s, ~8 GB de memória).")
  }

  @Test("the menu offers the three choices, named from the profiles in their order")
  func menuItems() {
    let menu = EvieBrainMenu(
      profiles: .builtIn, choice: .automatic, pinned: nil, next: pc)

    #expect(
      menu.items.map(\.title)
        == ["Automático · PC, depois Mac", "Sempre o PC · Qwen 3.8", "Sempre o Mac · LensVLM"])
    #expect(menu.items.map(\.isSelected) == [true, false, false])
    #expect(menu.items.allSatisfy { $0.isAvailable })
    #expect(menu.pinnedNote == nil)
    #expect(menu.reasoningLine == "Raciocínio: Desligado")
  }

  @Test("a place with no profile cannot be chosen")
  func unavailablePlace() {
    let pcOnly = EvieModelProfileSet(
      profiles: [pc], preferenceOrder: [pc.id], macFallback: .off)
    let menu = EvieBrainMenu(profiles: pcOnly, choice: .automatic, pinned: nil, next: pc)

    #expect(menu.items.map(\.isAvailable) == [true, true, false])
    #expect(menu.items[2].title == "Sempre o Mac · indisponível")
  }

  @Test("the open conversation is said to stay where it is pinned")
  func pinnedNote() {
    let menu = EvieBrainMenu(
      profiles: .builtIn, choice: .alwaysMac, pinned: pc, next: mac)

    #expect(
      menu.pinnedNote
        == "Esta conversa continua em Qwen 3.8 · PC. A escolha vale a partir da próxima.")
    #expect(menu.items.map(\.isSelected) == [false, false, true])
    // The reasoning that applies to the next answer is the pinned brain's.
    #expect(menu.reasoningLine == "Raciocínio: Desligado")
  }

  @Test("the reasoning line names the level that slows answers down")
  func reasoningLine() {
    var thinking = pc
    thinking.defaultReasoning = .xhigh
    let menu = EvieBrainMenu(profiles: .builtIn, choice: .automatic, pinned: nil, next: thinking)

    #expect(menu.reasoningLine == "Raciocínio: Máximo")
  }
}

/// The chip's menu pins through the resolver and its preference order.
@MainActor
@Suite("Evie brain resolver choice")
struct EvieBrainResolverChoiceTests {
  private let pc = EvieModelProfile.pcProfileID
  private let mac = EvieModelProfile.macProfileID

  @Test("an explicit PC choice releases the current Mac pin but preserves other conversations")
  func explicitChoiceChangesCurrentConversation() async {
    let harness = ResolverHarness(keys: .saved, rungs: [pc: .ready, mac: .ready])
    harness.resolver.choose(.alwaysMac)
    let current = UUID()
    let other = UUID()
    _ = await harness.resolver.resolve(conversation: current)
    _ = await harness.resolver.resolve(conversation: other)
    harness.resolver.choose(.alwaysPC, for: current)
    #expect(harness.resolver.expectedProfile(for: current).id == pc)
    #expect(await harness.resolver.resolve(conversation: current).profile.id == pc)
    #expect(harness.resolver.pinnedProfileID(for: other) == mac)
  }

  @Test("Sempre o Mac starts a new conversation on the Mac, without asking, though the PC is ready")
  func alwaysMac() async {
    let harness = ResolverHarness(
      keys: .saved, rungs: [pc: .ready, mac: .modelCold], fallback: .ask)
    harness.resolver.choose(.alwaysMac)

    let brain = await harness.resolver.resolve(conversation: UUID())

    #expect(harness.resolver.choice == .alwaysMac)
    #expect(brain.profile.id == mac)
    #expect(brain.notice == nil)
    #expect(harness.questions.isEmpty)
    #expect(harness.launcher.starts == 1)
  }

  @Test("Sempre o PC never moves to the Mac, even with fallback automatic")
  func alwaysPCNeverMoves() async {
    let harness = ResolverHarness(
      keys: .saved, rungs: [pc: .unreachable, mac: .ready], fallback: .automatic)
    harness.resolver.choose(.alwaysPC)
    let conversation = UUID()

    let brain = await harness.resolver.resolve(conversation: conversation)
    let next = await harness.resolver.failover(
      conversation: conversation, after: .unreachable("gateway"))

    #expect(brain.profile.id == pc)
    #expect(brain.rung == .unreachable)
    #expect(next == nil)
    #expect(harness.launcher.starts == 0)
  }

  @Test("Automático is the preference order as saved, moving as macFallback says")
  func automaticIsTheOrder() async {
    let harness = ResolverHarness(
      keys: .saved, rungs: [pc: .unreachable, mac: .modelCold], fallback: .automatic)
    harness.resolver.choose(.alwaysPC)
    harness.resolver.choose(.automatic)

    let brain = await harness.resolver.resolve(conversation: UUID())

    #expect(brain.profile.id == mac)
    #expect(brain.notice == "PC indisponível, usando o Mac")
  }

  @Test("a choice applies to conversations without a pin; the open one keeps its brain")
  func choiceLeavesPinsAlone() async {
    let harness = ResolverHarness(keys: .saved, rungs: [pc: .ready, mac: .ready])
    let open = UUID()
    _ = await harness.resolver.resolve(conversation: open)

    harness.resolver.choose(.alwaysMac)
    let again = await harness.resolver.resolve(conversation: open)
    let fresh = UUID()

    #expect(again.profile.id == pc)
    #expect(harness.resolver.expectedProfile(for: open).id == pc)
    #expect(harness.resolver.pinnedProfile(for: open)?.id == pc)
    #expect(harness.resolver.expectedProfile(for: fresh).id == mac)
    #expect(harness.resolver.pinnedProfile(for: fresh) == nil)
  }

  @Test("a choice wins over a profile the environment named")
  func choiceOverEnvironment() async {
    let harness = ResolverHarness(
      keys: .saved, rungs: [pc: .ready, mac: .ready],
      environment: ["EVIE_MODEL_PROFILE": mac])
    #expect(harness.resolver.expectedProfile(for: UUID()).id == mac)

    harness.resolver.choose(.alwaysPC)

    #expect(harness.resolver.expectedProfile(for: UUID()).id == pc)
  }

  @Test("a place with no profile cannot be chosen, and choosing it changes nothing")
  func unavailableChoice() {
    let pcOnly = EvieModelProfileSet(
      profiles: [EvieModelProfile.builtInPC], preferenceOrder: [pc], macFallback: .off)
    let resolver = EvieBrainResolver(
      configuration: EvieLoadedConfiguration(
        profiles: pcOnly, activeProfile: EvieModelProfile.builtInPC),
      environment: [:],
      factory: ModelClientFactory(credentials: MutableKeys(saved: [])),
      readiness: ModelReadinessCache { _ in ModelReadiness(rung: .ready) },
      localBrain: LauncherDouble()
    )

    resolver.choose(.alwaysMac)

    #expect(!resolver.canChoose(.alwaysMac))
    #expect(resolver.canChoose(.alwaysPC))
    #expect(resolver.choice == .automatic)
  }

  @Test("the chip's status is the expected brain and its rung, the key store first")
  func status() async {
    let harness = ResolverHarness(keys: .none, rungs: [pc: .ready, mac: .ready])

    let status = await harness.resolver.status(for: UUID())

    #expect(status.profile.id == pc)
    #expect(status.rung == .keyMissing)
    #expect(!harness.probed.contains(pc))
  }

  @Test("Testar conexão probes again whatever the cache held")
  func checkConnectionReprobes() async {
    let harness = ResolverHarness(keys: .saved, rungs: [pc: .ready, mac: .ready])
    let conversation = UUID()
    #expect(await harness.resolver.status(for: conversation).rung == .ready)

    harness.rungs.set(pc, .unreachable)
    let cached = await harness.resolver.status(for: conversation)
    let checked = await harness.resolver.checkConnection(for: conversation)

    #expect(cached.rung == .ready)
    #expect(checked.rung == .unreachable)
  }
}
