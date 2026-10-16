import Foundation

/// Runtime configuration shared by Evie's model adapters.
///
/// It holds a *reference* to a credential — which keychain item, and the host
/// that item was saved for — and never the credential itself. The token is read
/// from the keychain at request time by an `EvieCredentialProviding`, so nothing
/// that encodes, logs or exports this value can carry a key.
public struct EvieConfiguration: Codable, Hashable, Sendable {
  /// The configuration Evie runs with when there is no file, or the file cannot
  /// be used: the preferred built-in profile, the PC, with its key reference.
  /// Every fallback resolves here, never to `EvieConfiguration()`, which has no
  /// key reference and so is refused by the transport policy for the PC.
  public static let builtIn = EvieModelProfileSet.builtIn.preferredProfile.configuration

  // The built-in profile's figures, kept as the memberwise defaults. They were
  // Gemma on 127.0.0.1:38433 with 65536 tokens until schema v2.
  public static let defaultEndpoint = builtIn.endpoint
  public static let defaultModel = builtIn.model
  public static let defaultContextWindow = builtIn.contextWindowTokens

  public var endpoint: URL
  public var model: String
  /// Expected server capacity. The server must still be launched with a matching
  /// context limit; Chat Completions has no per-request context field.
  public var contextWindowTokens: Int
  public var maxCompletionTokens: Int
  public var temperature: Double?
  public var topP: Double?
  public var stopSequences: [String]
  public var requestTimeout: TimeInterval
  /// Which saved key goes with this endpoint, if any. Plain-http loopback
  /// endpoints have none; a remote endpoint is refused without one.
  public var credential: CredentialReference?
  /// How this server is told whether to think. `.none` by default: the
  /// loopback Gemma server ignores every thinking parameter.
  public var thinkingStyle: ThinkingParameterStyle
  /// The reasoning an ordinary turn asks for. Off unless chosen: thinking costs
  /// seconds before the first word, and on the PC its sampler is the one with no
  /// repetition guard.
  public var defaultReasoning: ReasoningLevel
  /// The loopback port of a brain Evie starts on this Mac, nil for every
  /// other server. Only a request to `http://127.0.0.1:<this port>` carries the
  /// key that brain was started with (`LocalBrainKeyFile`, ADR 0017), the one
  /// exception to "no key over http".
  public var localBrainPort: Int?

  public init(
    endpoint: URL = EvieConfiguration.defaultEndpoint,
    model: String = EvieConfiguration.defaultModel,
    contextWindowTokens: Int = EvieConfiguration.defaultContextWindow,
    maxCompletionTokens: Int = 4_096,
    temperature: Double? = nil,
    topP: Double? = nil,
    stopSequences: [String] = [],
    requestTimeout: TimeInterval = 300,
    credential: CredentialReference? = nil,
    thinkingStyle: ThinkingParameterStyle = .none,
    defaultReasoning: ReasoningLevel = .off
  ) {
    self.endpoint = endpoint
    self.model = model
    self.contextWindowTokens = contextWindowTokens
    self.maxCompletionTokens = maxCompletionTokens
    self.temperature = temperature
    self.topP = topP
    self.stopSequences = stopSequences
    self.requestTimeout = requestTimeout
    self.credential = credential
    self.thinkingStyle = thinkingStyle
    self.defaultReasoning = defaultReasoning
  }

  public var chatCompletionsURL: URL {
    if endpoint.path.hasSuffix("/chat/completions") {
      return endpoint
    }
    return endpoint.appendingPathComponent("chat/completions")
  }

  public func validate() throws {
    guard let scheme = endpoint.scheme?.lowercased(),
      scheme == "http" || scheme == "https",
      endpoint.host != nil
    else {
      throw ValidationError.invalidEndpoint
    }

    guard !model.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
      throw ValidationError.emptyModel
    }
    guard contextWindowTokens > 0 else {
      throw ValidationError.invalidContextWindow
    }
    guard maxCompletionTokens > 0,
      maxCompletionTokens <= contextWindowTokens
    else {
      throw ValidationError.invalidCompletionLimit
    }
    if let temperature, !(0...2).contains(temperature) {
      throw ValidationError.invalidTemperature
    }
    if let topP, topP <= 0 || topP > 1 {
      throw ValidationError.invalidTopP
    }
    guard requestTimeout > 0 else {
      throw ValidationError.invalidTimeout
    }
  }

  public enum ValidationError: Error, Equatable, Sendable {
    case invalidEndpoint
    case emptyModel
    case invalidContextWindow
    case invalidCompletionLimit
    case invalidTemperature
    case invalidTopP
    case invalidTimeout
  }
}

extension EvieConfiguration.ValidationError: LocalizedError {
  public var errorDescription: String? {
    switch self {
    case .invalidEndpoint:
      "The agent endpoint must be an HTTP or HTTPS URL with a host."
    case .emptyModel:
      "The model identifier cannot be empty."
    case .invalidContextWindow:
      "The context window must contain at least one token."
    case .invalidCompletionLimit:
      "The completion limit must be positive and no larger than the context window."
    case .invalidTemperature:
      "Temperature must be between 0 and 2."
    case .invalidTopP:
      "Top-p must be greater than 0 and at most 1."
    case .invalidTimeout:
      "The request timeout must be greater than zero."
    }
  }
}
