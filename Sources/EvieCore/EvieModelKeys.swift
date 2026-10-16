import Foundation
import Security

/// A generic password's place in the keychain: its service and account.
public struct KeychainItemName: Sendable, Hashable {
  public let service: String
  public let account: String

  public init(service: String, account: String) {
    self.service = service
    self.account = account
  }

  public init(_ reference: CredentialReference) {
    self.init(service: reference.service, account: reference.account)
  }
}

/// Generic passwords by name: whether one exists, its secret, and writing one.
///
/// A protocol so the key import can be tested without a keychain.
/// `LoginKeychainItems` is the real one.
public protocol EvieKeychainItems: Sendable {
  /// Whether the item exists. Reads attributes only, never the secret, so it
  /// never shows the macOS access prompt and can run on every refresh.
  func contains(_ item: KeychainItemName) throws -> Bool
  /// The item's secret, or `nil` when there is no such item. For an item another
  /// program created, macOS asks the person first and this call waits for the
  /// answer.
  func read(_ item: KeychainItemName) throws -> String?
  /// Creates the item, or replaces the secret of the one already there.
  func write(_ secret: String, to item: KeychainItemName, label: String) throws
}

/// The legacy login keychain, the same one `KeychainCredentialProvider` reads.
///
/// An item this process creates lists this application, by its code signature,
/// as the one program allowed to read it without asking. That is why Evie keeps
/// its own copy of the PC key instead of reading the PC configuration's item on
/// every turn: that item belongs to another program, and each read of it would
/// be a prompt.
public struct LoginKeychainItems: EvieKeychainItems {
  public init() {}

  public func contains(_ item: KeychainItemName) throws -> Bool {
    var query = Self.query(for: item)
    query[kSecReturnAttributes] = true
    query[kSecMatchLimit] = kSecMatchLimitOne
    var result: CFTypeRef?
    let status = SecItemCopyMatching(query as CFDictionary, &result)
    switch status {
    case errSecSuccess: return true
    case errSecItemNotFound: return false
    default: throw EvieModelKeyError(status: status)
    }
  }

  public func read(_ item: KeychainItemName) throws -> String? {
    var query = Self.query(for: item)
    query[kSecReturnData] = true
    query[kSecMatchLimit] = kSecMatchLimitOne
    var result: CFTypeRef?
    let status = SecItemCopyMatching(query as CFDictionary, &result)
    switch status {
    case errSecSuccess:
      return (result as? Data).flatMap { String(data: $0, encoding: .utf8) }
    case errSecItemNotFound:
      return nil
    default:
      throw EvieModelKeyError(status: status)
    }
  }

  public func write(_ secret: String, to item: KeychainItemName, label: String) throws {
    let data = Data(secret.utf8)
    var attributes = Self.query(for: item)
    attributes[kSecValueData] = data
    attributes[kSecAttrLabel] = label
    let added = SecItemAdd(attributes as CFDictionary, nil)
    switch added {
    case errSecSuccess:
      return
    case errSecDuplicateItem:
      // Replacing the secret keeps the item's access list: the program that
      // created it — Evie, or the `-T` list `Scripts/evie-app import-pc-key`
      // gave — stays the one allowed to read it.
      let updated = SecItemUpdate(
        Self.query(for: item) as CFDictionary,
        [kSecValueData: data, kSecAttrLabel: label] as CFDictionary
      )
      guard updated == errSecSuccess else {
        throw EvieModelKeyError(status: updated)
      }
    default:
      throw EvieModelKeyError(status: added)
    }
  }

  private static func query(for item: KeychainItemName) -> [CFString: Any] {
    [
      kSecClass: kSecClassGenericPassword,
      kSecAttrService: item.service,
      kSecAttrAccount: item.account,
      // The legacy keychain: the data-protection one needs an
      // application-identifier entitlement this self-signed build cannot have.
      kSecUseDataProtectionKeychain: false,
    ]
  }
}

/// Whether a profile's key is saved, as the settings pane shows it. The pane
/// never shows the key itself.
public enum EvieModelKeyStatus: Sendable, Equatable {
  case saved
  case missing
  /// The keychain could not be asked; the message says why.
  case unknown(String)

  public var text: String {
    switch self {
    case .saved: "chave salva ✓"
    case .missing: "sem chave"
    case .unknown(let reason): "não consegui ver a chave: \(reason)"
    }
  }
}

