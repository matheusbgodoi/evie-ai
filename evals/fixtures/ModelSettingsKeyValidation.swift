import EvieCore
import Foundation
import Synchronization

// Exercises the production settings model against a real temporary JSON store.
// The keychain boundary is in memory; no real credentials or network are used.
private final class MemoryKeys: EvieKeychainItems, Sendable {
  private let values = Mutex<[KeychainItemName: String]>([:])
  func contains(_ item: KeychainItemName) throws -> Bool { values.withLock { $0[item] != nil } }
  func read(_ item: KeychainItemName) throws -> String? { values.withLock { $0[item] } }
  func write(_ secret: String, to item: KeychainItemName, label: String) throws {
    values.withLock { $0[item] = secret }
  }
}

private final class BlockingStatusKeys: EvieKeychainItems, Sendable {
  private struct State {
    var released = false
    var calls = 0
  }
  private let state = Mutex(State())
  private let gate = DispatchSemaphore(value: 0)
  var calls: Int { state.withLock { $0.calls } }
  func contains(_ item: KeychainItemName) throws -> Bool {
    let blocks = state.withLock { state in
      state.calls += 1
      return !state.released
    }
    if blocks { gate.wait() }
    return true
  }
  func read(_ item: KeychainItemName) throws -> String? { nil }
  func write(_ secret: String, to item: KeychainItemName, label: String) throws {}
  func release() {
    state.withLock { $0.released = true }
    gate.signal()
  }
}

private actor SuspendedInvalidation: EvieCredentialProviding {
  private var continuation: CheckedContinuation<Void, Never>?
  private var started = false
  private var entered: [CheckedContinuation<Void, Never>] = []
  func bearerToken(for reference: CredentialReference) async throws -> String? { nil }
  func invalidate(_ reference: CredentialReference) async {
    started = true
    for waiter in entered { waiter.resume() }
    entered = []
    await withCheckedContinuation { continuation = $0 }
  }
  func waitUntilStarted() async {
    if started { return }
    await withCheckedContinuation { entered.append($0) }
  }
  func resume() {
    continuation?.resume()
    continuation = nil
  }
}

private struct CheckFailure: Error { let message: String }

