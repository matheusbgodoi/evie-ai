import Foundation
import Security
import Synchronization
import Testing

@testable import EvieCore

/// Saving and importing the PC key, against an in-memory keychain.
///
/// The real login keychain is touched once, read-only, for an item that cannot
/// exist. Everything else goes through `MemoryKeychainItems`, which counts every
/// read, so "one read of the PC configuration's item" and "the status never reads
/// a secret" are checked rather than assumed.
@Suite("Evie model keys")
struct EvieModelKeysTests {
  private let reference = EvieModelProfileSet.builtIn.preferredProfile.credential!
  private var evieItem: KeychainItemName {
    KeychainItemName(service: reference.service, account: reference.account)
  }

  @Test("a pasted key is saved, trimmed, in Evie's own item, and the cached copy is dropped")
  func pastedKeyIsSaved() async throws {
    let items = MemoryKeychainItems()
    let credentials = InvalidationRecorder()
    let keys = EvieModelKeys(items: items, credentials: credentials)

    try await keys.save(pasted: "  sk-test-0123456789\n", for: reference)

    #expect(items.secret(at: evieItem) == "sk-test-0123456789")
    #expect(items.label(at: evieItem) == "Evie — chave do modelo (models.example.invalid)")
    #expect(await credentials.invalidated == [reference])
  }

