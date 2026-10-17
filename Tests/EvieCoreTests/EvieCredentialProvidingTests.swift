import Foundation
import Security
import Testing

@testable import EvieCore

@Suite("Model credential providers")
struct EvieCredentialProvidingTests {
  private let reference = CredentialReference(
    service: "com.matheusbgodoi.evie.model",
    account: "pc-3090",
    boundHost: "models.example.invalid"
  )

  @Test("a keychain hit becomes the token, without its trailing newline")
  func keychainHit() throws {
    let token = try KeychainCredentialProvider.token(
      status: errSecSuccess,
      data: Data("abc123\n".utf8)
    )

    #expect(token == "abc123")
  }

  @Test("a missing or blank keychain item is no key, not an error")
  func keychainMiss() throws {
    #expect(try KeychainCredentialProvider.token(status: errSecItemNotFound, data: nil) == nil)
    #expect(
      try KeychainCredentialProvider.token(status: errSecSuccess, data: Data(" \n".utf8)) == nil
    )
    #expect(try KeychainCredentialProvider.token(status: errSecSuccess, data: nil) == nil)
  }

  @Test("any other keychain status is an error that carries only the status")
  func keychainFailure() {
    #expect(throws: KeychainCredentialError(status: errSecAuthFailed)) {
      try KeychainCredentialProvider.token(status: errSecAuthFailed, data: Data("abc".utf8))
    }
  }

  /// Read-only and against an item nobody creates, so it shows no prompt and
  /// changes nothing — but it does go through the real `SecItemCopyMatching`.
  @Test("the login keychain answers a reference to an absent item with no key")
  func absentKeychainItem() async throws {
    let absent = CredentialReference(
      service: "com.matheusbgodoi.evie.test.absent-\(UUID().uuidString)",
      account: "nobody",
      boundHost: "stub.evie.test"
    )

    let token = try await KeychainCredentialProvider().bearerToken(for: absent)

    #expect(token == nil)
  }

  @Test("a static token is found only under the exact reference, host included")
  func staticProviderMatchesWholeReference() async throws {
    let provider = StaticCredentialProvider(tokens: [reference: "abc"])
    let rebound = CredentialReference(
      service: reference.service,
      account: reference.account,
      boundHost: "evil.example"
    )

    #expect(try await provider.bearerToken(for: reference) == "abc")
    #expect(try await provider.bearerToken(for: rebound) == nil)
  }

  @Test("a credential reference encodes no secret, only where to find one")
  func referenceEncoding() throws {
    let data = try JSONEncoder().encode(reference)
    let keys = try #require(
      JSONSerialization.jsonObject(with: data) as? [String: String]
    )

    #expect(Set(keys.keys) == ["service", "account", "boundHost"])
  }
}