@main
struct ModelSettingsKeyValidation {
  @MainActor
  static func main() async throws {
    try await blockedStatusRefreshIsResponsive()
    let directory = FileManager.default.temporaryDirectory
      .appendingPathComponent("evie-key-validation-\(UUID().uuidString)", isDirectory: true)
    defer { try? FileManager.default.removeItem(at: directory) }
    let file = directory.appendingPathComponent("config.json")
    let store = EvieConfigurationStore(fileURL: file)
    let loader = EvieConfigurationLoader(fileURL: file)
    try store.save(.builtIn)
    let loaded = try loader.loadProfiles(environment: [:])
    let memory = MemoryKeys()
    let gate = SuspendedInvalidation()
    let viewModel = ModelSettingsViewModel(
      loaded: loaded, repairBaseline: loaded.profiles, store: store, loader: loader,
      keys: EvieModelKeys(items: memory, credentials: gate),
      onSave: { _ in }, onKeySaved: { _ in })
    let pc = try requireIndex(EvieModelProfile.pcProfileID, in: viewModel)
    let mac = try requireIndex(EvieModelProfile.macProfileID, in: viewModel)
    viewModel.editingProfileID = EvieModelProfile.pcProfileID
    viewModel.drafts[pc].endpoint = "https://new-model.example.invalid/v1"
    viewModel.drafts[pc].model = "unsaved-model"
    viewModel.drafts[mac].contextTokens = 65_536
    viewModel.preferredProfileID = EvieModelProfile.macProfileID
    viewModel.macFallback = .off
    viewModel.pastedKey = "synthetic-original-token"
    let task = Task { await viewModel.saveKey() }
    await gate.waitUntilStarted()
    // Emulate another settings writer while the key-cache invalidation awaits.
    _ = try store.saveProfiles(reading: loader, environment: [:], otherwise: loaded.profiles) {
      set, _ in
      try set.updateProfile(id: EvieModelProfile.pcProfileID) {
        $0.model = "externally-saved-model"
        $0.requestTimeout = 123
        $0.displayName = "Externally saved label"
      }
    }
    viewModel.drafts[pc].displayName = "Typed during await"
    viewModel.drafts[pc].endpoint = "https://typed-later.example.invalid/v1"
    viewModel.drafts[mac].defaultReasoning = .low
    viewModel.editingProfileID = EvieModelProfile.macProfileID
    viewModel.pastedKey = "synthetic-next-token"
    try check(viewModel.isSavingKey, "pending key save not marked busy")
    await viewModel.saveKey()
    try check(
      viewModel.pastedKey == "synthetic-next-token", "concurrent save consumed newly typed key")
    await gate.resume()
    await task.value
    let saved = try loader.loadProfiles(environment: [:])
    let savedPC = saved.profiles.profile(id: EvieModelProfile.pcProfileID)!
    try check(savedPC.model == "externally-saved-model", "key save overwrote fresh saved model")
    try check(savedPC.requestTimeout == 123, "key save overwrote fresh saved timeout")
    try check(savedPC.displayName == "Externally saved label", "key save persisted unsaved label")
    try check(
      savedPC.endpoint.absoluteString == "https://new-model.example.invalid/v1",
      "captured endpoint not saved")
    try check(
      savedPC.credential?.boundHost == "new-model.example.invalid", "key bound to wrong host")
    try check(viewModel.drafts[pc].model == "unsaved-model", "selected draft lost")
    try check(
      viewModel.drafts[pc].endpoint == "https://typed-later.example.invalid/v1",
      "endpoint typed during await lost or bound to the captured key")
    try check(
      viewModel.drafts[pc].displayName == "Typed during await", "concurrent label edit lost")
    try check(viewModel.drafts[pc].requestTimeout == 123, "unchanged draft field did not rebase")
    try check(viewModel.drafts[mac].contextTokens == 65_536, "other profile draft lost")
    try check(viewModel.drafts[mac].defaultReasoning == .low, "concurrent other profile edit lost")
    try check(
      viewModel.preferredProfileID == EvieModelProfile.macProfileID, "unsaved preference lost")
    try check(viewModel.macFallback == .off, "unsaved fallback lost")
    try check(viewModel.editingProfileID == EvieModelProfile.macProfileID, "editing selection lost")
    try check(viewModel.pastedKey == "synthetic-next-token", "new pasted key cleared")
    try check(viewModel.keyFeedback?.isError == false, "key save failed")
    try check(!viewModel.isSavingKey, "saving state did not settle")
    try check(
      saved.profiles.preferredProfile.id == loaded.profiles.preferredProfile.id,
      "key save persisted unsaved preferred profile")
    try check(
      saved.profiles.macFallback == loaded.profiles.macFallback,
      "key save persisted unsaved fallback")
    let serialized = try String(contentsOf: file, encoding: .utf8)
    try check(!serialized.contains("synthetic-original-token"), "secret serialized into JSON")
    print(
      "PASS: real settings VM + atomic JSON store; host binding, field rebase and edits during await preserved"
    )

    // A valid Keychain save followed by a refused newer configuration must
    // expose the partial result and leave both the file and typed drafts intact.
    let failureGate = SuspendedInvalidation()
    let failureModel = ModelSettingsViewModel(
      loaded: saved, repairBaseline: saved.profiles, store: store, loader: loader,
      keys: EvieModelKeys(items: memory, credentials: failureGate),
      onSave: { _ in }, onKeySaved: { _ in })
    failureModel.editingProfileID = EvieModelProfile.pcProfileID
    failureModel.drafts[pc].displayName = "Still unsaved after failure"
    failureModel.pastedKey = "synthetic-failure-token"
    let failureTask = Task { await failureModel.saveKey() }
    await failureGate.waitUntilStarted()
    let newer = Data("{\"schema_version\":999}".utf8)
    try newer.write(to: file)
    await failureGate.resume()
    await failureTask.value
    try check(try Data(contentsOf: file) == newer, "failed key save overwrote newer schema")
    try check(
      failureModel.drafts[pc].displayName == "Still unsaved after failure",
      "failed save discarded draft")
    try check(failureModel.keyFeedback?.isError == true, "partial save not reported as failure")
    try check(
      failureModel.keyFeedback?.message.contains("ficou no Keychain") == true,
      "partial save did not explain retained key")
    try check(!failureModel.isSavingKey, "failed save remained busy")
    print(
      "PASS: failed configuration save preserves newer JSON and drafts; Keychain partial result is explicit"
    )
  }

  @MainActor
  private static func blockedStatusRefreshIsResponsive() async throws {
    let items = BlockingStatusKeys()
    // Release from a non-main queue even on the broken implementation: the
    // regression reports a UI stall rather than hanging the test itself.
    DispatchQueue.global(qos: .utility).asyncAfter(deadline: .now() + .milliseconds(250)) {
      items.release()
    }
    let start = ContinuousClock.now
    let model = ModelSettingsViewModel(
      loaded: .builtIn, repairBaseline: .builtIn,
      keys: EvieModelKeys(items: items, credentials: StaticCredentialProvider()),
      onSave: { _ in }, onKeySaved: { _ in })
    try check(
      start.duration(to: .now) < .milliseconds(100),
      "main actor stalled in synchronous Keychain status during settings initialization")
    for _ in 0..<50 { model.refreshKeyStatus() }
    try check(start.duration(to: .now) < .milliseconds(100), "refresh blocked main actor")
    try await Task.sleep(for: .milliseconds(30))
    try check(items.calls == 1, "blocked status refreshes were not coalesced")
    let deadline = ContinuousClock.now + .seconds(2)
    while model.keyStatus[EvieModelProfile.pcProfileID] != .saved, ContinuousClock.now < deadline {
      try await Task.sleep(for: .milliseconds(5))
    }
    try check(
      model.keyStatus[EvieModelProfile.pcProfileID] == .saved,
      "released Keychain status never refreshed the settings cache")
    print("PASS: blocked Keychain attributes leave MainActor responsive and coalesce refreshes")
  }

  @MainActor
  private static func requireIndex(_ id: String, in model: ModelSettingsViewModel) throws -> Int {
    guard let index = model.drafts.firstIndex(where: { $0.profileID == id }) else {
      throw CheckFailure(message: "missing synthetic profile")
    }
    return index
  }

  private static func check(_ condition: Bool, _ message: String) throws {
    guard condition else { throw CheckFailure(message: message) }
  }
}