  @Test("an empty paste is refused and nothing is written", arguments: ["", "   ", "\n\t"])
  func emptyPasteIsRefused(pasted: String) async {
    let items = MemoryKeychainItems()
    let keys = EvieModelKeys(items: items, credentials: InvalidationRecorder())

    await #expect(throws: EvieModelKeyError.empty) {
      try await keys.save(pasted: pasted, for: reference)
    }
    #expect(items.writes == 0)
  }

  @Test(
    "a paste that is not one key is refused, and the message does not repeat it",
    arguments: ["Bearer sk-test-0123456789", "sk-test\nsecond-line", "sk\u{0007}bell"]
  )
  func malformedPasteIsRefused(pasted: String) async {
    let items = MemoryKeychainItems()
    let keys = EvieModelKeys(items: items, credentials: InvalidationRecorder())

    await #expect(throws: EvieModelKeyError.malformed) {
      try await keys.save(pasted: pasted, for: reference)
    }
    #expect(items.writes == 0)
    let message = EvieModelKeyError.malformed.errorDescription ?? ""
    #expect(!message.contains("sk-test"))
  }

  @Test("the import reads the PC configuration's item once and copies it into Evie's")
  func importReadsTheSourceOnce() async throws {
    let items = MemoryKeychainItems()
    items.store("sk-from-the-pc-config", at: EvieModelKeys.pcConfigurationItem)
    let credentials = InvalidationRecorder()
    let keys = EvieModelKeys(items: items, credentials: credentials)

    try await keys.importPCConfigurationKey(into: reference)

    #expect(items.reads(of: EvieModelKeys.pcConfigurationItem) == 1)
    #expect(items.reads(of: evieItem) == 0)
    #expect(items.secret(at: evieItem) == "sk-from-the-pc-config")
    #expect(await credentials.invalidated == [reference])
  }

  @Test("the PC configuration's item is local-ai-3090 / gateway-api-key")
  func sourceItemName() {
    #expect(
      EvieModelKeys.pcConfigurationItem
        == KeychainItemName(service: "local-ai-3090", account: "gateway-api-key")
    )
  }

  @Test("no PC configuration item gives sourceMissing, and nothing is written")
  func missingSourceIsReported() async {
    let items = MemoryKeychainItems()
    let keys = EvieModelKeys(items: items, credentials: InvalidationRecorder())

    await #expect(throws: EvieModelKeyError.sourceMissing) {
      try await keys.importPCConfigurationKey(into: reference)
    }
    #expect(items.writes == 0)
  }

  @Test(
    "a refused or cancelled macOS prompt gives accessDenied, and nothing is written",
    arguments: [errSecUserCanceled, errSecAuthFailed, errSecInteractionNotAllowed]
  )
  func deniedPromptIsReported(status: OSStatus) async {
    let items = MemoryKeychainItems()
    items.failReads(of: EvieModelKeys.pcConfigurationItem, with: status)
    let keys = EvieModelKeys(items: items, credentials: InvalidationRecorder())

    await #expect(throws: EvieModelKeyError.accessDenied) {
      try await keys.importPCConfigurationKey(into: reference)
    }
    #expect(items.writes == 0)
  }

  @Test("a PC configuration item holding no usable key is refused like a bad paste")
  func emptySourceIsRefused() async {
    let items = MemoryKeychainItems()
    items.store("  \n", at: EvieModelKeys.pcConfigurationItem)
    let keys = EvieModelKeys(items: items, credentials: InvalidationRecorder())

    await #expect(throws: EvieModelKeyError.empty) {
      try await keys.importPCConfigurationKey(into: reference)
    }
    #expect(items.writes == 0)
  }

  @Test("the status says whether a key is saved without ever reading it")
  func statusReadsNoSecret() async {
    let items = MemoryKeychainItems()
    let keys = EvieModelKeys(items: items, credentials: InvalidationRecorder())

    let before = keys.status(of: reference)
    items.store("sk-test-0123456789", at: evieItem)
    let after = keys.status(of: reference)

    #expect(before == .missing)
    #expect(after == .saved)
    #expect(items.reads(of: evieItem) == 0)
    #expect(EvieModelKeyStatus.saved.text == "chave salva ✓")
    #expect(EvieModelKeyStatus.missing.text == "sem chave")
  }

  @Test("a keychain failure is reported with its status only")
  func keychainFailureCarriesOnlyTheStatus() {
    let error = EvieModelKeyError.keychain(errSecIO)
    #expect(error.errorDescription?.hasPrefix("O Keychain do macOS respondeu com um erro") == true)
  }

  // MARK: - Writing never reuses an item someone else made

  @Test("a write deletes whatever item is there, then adds a new one; it never updates")
  func writeDeletesThenAdds() throws {
    let calls = RecordedKeychainCalls(delete: errSecSuccess, add: [errSecSuccess])

    try LoginKeychainItems(calls: calls.calls).write("sk-new", to: evieItem, label: "Evie — L")

    #expect(calls.log == ["delete", "add"])
    let deleted = try #require(calls.deleted.first)
    #expect(deleted.service == reference.service)
    #expect(deleted.account == reference.account)
    #expect(deleted.data == nil)
    #expect(deleted.dataProtectionKeychain == false)
    let added = try #require(calls.added.first)
    #expect(added.service == reference.service)
    #expect(added.account == reference.account)
    #expect(added.data == Data("sk-new".utf8))
    #expect(added.label == "Evie — L")
    #expect(added.dataProtectionKeychain == false)
    // No access list is passed: an item SecItemAdd creates in the legacy
    // keychain trusts the program that created it, and only it.
    #expect(!added.carriesAccessList)
  }

  @Test("with no item there yet, the write just adds one")
  func writeWithoutAnItem() throws {
    let calls = RecordedKeychainCalls(delete: errSecItemNotFound, add: [errSecSuccess])

    try LoginKeychainItems(calls: calls.calls).write("sk-new", to: evieItem, label: "L")

    #expect(calls.log == ["delete", "add"])
  }

  @Test("an item that cannot be deleted is left alone and the key is not written anywhere")
  func undeletableItemStopsTheWrite() {
    let calls = RecordedKeychainCalls(delete: errSecAuthFailed, add: [errSecSuccess])

    #expect(throws: EvieModelKeyError.accessDenied) {
      try LoginKeychainItems(calls: calls.calls).write("sk-new", to: evieItem, label: "L")
    }
    #expect(calls.log == ["delete"])
  }

  @Test("an item made again between the delete and the add is refused, not updated")
  func squatterBetweenDeleteAndAdd() {
    let calls = RecordedKeychainCalls(delete: errSecSuccess, add: [errSecDuplicateItem])

    #expect(throws: EvieModelKeyError.keychain(errSecDuplicateItem)) {
      try LoginKeychainItems(calls: calls.calls).write("sk-new", to: evieItem, label: "L")
    }
    #expect(calls.log == ["delete", "add"])
  }

  @Test("the login keychain has no item under a name nobody uses")
  func loginKeychainLookupOfAMissingItem() throws {
    let item = KeychainItemName(
      service: "com.matheusbgodoi.evie.tests.\(UUID().uuidString)",
      account: "absent"
    )

    #expect(try LoginKeychainItems().contains(item) == false)
  }
}

