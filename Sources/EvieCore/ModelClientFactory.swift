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
  public static let live: ModelClientFactory = {
    let loader = EvieConfigurationLoader()
    let file = (try? loader.resolvedFileURL()) ?? EvieConfigurationLoader.defaultFileURL
    return ModelClientFactory(
      credentials: KeychainCredentialProvider(),
      transportPolicy: ModelTransportPolicy(allowedRemoteHosts: [], trustedConfigurationURL: file))
  }()

  /// One session for every model request in the process, built from
  /// `URLSessionConfiguration.evieModel`: no disk cache, a fifteen-minute cap.
  public static let modelSession = URLSession(configuration: .evieModel)

  public let credentials: any EvieCredentialProviding
  public let transportPolicy: ModelTransportPolicy
  public let session: URLSession
  public let deadlines: ModelDeadlinePolicy
  /// Where the Mac brain's per-launch key is read from, for requests to its
  /// own loopback port only.
  public let localBrainKey: LocalBrainKeyFile

  public init(
    credentials: any EvieCredentialProviding,
    transportPolicy: ModelTransportPolicy = ModelTransportPolicy(),
    session: URLSession = ModelClientFactory.modelSession,
    deadlines: ModelDeadlinePolicy = .standard,
    localBrainKey: LocalBrainKeyFile = .standard
  ) {
    self.credentials = credentials
    self.transportPolicy = transportPolicy
    self.session = session
    self.deadlines = deadlines
    self.localBrainKey = localBrainKey
  }

  public func makeClient(configuration: EvieConfiguration) -> OpenAICompatibleClient {
    OpenAICompatibleClient(
      configuration: configuration,
      credentials: credentials,
      transportPolicy: transportPolicy,
      session: session,
      deadlines: deadlines,
      localBrainKey: localBrainKey
    )
  }
}
