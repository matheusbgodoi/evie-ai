import Foundation
import Security
import Testing

@testable import EvieCore

/// The first-run guide's two rows that are not system permissions: "Chave do
/// PC", which imports the PC configuration's key, and "Cérebro", which runs
/// Testar conexão. The keychain is the in-memory one from `EvieModelKeysTests`
/// and the connection test is a stand-in, so nothing here touches the network
/// or the real keychain.
@Suite("Evie permission guide brain rows")
@MainActor
struct EviePermissionGuideBrainTests {
  private let pcProfile = EvieModelProfileSet.builtIn.profile(id: EvieModelProfile.pcProfileID)!
  private let macProfile = EvieModelProfileSet.builtIn.profile(id: EvieModelProfile.macProfileID)!
  private var evieItem: KeychainItemName { KeychainItemName(pcProfile.credential!) }

  // MARK: Chave do PC

  @Test("a saved PC key is marked done and offers no button")
  func savedKeyOffersNothing() {
    let row = PermissionGuideRow.pcKey(status: .saved, importFailure: nil)

    #expect(row.id == PermissionGuideRow.pcKeyID)
    #expect(row.title == "Chave do PC")
    #expect(row.mark == .satisfied)
    #expect(row.statusText == "Salva")
    #expect(row.action == nil)
  }

  @Test("a missing PC key offers the import and explains the macOS prompt before it is pressed")
  func missingKeyOffersTheImport() {
    let row = PermissionGuideRow.pcKey(status: .missing, importFailure: nil)

    #expect(row.mark == .pending)
    #expect(row.statusText == "Sem chave")
    #expect(row.action == PermissionGuideRow.Action(title: "Importar", kind: .importPCKey))
    #expect(row.hint == EvieModelKeys.importPromptExplanation)
    #expect(EvieModelKeys.importPromptExplanation.contains("\"Permitir\" basta"))
    #expect(EvieModelKeys.importPromptExplanation.contains("senha de login do Mac"))
  }

  @Test("a keychain that cannot be asked is shown with its reason, and the import stays offered")
  func unknownStatusShowsTheReason() {
    let row = PermissionGuideRow.pcKey(
      status: .unknown("O Keychain do macOS respondeu com um erro (status -1)."),
      importFailure: nil
    )

    #expect(row.mark == .refused)
    #expect(row.hint == "O Keychain do macOS respondeu com um erro (status -1).")
    #expect(row.action?.kind == .importPCKey)
  }

  @Test("a failed import says why and offers to try again")
  func failedImportSaysWhy() {
    let failure = EvieModelKeyError.accessDenied.errorDescription!
    let row = PermissionGuideRow.pcKey(status: .missing, importFailure: failure)

    #expect(row.mark == .refused)
    #expect(row.hint == failure)
    #expect(row.action?.kind == .importPCKey)
  }

  @Test("a key saved after a failed import wins over the failure")
  func savedKeyWinsOverAnEarlierFailure() {
    let row = PermissionGuideRow.pcKey(
      status: .saved,
      importFailure: EvieModelKeyError.sourceMissing.errorDescription
    )

    #expect(row.mark == .satisfied)
    #expect(row.hint == nil)
    #expect(row.action == nil)
  }

  @Test("with no profile that takes the PC key, the row has nothing to ask")
  func noProfileTakesTheKey() {
    let row = PermissionGuideRow.pcKey(status: nil, importFailure: nil)

    #expect(row.mark == .satisfied)
    #expect(row.statusText == "Não usada")
    #expect(row.action == nil)
  }