// MARK: - Stand-ins

/// The Security calls a keychain write makes, answered from a script and
/// recorded in order, with what they were given.
final class RecordedKeychainCalls: Sendable {
  /// The parts of a query or an item a test looks at.
  struct Item: Sendable {
    let service: String?
    let account: String?
    let label: String?
    let data: Data?
    let dataProtectionKeychain: Bool?
    let carriesAccessList: Bool

    init(_ dictionary: [CFString: Any]) {
      service = dictionary[kSecAttrService] as? String
      account = dictionary[kSecAttrAccount] as? String
      label = dictionary[kSecAttrLabel] as? String
      data = dictionary[kSecValueData] as? Data
      dataProtectionKeychain = dictionary[kSecUseDataProtectionKeychain] as? Bool
      carriesAccessList = dictionary[kSecAttrAccess] != nil
    }
  }

  private struct State {
    var log: [String] = []
    var deleted: [Item] = []
    var added: [Item] = []
    var addStatuses: [OSStatus]
  }

  private let deleteStatus: OSStatus
  private let state: Mutex<State>

  init(delete: OSStatus, add: [OSStatus]) {
    deleteStatus = delete
    state = Mutex(State(addStatuses: add))
  }

  var log: [String] { state.withLock { $0.log } }
  var deleted: [Item] { state.withLock { $0.deleted } }
  var added: [Item] { state.withLock { $0.added } }

  var calls: KeychainWriteCalls {
    KeychainWriteCalls(
      delete: { query in
        let item = Item(query)
        self.state.withLock { state in
          state.log.append("delete")
          state.deleted.append(item)
        }
        return self.deleteStatus
      },
      add: { attributes in
        let item = Item(attributes)
        return self.state.withLock { state in
          state.log.append("add")
          state.added.append(item)
          return state.addStatuses.isEmpty ? errSecSuccess : state.addStatuses.removeFirst()
        }
      }
    )
  }
}

/// A keychain in memory that counts reads and writes per item. Shared with
/// `EviePermissionGuideBrainTests`, which drives the guide's import through it.
final class MemoryKeychainItems: EvieKeychainItems {
  private struct State {
    var secrets: [KeychainItemName: String] = [:]
    var labels: [KeychainItemName: String] = [:]
    var failures: [KeychainItemName: OSStatus] = [:]
    var reads: [KeychainItemName: Int] = [:]
    var writes = 0
  }

  private let state = Mutex(State())

  func contains(_ item: KeychainItemName) throws -> Bool {
    state.withLock { $0.secrets[item] != nil }
  }

  func read(_ item: KeychainItemName) throws -> String? {
    let (secret, failure) = state.withLock { state in
      state.reads[item, default: 0] += 1
      return (state.secrets[item], state.failures[item])
    }
    if let failure {
      throw EvieModelKeyError(status: failure)
    }
    return secret
  }

  func write(_ secret: String, to item: KeychainItemName, label: String) throws {
    state.withLock { state in
      state.writes += 1
      state.secrets[item] = secret
      state.labels[item] = label
    }
  }

  func store(_ secret: String, at item: KeychainItemName) {
    state.withLock { $0.secrets[item] = secret }
  }

  func failReads(of item: KeychainItemName, with status: OSStatus) {
    state.withLock { $0.failures[item] = status }
  }

  func secret(at item: KeychainItemName) -> String? {
    state.withLock { $0.secrets[item] }
  }

  func label(at item: KeychainItemName) -> String? {
    state.withLock { $0.labels[item] }
  }

  func reads(of item: KeychainItemName) -> Int {
    state.withLock { $0.reads[item] ?? 0 }
  }

  var writes: Int {
    state.withLock { $0.writes }
  }
}

/// No tokens, and a record of which references were invalidated.
actor InvalidationRecorder: EvieCredentialProviding {
  private(set) var invalidated: [CredentialReference] = []

  func bearerToken(for reference: CredentialReference) -> String? {
    nil
  }

  func invalidate(_ reference: CredentialReference) {
    invalidated.append(reference)
  }
}
