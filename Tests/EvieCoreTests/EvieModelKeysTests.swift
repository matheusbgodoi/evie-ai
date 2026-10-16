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
    #expect(items.label(at: evieItem) == "Evie — chave do modelo (ai-node-3090.tail6146ef.ts.net)")
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

/// A keychain in memory that counts reads and writes per item.
private final class MemoryKeychainItems: EvieKeychainItems {
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
private actor InvalidationRecorder: EvieCredentialProviding {
  private(set) var invalidated: [CredentialReference] = []

  func bearerToken(for reference: CredentialReference) -> String? {
    nil
  }

  func invalidate(_ reference: CredentialReference) {
    invalidated.append(reference)
  }
}
