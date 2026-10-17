import EvieCore
import Foundation

/// The "Cérebro" tab: which brain Evie prefers, what she does when the PC is
/// out, each profile's fields, its key and its connection test.
///
/// The rules — how a typed value becomes a profile, which fields the
/// environment holds, what each brain is called, what the endpoint check says —
/// live in EvieCore (`EvieProfileDraft`, `EvieManagedField`, `EvieModelKeys`,
/// `ModelConnectionReport`), where they are tested. This model only holds what
/// the pane is showing and runs the pane's buttons.
@MainActor
final class ModelSettingsViewModel: ObservableObject {
  /// The brain asked first: the head of the preference order.
  @Published var preferredProfileID: String
  @Published var macFallback: MacFallback
  /// The profile whose fields are on screen.
  @Published var editingProfileID: String
  /// One per profile, in the file's order.
  @Published var drafts: [EvieProfileDraft]
  /// Typed or pasted into the key field. Cleared once saved, and never filled
  /// from the keychain: the field does not echo a saved key back.
  @Published var pastedKey = ""
  @Published private(set) var keyStatus: [String: EvieModelKeyStatus] = [:]
  @Published private(set) var keyFeedback: Feedback?
  @Published private(set) var isImportingKey = false
  @Published private(set) var isSavingKey = false
  @Published private(set) var reports: [String: ModelConnectionReport] = [:]
  @Published private(set) var testingProfileID: String?
  @Published private(set) var feedback: Feedback?

  /// The profiles as the file has them, which is what a save edits.
  private(set) var profiles: EvieModelProfileSet
  /// The profile in use, with the environment's overrides.
  private(set) var activeProfile: EvieModelProfile
  /// The drafts as they were when the pane last loaded, so a save writes only
  /// the profiles that were edited and leaves the others as the file has them.
  private var loadedDrafts: [EvieProfileDraft]

  private let store: EvieConfigurationStore
  private let loader: EvieConfigurationLoader
  private let environment: [String: String]
  private let keys: EvieModelKeys
  private let keyStatusRefresh: EvieModelKeyStatusRefresh
  private let probe: ModelReadinessProbe
  private let transportPolicy: ModelTransportPolicy
  private let onSave: @MainActor (EvieLoadedConfiguration) -> Void
  private let onKeySaved: @MainActor (EvieModelProfile) -> Void
  /// The profiles a damaged file is repaired from: those Evie launched with,
  /// then the last ones saved.
  private var repairBaseline: EvieModelProfileSet

  init(
    loaded: EvieLoadedConfiguration,
    repairBaseline: EvieModelProfileSet,
    store: EvieConfigurationStore = EvieConfigurationStore(),
    loader: EvieConfigurationLoader = EvieConfigurationLoader(),
    environment: [String: String] = [:],
    factory: ModelClientFactory = .live,
    keys: EvieModelKeys = .live,
    onSave: @escaping @MainActor (EvieLoadedConfiguration) -> Void,
    onKeySaved: @escaping @MainActor (EvieModelProfile) -> Void
  ) {
    self.store = store
    self.loader = loader
    self.environment = environment
    self.keys = keys
    keyStatusRefresh = EvieModelKeyStatusRefresh(keys: keys)
    probe = factory.makeReadinessProbe()
    transportPolicy = factory.transportPolicy
    self.onSave = onSave
    self.onKeySaved = onKeySaved
    self.repairBaseline = repairBaseline
    profiles = loaded.profiles
    activeProfile = loaded.activeProfile
    preferredProfileID = loaded.profiles.preferredProfile.id
    macFallback = loaded.profiles.macFallback
    editingProfileID = loaded.activeProfile.id
    let drafts = Self.drafts(for: loaded)
    self.drafts = drafts
    loadedDrafts = drafts
    keyStatusRefresh.onChange = { [weak self] in
      guard let self else { return }
      keyStatus = keyStatusRefresh.statuses
    }
    refreshKeyStatus()
  }

  // MARK: What the pane shows

