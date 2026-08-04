import Foundation

/// Runtime configuration shared by Evie's local agent adapters.
///
/// It intentionally contains no API key or credential field. Secrets for future
/// integrations belong in Keychain-backed adapters, not this Codable value.
public struct EvieConfiguration: Codable, Hashable, Sendable {
  public static let turboFieldfareEndpoint = URL(
    string: "http://127.0.0.1:8080/v1"
  )!
  public static let turboFieldfareModel = "gemma-4-26b-a4b-it"
  public static let turboFieldfareContextWindow = 65_536

  public var endpoint: URL
  public var model: String
  /// Expected server capacity. TurboFieldfare must still be launched with a
  /// matching `--max-context`; Chat Completions has no per-request context field.
  public var contextWindowTokens: Int
  public var maxCompletionTokens: Int
  public var temperature: Double?
  public var topP: Double?
  public var stopSequences: [String]
  public var requestTimeout: TimeInterval

  public init(
    endpoint: URL = EvieConfiguration.turboFieldfareEndpoint,
    model: String = EvieConfiguration.turboFieldfareModel,
    contextWindowTokens: Int = EvieConfiguration.turboFieldfareContextWindow,
    maxCompletionTokens: Int = 4_096,
    temperature: Double? = nil,
    topP: Double? = nil,
    stopSequences: [String] = [],
    requestTimeout: TimeInterval = 300
  ) {
    self.endpoint = endpoint
    self.model = model
    self.contextWindowTokens = contextWindowTokens
    self.maxCompletionTokens = maxCompletionTokens
    self.temperature = temperature
    self.topP = topP
    self.stopSequences = stopSequences
    self.requestTimeout = requestTimeout
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
