import Foundation
import Security

/// Where a model endpoint's key is kept, never the key itself.
///
/// This is what configuration files may hold. `boundHost` records which host the
/// key was saved for: a request to any other host gets no token, so editing an
/// endpoint cannot redirect a saved key to a new machine.
public struct CredentialReference: Codable, Sendable, Hashable {
  public let service: String
  public let account: String
  public let boundHost: String

  public init(service: String, account: String, boundHost: String) {
    self.service = service
    self.account = account
    self.boundHost = boundHost
  }
}

/// Resolves a `CredentialReference` to a bearer token at request time.
public protocol EvieCredentialProviding: Sendable {
  /// The token, or `nil` when nothing is saved for that reference.
  func bearerToken(for reference: CredentialReference) async throws -> String?

  /// Drops any cached copy, so the next request reads the store again — for
  /// when the server has rejected the key.
  func invalidate(_ reference: CredentialReference) async
}

/// Reads tokens from the legacy login keychain as generic passwords.
///
/// The legacy keychain, not the data-protection one, because the latter needs an
/// application-identifier entitlement that a self-signed build without a team
/// cannot carry. A token is cached in memory after the first read so a turn does
/// not pay a keychain round trip; misses are not cached, so a key saved while
/// Evie runs is found on the next turn.
///
/// `SecItemCopyMatching` can block while macOS shows its access prompt. That
/// happens only for an item another program created; Evie's own item lists Evie
/// in its access control, so the prompt is not expected on the turn path.
public actor KeychainCredentialProvider: EvieCredentialProviding {
  private var cache: [CredentialReference: String] = [:]

  public init() {}

  public func bearerToken(for reference: CredentialReference) throws -> String? {
    if let cached = cache[reference] {
      return cached
    }
    guard let token = try Self.readGenericPassword(for: reference) else {
      return nil
    }
    cache[reference] = token
    return token
  }

  public func invalidate(_ reference: CredentialReference) {
    cache[reference] = nil
  }

  private static func readGenericPassword(for reference: CredentialReference) throws -> String? {
    let query: [CFString: Any] = [
      kSecClass: kSecClassGenericPassword,
      kSecAttrService: reference.service,
      kSecAttrAccount: reference.account,
      kSecReturnData: true,
      kSecMatchLimit: kSecMatchLimitOne,
      kSecUseDataProtectionKeychain: false,
    ]
    var result: CFTypeRef?
    let status = SecItemCopyMatching(query as CFDictionary, &result)
    return try token(status: status, data: result as? Data)
  }

  /// The mapping from a keychain answer to a token, kept apart so it can be
  /// tested without a keychain. A missing item is "no key", not an error; an
  /// empty or whitespace-only item is treated the same way.
  static func token(status: OSStatus, data: Data?) throws -> String? {
    switch status {
    case errSecSuccess:
      let token = data
        .flatMap { String(data: $0, encoding: .utf8) }?
        .trimmingCharacters(in: .whitespacesAndNewlines)
      guard let token, !token.isEmpty else { return nil }
      return token
    case errSecItemNotFound:
      return nil
    default:
      throw KeychainCredentialError(status: status)
    }
  }
}

/// A keychain failure other than "not found". Carries only the status, so the
/// message can never contain anything read from the item.
public struct KeychainCredentialError: Error, Equatable, Sendable, LocalizedError {
  public let status: OSStatus

  public var errorDescription: String? {
    let detail = SecCopyErrorMessageString(status, nil) as String? ?? "status \(status)"
    return "Could not read the model key from the keychain: \(detail)"
  }
}

/// Fixed tokens, for tests and for diagnostics that must not touch the keychain.
public struct StaticCredentialProvider: EvieCredentialProviding {
  public let tokens: [CredentialReference: String]

  public init(tokens: [CredentialReference: String] = [:]) {
    self.tokens = tokens
  }

  public func bearerToken(for reference: CredentialReference) async throws -> String? {
    tokens[reference]
  }

  public func invalidate(_ reference: CredentialReference) async {}
}