  var editingIndex: Int {
    drafts.firstIndex { $0.profileID == editingProfileID } ?? 0
  }

  var editingProfile: EvieModelProfile {
    profile(id: editingProfileID) ?? activeProfile
  }

  /// The fields of the editing profile an `EVIE_MODEL_*` variable holds for
  /// this run. Only the profile in use takes those overrides.
  var managedFields: Set<EvieManagedField> {
    editingProfileID == activeProfile.id ? EvieManagedField.managed(by: environment) : []
  }

  /// The profile the environment chose by name, if any: the preferred-brain
  /// picker still saves, but this run keeps using that one.
  var profileChosenByEnvironment: String? {
    environment["EVIE_MODEL_PROFILE"].flatMap { $0.isEmpty ? nil : $0 }
  }

  var endpointProblem: String? {
    drafts[editingIndex].endpointProblem(
      credential: editingProfile.credential,
      policy: transportPolicy
    )
  }

  /// Why the editing profile cannot be saved as it is, or nil.
  var draftProblem: String? {
    do {
      _ = try edited(drafts[editingIndex])
      return nil
    } catch {
      return (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
    }
  }

  var canSave: Bool {
    drafts.allSatisfy { (try? edited($0)) != nil }
  }

  var editingKeyStatus: EvieModelKeyStatus? {
    editingProfile.credential.map { _ in keyStatus[editingProfileID] ?? .checking }
  }

  /// The import copies the PC configuration's key, so it is offered only on
  /// a profile that runs on the PC and takes a key.
  var offersKeyImport: Bool {
    editingProfile.location == .yourPC && editingProfile.credential != nil
  }

  var editingReport: ModelConnectionReport? {
    reports[editingProfileID]
  }

  var availableModels: [String] {
    reports[editingProfileID]?.availableModels ?? []
  }

  var completionTokenRange: ClosedRange<Int> {
    256...max(256, drafts[editingIndex].contextTokens)
  }

  var contextTokenRange: ClosedRange<Int> {
    1_024...max(1_024, editingProfile.serverContextTokens ?? 1_048_576)
  }

  var timeoutRange: ClosedRange<Double> {
    let timeout = drafts[editingIndex].requestTimeout
    return min(1, timeout)...max(3_600, timeout)
  }

  var topPRange: ClosedRange<Double> {
    min(0.001, drafts[editingIndex].topP)...1
  }

  /// The editing profile's context line, with the cap as it is being typed.
  var contextLine: String {
    var shown = editingProfile
    shown.contextTokens = drafts[editingIndex].contextTokens
    return shown.contextLine
  }

  func profile(id: String) -> EvieModelProfile? {
    id == activeProfile.id ? activeProfile : profiles.profile(id: id)
  }

  // MARK: Buttons

  /// An effort change from the compact controls must not let an older open
  /// Settings draft silently restore the old value on its next save.
  func adoptReasoning(_ level: ReasoningLevel, profileID: String) throws {
    if let index = drafts.firstIndex(where: { $0.profileID == profileID }),
      let baseline = loadedDrafts.first(where: { $0.profileID == profileID }),
      drafts[index].defaultReasoning == baseline.defaultReasoning
    {
      drafts[index].defaultReasoning = level
    }
    if let index = loadedDrafts.firstIndex(where: { $0.profileID == profileID }) {
      loadedDrafts[index].defaultReasoning = level
    }
    if profiles.profile(id: profileID) != nil {
      try profiles.updateProfile(id: profileID) { $0.defaultReasoning = level }
    }
    if activeProfile.id == profileID { activeProfile.defaultReasoning = level }
  }

  func save() {
    let changed = drafts.filter { !loadedDrafts.contains($0) }
    let preferred = preferredProfileID
    let fallback = macFallback
    let managed = EvieManagedField.managed(by: environment)
    do {
      let saved = try store.saveProfiles(
        reading: loader,
        environment: environment,
        otherwise: repairBaseline
      ) { set, activeID in
        for draft in changed {
          // A profile removed by hand while the pane was open stays removed.
          guard let base = set.profile(id: draft.profileID) else { continue }
          let edited = try draft.applied(
            to: base,
            keeping: draft.profileID == activeID ? managed : []
          )
          try set.updateProfile(id: draft.profileID) { $0 = edited }
        }
        if set.profile(id: preferred) != nil {
          set = set.preferring(preferred)
        }
        set.macFallback = fallback
      }
      let effective = try loader.loadProfiles(environment: environment)
      repairBaseline = saved
      adopt(effective)
      onSave(effective)
      feedback = Feedback(
        message: managed.isEmpty && profileChosenByEnvironment == nil
          ? "Salvo. A próxima pergunta já usa estes ajustes; a troca de cérebro vale "
            + "para conversas novas."
          : "Arquivo salvo. Valores gerenciados pelo ambiente continuam prevalecendo.",
        isError: false
      )
    } catch {
      feedback = Feedback(
        message: (error as? LocalizedError)?.errorDescription ?? error.localizedDescription,
        isError: true
      )
    }
  }

  func restoreRecommendedSampling() {
    let index = editingIndex
    var profile = editingProfile
    profile.model = drafts[index].model
    let sampling = profile.recommendedSampling
    drafts[index].temperature = sampling.temperature ?? EvieProfileDraft.recommendedTemperature
    drafts[index].topP = sampling.topP ?? EvieProfileDraft.recommendedTopP
    drafts[index].usesServerTemperature = sampling.temperature == nil
    drafts[index].usesServerTopP = sampling.topP == nil
    feedback = nil
  }

  func saveKey() async {
    guard !isSavingKey, !isImportingKey else { return }
    isSavingKey = true
    defer { isSavingKey = false }
    let pasted = pastedKey
    pastedKey = ""
    var keyWasSaved = false
    do {
      let profile = editingProfile
      let endpointIsManaged = managedFields.contains(.endpoint)
      let endpointText = drafts[editingIndex].endpoint
        .trimmingCharacters(in: .whitespacesAndNewlines)
      guard let endpoint = endpointIsManaged ? profile.endpoint : URL(string: endpointText),
        endpoint.scheme?.lowercased() == "https",
        let host = endpoint.host?.lowercased(), !host.isEmpty,
        endpoint.user == nil, endpoint.password == nil
      else { throw EvieConfiguration.ValidationError.invalidEndpoint }
      // Bind only the explicitly captured address. Other draft fields need not
      // be valid yet and are never saved as a side effect of saving a key.
      let reference =
        profile.credential.flatMap { $0.boundHost.lowercased() == host ? $0 : nil }
        ?? CredentialReference(
          service: "com.matheusbgodoi.evie.model",
          account: "\(profile.id)@\(host)", boundHost: host)
      try await keys.save(pasted: pasted, for: reference)
      keyWasSaved = true
      let saved = try store.saveProfiles(
        reading: loader, environment: environment, otherwise: repairBaseline
      ) { set, _ in
        try set.updateProfile(id: profile.id) {
          if !endpointIsManaged { $0.endpoint = endpoint }
          $0.credential = reference
        }
      }
      let effective = try loader.loadProfiles(environment: environment)
      repairBaseline = saved
      adoptPreservingEdits(effective)
      onSave(effective)
      keyFeedback = Feedback(
        message:
          "Chave salva no Keychain e vinculada a este endereço. Ajustes não salvos foram preservados.",
        isError: false)
      var keyedProfile = profile
      keyedProfile.endpoint = endpoint
      keyedProfile.credential = reference
      keySaved(for: keyedProfile)
    } catch {
      let prefix =
        keyWasSaved
        ? "A chave ficou no Keychain, mas o endereço não pôde ser salvo. Seus ajustes continuam na tela. "
        : ""
      keyFeedback = Feedback(message: prefix + Self.message(for: error), isError: true)
    }
  }

  /// Read drafts after the keychain await: edits made while it was pending
  /// belong to the person too. Rebase them field by field onto the fresh file.
  private func adoptPreservingEdits(_ loaded: EvieLoadedConfiguration) {
    let pending = drafts
    let baseline = loadedDrafts
    let preferred = preferredProfileID != profiles.preferredProfile.id ? preferredProfileID : nil
    let fallback = macFallback != profiles.macFallback ? macFallback : nil
    let selection = editingProfileID
    adopt(loaded)
    drafts = drafts.map { latest in
      guard let previous = pending.first(where: { $0.profileID == latest.profileID }),
        let original = baseline.first(where: { $0.profileID == latest.profileID })
      else { return latest }
      return previous.rebased(onto: latest, since: original)
    }
    if let preferred, profiles.profile(id: preferred) != nil { preferredProfileID = preferred }
    if let fallback { macFallback = fallback }
    if drafts.contains(where: { $0.profileID == selection }) { editingProfileID = selection }
  }

  func importKey() async {
    guard !isSavingKey, !isImportingKey else { return }
    guard let reference = editingProfile.credential else { return }
    let profile = editingProfile
    isImportingKey = true
    defer { isImportingKey = false }
    do {
      try await keys.importPCConfigurationKey(into: reference)
      keyFeedback = Feedback(message: "Chave importada da configuração do PC.", isError: false)
      keySaved(for: profile)
    } catch {
      keyFeedback = Feedback(message: Self.message(for: error), isError: true)
    }
  }

  /// Runs the probe on the profile as it is being edited, saved or not, so an
  /// endpoint or model can be tried before it is kept.
  func testConnection() async {
    let id = editingProfileID
    let profile: EvieModelProfile
    do {
      profile = try edited(drafts[editingIndex])
    } catch {
      feedback = Feedback(message: Self.message(for: error), isError: true)
      return
    }
    testingProfileID = id
    defer { testingProfileID = nil }
    reports[id] = await probe.connectionReport(for: profile)
  }

  func refreshKeyStatus() {
    let references = Dictionary(
      uniqueKeysWithValues: profiles.profiles.compactMap { profile in
        profile.credential.map { (profile.id, $0) }
      })
    keyStatusRefresh.refresh(references)
  }

  // MARK: Helpers

  /// The draft as a profile on top of the one it edits: the profile in use
  /// keeps the environment's overrides, so a test runs what a turn would.
  private func edited(_ draft: EvieProfileDraft) throws -> EvieModelProfile {
    guard let base = profile(id: draft.profileID) else {
      throw EvieModelProfileSet.ValidationError.unknownProfile(draft.profileID)
    }
    let managed =
      draft.profileID == activeProfile.id ? EvieManagedField.managed(by: environment) : []
    return try draft.applied(to: base, keeping: managed)
  }

  private func keySaved(for profile: EvieModelProfile) {
    refreshKeyStatus()
    reports[profile.id] = nil
    onKeySaved(profile)
  }

  private func adopt(_ loaded: EvieLoadedConfiguration) {
    profiles = loaded.profiles
    activeProfile = loaded.activeProfile
    preferredProfileID = loaded.profiles.preferredProfile.id
    macFallback = loaded.profiles.macFallback
    let drafts = Self.drafts(for: loaded)
    self.drafts = drafts
    loadedDrafts = drafts
    if !drafts.contains(where: { $0.profileID == editingProfileID }) {
      editingProfileID = loaded.activeProfile.id
    }
    refreshKeyStatus()
  }

  /// Every profile's draft; the one in use shows what this run uses.
  private static func drafts(for loaded: EvieLoadedConfiguration) -> [EvieProfileDraft] {
    loaded.profiles.profiles.map { profile in
      EvieProfileDraft(profile.id == loaded.activeProfile.id ? loaded.activeProfile : profile)
    }
  }

  private static func message(for error: any Error) -> String {
    (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
  }
}

extension ModelSettingsViewModel {
  struct Feedback: Equatable {
    let message: String
    let isError: Bool
  }
}