  @Test("the key the guide imports is the PC profile's, even while the Mac is the brain in use")
  func pcKeyProfileIsThePCs() {
    let onThePC = EvieLoadedConfiguration(profiles: .builtIn, activeProfile: pcProfile)
    let onTheMac = EvieLoadedConfiguration(profiles: .builtIn, activeProfile: macProfile)
    var macOnly = EvieModelProfileSet.builtIn
    macOnly.profiles.removeAll { $0.id == EvieModelProfile.pcProfileID }
    macOnly.preferenceOrder = [EvieModelProfile.macProfileID]

    #expect(onThePC.pcKeyProfile?.id == EvieModelProfile.pcProfileID)
    #expect(onTheMac.pcKeyProfile?.id == EvieModelProfile.pcProfileID)
    #expect(
      EvieLoadedConfiguration(profiles: macOnly, activeProfile: macProfile).pcKeyProfile == nil
    )
  }

  @Test("the import copies the PC configuration's key into Evie's item with one read")
  func importCopiesTheKey() async {
    let items = MemoryKeychainItems()
    items.store("sk-guide-0123456789", at: EvieModelKeys.pcConfigurationItem)
    let saved = Box<[String]>([])
    let step = EvieGuidePCKeyStep(
      keys: EvieModelKeys(items: items, credentials: InvalidationRecorder()),
      configuration: { EvieLoadedConfiguration(profiles: .builtIn, activeProfile: macProfile) },
      onKeySaved: { saved.value.append($0.id) }
    )
    #expect(step.row.mark == .pending)

    await step.importKey()

    #expect(items.secret(at: evieItem) == "sk-guide-0123456789")
    #expect(items.reads(of: EvieModelKeys.pcConfigurationItem) == 1)
    #expect(saved.value == [EvieModelProfile.pcProfileID])
    await waitForSavedKey(step)
    #expect(step.row.mark == .satisfied)
  }

  @Test("the row's status reads attributes only, never a secret")
  func statusNeverReadsASecret() async {
    let items = MemoryKeychainItems()
    items.store("sk-guide-0123456789", at: evieItem)
    let step = EvieGuidePCKeyStep(
      keys: EvieModelKeys(items: items, credentials: InvalidationRecorder()),
      configuration: { EvieLoadedConfiguration(profiles: .builtIn, activeProfile: pcProfile) },
      onKeySaved: { _ in }
    )

    await waitForSavedKey(step)
    let row = step.row

    #expect(row.mark == .satisfied)
    #expect(items.reads(of: evieItem) == 0)
    #expect(items.reads(of: EvieModelKeys.pcConfigurationItem) == 0)
    #expect(!"\(row)".contains("sk-guide"))
  }

  @Test("an import with no PC configuration on this Mac writes nothing and says to paste the key")
  func importWithoutTheSourceWritesNothing() async {
    let items = MemoryKeychainItems()
    let saved = Box(0)
    let step = EvieGuidePCKeyStep(
      keys: EvieModelKeys(items: items, credentials: InvalidationRecorder()),
      configuration: { EvieLoadedConfiguration(profiles: .builtIn, activeProfile: pcProfile) },
      onKeySaved: { _ in saved.value += 1 }
    )

    await step.importKey()

    #expect(items.writes == 0)
    #expect(saved.value == 0)
    #expect(step.row.mark == .refused)
    #expect(step.row.hint == EvieModelKeyError.sourceMissing.errorDescription)
    #expect(step.row.action?.kind == .importPCKey)
  }

  @Test("a refused macOS prompt leaves no trace of the key in the row")
  func refusedPromptLeavesNoKey() async {
    let items = MemoryKeychainItems()
    items.store("sk-guide-0123456789", at: EvieModelKeys.pcConfigurationItem)
    items.failReads(of: EvieModelKeys.pcConfigurationItem, with: errSecUserCanceled)
    let step = EvieGuidePCKeyStep(
      keys: EvieModelKeys(items: items, credentials: InvalidationRecorder()),
      configuration: { EvieLoadedConfiguration(profiles: .builtIn, activeProfile: pcProfile) },
      onKeySaved: { _ in }
    )

    await step.importKey()

    #expect(items.writes == 0)
    #expect(step.row.hint == EvieModelKeyError.accessDenied.errorDescription)
    #expect(!"\(step.row)".contains("sk-guide"))
  }

  private func waitForSavedKey(_ step: EvieGuidePCKeyStep) async {
    let deadline = ContinuousClock.now + .seconds(2)
    while step.row.mark != .satisfied, ContinuousClock.now < deadline {
      try? await Task.sleep(for: .milliseconds(2))
    }
  }

  // MARK: Cérebro

  @Test("an untested brain offers Testar conexão")
  func untestedBrainOffersTheTest() {
    let row = PermissionGuideRow.brain(profile: pcProfile, report: nil)

    #expect(row.id == PermissionGuideRow.brainID)
    #expect(row.title == "Cérebro")
    #expect(row.mark == .pending)
    #expect(row.statusText == "Não testado")
    #expect(row.action == PermissionGuideRow.Action(title: "Testar conexão", kind: .testConnection))
  }

  @Test("a brain that passed shows each step's time and keeps the test on offer")
  func passedBrainShowsTheSteps() {
    let row = PermissionGuideRow.brain(profile: pcProfile, report: Self.report(.ready))

    #expect(row.mark == .satisfied)
    #expect(row.statusText == "Pronto")
    #expect(
      row.hint
        == "PC alcançável: ✓ 37 ms · Chave aceita: ✓ 69 ms · Modelo carregado: ✓ 69 ms\n"
        + "Tudo certo: qwen-daily está carregado."
    )
    #expect(row.action?.kind == .testConnection)
  }

  @Test(
    "a brain that cannot answer is marked refused, with the rung's own words",
    arguments: [
      (ReadinessRung.unreachable, "Sem resposta"),
      (.keyMissing, "Sem chave"),
      (.keyRejected, "Chave recusada"),
      (.modelUnknown, "Sem o modelo"),
    ]
  )
  func failedBrainIsRefused(rung: ReadinessRung, statusText: String) {
    let report = Self.report(rung)
    let row = PermissionGuideRow.brain(profile: pcProfile, report: report)

    #expect(row.mark == .refused)
    #expect(row.statusText == statusText)
    #expect(row.hint?.hasSuffix(report.summary(for: pcProfile)) == true)
  }

  @Test("an unloaded model is set up: the first question loads it, and the Mac brain wakes")
  func coldBrainIsSetUp() {
    let pcRow = PermissionGuideRow.brain(profile: pcProfile, report: Self.report(.modelCold))
    let macRow = PermissionGuideRow.brain(
      profile: macProfile,
      report: ModelConnectionReport(
        readiness: ModelReadiness(rung: .modelCold),
        lines: [
          .init(step: .reachable, outcome: .failed, elapsed: .milliseconds(2)),
          .init(step: .key, outcome: .notNeeded, elapsed: nil),
          .init(step: .model, outcome: .notRun, elapsed: nil),
        ],
        availableModels: []
      )
    )

    #expect(pcRow.mark == .satisfied)
    #expect(pcRow.statusText == "Descarregado")
    #expect(macRow.mark == .satisfied)
    #expect(macRow.statusText == "Acorda ao perguntar")
    #expect(
      macRow.hint
        == "Servidor do Mac rodando: ✗ 2 ms · Chave aceita: não precisa · "
        + "Modelo carregado: não testado\nO cérebro do Mac não está rodando."
    )
  }

  @Test("the test runs on the brain in use, and its result goes when that brain changes")
  func testFollowsTheBrainInUse() async {
    let configuration = Box(EvieLoadedConfiguration(profiles: .builtIn, activeProfile: pcProfile))
    let tested = Box<[String]>([])
    let step = EvieGuideBrainStep(
      configuration: { configuration.value },
      test: { profile in
        tested.value.append(profile.id)
        return Self.report(.ready)
      }
    )

    await step.testConnection()
    #expect(tested.value == [EvieModelProfile.pcProfileID])
    #expect(step.row.mark == .satisfied)

    configuration.value = EvieLoadedConfiguration(profiles: .builtIn, activeProfile: macProfile)
    #expect(step.row.mark == .pending)
    #expect(step.row.detail.contains("Mac"))
  }

  @Test("a saved key makes the last result stale")
  func forgettingTheResult() async {
    let step = EvieGuideBrainStep(
      configuration: { EvieLoadedConfiguration(profiles: .builtIn, activeProfile: pcProfile) },
      test: { _ in Self.report(.keyMissing) }
    )
    await step.testConnection()
    #expect(step.row.mark == .refused)

    step.forgetResult()

    #expect(step.row.mark == .pending)
  }

  // MARK: Helpers

  /// A gateway report that stops at the step the rung names.
  private static func report(_ rung: ReadinessRung) -> ModelConnectionReport {
    let reachable: ModelConnectionReport.Outcome = rung == .unreachable ? .failed : .passed
    let key: ModelConnectionReport.Outcome =
      switch rung {
      case .unreachable: .notRun
      case .keyMissing, .keyRejected: .failed
      case .modelUnknown, .modelCold, .ready: .passed
      }
    let model: ModelConnectionReport.Outcome =
      switch rung {
      case .unreachable, .keyMissing, .keyRejected: .notRun
      case .modelUnknown, .modelCold: .failed
      case .ready: .passed
      }
    return ModelConnectionReport(
      readiness: ModelReadiness(rung: rung),
      lines: [
        .init(step: .reachable, outcome: reachable, elapsed: .milliseconds(37)),
        .init(step: .key, outcome: key, elapsed: key == .notRun ? nil : .milliseconds(69)),
        .init(step: .model, outcome: model, elapsed: model == .notRun ? nil : .milliseconds(69)),
      ],
      availableModels: []
    )
  }
}

/// A value the closures under test can change and the test can read back.
@MainActor
private final class Box<Value> {
  var value: Value

  init(_ value: Value) {
    self.value = value
  }
}
