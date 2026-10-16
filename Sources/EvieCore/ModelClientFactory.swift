import Foundation

/// The one place a model client is built.
///
/// Every construction site — the app, the settings reload, scheduled runs and
/// each diagnostic — goes through here, so the transport policy and the
/// credential source cannot differ between them. Before this existed there were
/// nine direct constructions, and a rule added to one of them would have been a
/// rule the other eight quietly lacked.
public struct ModelClientFactory: Sendable {
  /// The process-wide factory: the login keychain and the default allowlist.
  ///
  /// Shared so that every client in the process reads the same keychain cache,
  /// and invalidating a rejected key invalidates it for all of them.
  public static let live = ModelClientFactory(credentials: KeychainCredentialProvider())

  public let credentials: any EvieCredentialProviding
  public let transportPolicy: ModelTransportPolicy
  public let session: URLSession

  public init(
    credentials: any EvieCredentialProviding,
    transportPolicy: ModelTransportPolicy = ModelTransportPolicy(),
    session: URLSession = .shared
  ) {
    self.credentials = credentials
    self.transportPolicy = transportPolicy
    self.session = session
  }

  public func makeClient(configuration: EvieConfiguration) -> OpenAICompatibleClient {
    OpenAICompatibleClient(
      configuration: configuration,
      credentials: credentials,
      transportPolicy: transportPolicy,
      session: session
    )
  }
}