/// Why a key was not saved. Every message is the person's to read, in
/// Portuguese, and none of them carries anything read from a keychain item or
/// typed into the key field.
public enum EvieModelKeyError: Error, Sendable, Equatable {
  case empty
  /// More than one key, a `Bearer` prefix, a line break or a control character.
  case malformed
  /// There is no `local-ai-3090` / `gateway-api-key` item on this Mac.
  case sourceMissing
  /// The person refused or closed the macOS prompt.
  case accessDenied
  case keychain(OSStatus)

  /// The error for a keychain status other than success or "not found".
  public init(status: OSStatus) {
    switch status {
    case errSecUserCanceled, errSecAuthFailed, errSecInteractionNotAllowed:
      self = .accessDenied
    default:
      self = .keychain(status)
    }
  }
}

extension EvieModelKeyError: LocalizedError {
  public var errorDescription: String? {
    switch self {
    case .empty:
      "A chave está vazia. Cole a chave do gateway do PC."
    case .malformed:
      "Isso não parece uma chave só: cole a chave sem \"Bearer\", sem espaços e numa linha."
    case .sourceMissing:
      "Não achei a configuração do PC neste Mac (item local-ai-3090 / gateway-api-key "
        + "no Keychain). Cole a chave à mão."
    case .accessDenied:
      "O macOS não liberou a leitura da chave. Tente de novo e escolha Permitir."
    case .keychain(let status):
      "O Keychain do macOS respondeu com um erro ("
        + (SecCopyErrorMessageString(status, nil) as String? ?? "status \(status)") + ")."
    }
  }
}

/// Saves the PC key into Evie's own keychain item, pasted or copied from the
/// PC configuration's item, and says whether one is saved.
///
/// The copy is made once: the PC configuration's item (`local-ai-3090` /
/// `gateway-api-key`, written by the PC stack's setup on this Mac) belongs to
/// another program, so reading it shows the macOS prompt. After one read the key
/// lives in Evie's item — the profile's `CredentialReference`, by default
/// `com.matheusbgodoi.evie.model` / `pc-3090` — which Evie reads without asking.
public struct EvieModelKeys: Sendable {
  public static let pcConfigurationItem = KeychainItemName(
    service: "local-ai-3090",
    account: "gateway-api-key"
  )

  /// The login keychain and the process's shared key cache, so a key saved here
  /// replaces the one every client has cached.
  public static let live = EvieModelKeys(
    items: LoginKeychainItems(),
    credentials: ModelClientFactory.live.credentials
  )

  private let items: any EvieKeychainItems
  private let credentials: any EvieCredentialProviding

  public init(items: any EvieKeychainItems, credentials: any EvieCredentialProviding) {
    self.items = items
    self.credentials = credentials
  }

  public func status(of reference: CredentialReference) -> EvieModelKeyStatus {
    do {
      return try items.contains(KeychainItemName(reference)) ? .saved : .missing
    } catch {
      return .unknown((error as? LocalizedError)?.errorDescription ?? "\(error)")
    }
  }

  /// Saves what the person pasted.
  public func save(pasted: String, for reference: CredentialReference) async throws {
    try await store(Self.normalized(pasted), for: reference)
  }

  /// Reads the PC configuration's item once and saves a copy into Evie's.
  ///
  /// The read waits for the person to answer the macOS prompt, so it runs on a
  /// thread of its own rather than holding one of the cooperative pool's.
  public func importPCConfigurationKey(into reference: CredentialReference) async throws {
    let items = items
    let source = try await Self.offTheCooperativePool {
      try items.read(Self.pcConfigurationItem)
    }
    guard let source else {
      throw EvieModelKeyError.sourceMissing
    }
    try await store(Self.normalized(source), for: reference)
  }

  private func store(_ key: String, for reference: CredentialReference) async throws {
    try items.write(
      key,
      to: KeychainItemName(reference),
      label: "Evie — chave do modelo (\(reference.boundHost))"
    )
    // Every client in the process reads through one cache; a replaced key must
    // not keep being sent from it.
    await credentials.invalidate(reference)
  }

  /// The key as it will be sent: surrounding whitespace removed, and refused
  /// when what is left is not one printable token.
  static func normalized(_ raw: String) throws -> String {
    let key = raw.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !key.isEmpty else {
      throw EvieModelKeyError.empty
    }
    let printable = key.unicodeScalars.allSatisfy { (0x21...0x7E).contains($0.value) }
    guard printable, key.count <= 4_096 else {
      throw EvieModelKeyError.malformed
    }
    return key
  }

  private static func offTheCooperativePool<T: Sendable>(
    _ work: @escaping @Sendable () throws -> T
  ) async throws -> T {
    try await withCheckedThrowingContinuation { continuation in
      Thread.detachNewThread {
        continuation.resume(with: Result { try work() })
      }
    }
  }
}
