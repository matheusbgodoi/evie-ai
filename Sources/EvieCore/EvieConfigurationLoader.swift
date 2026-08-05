import Foundation

/// Resolves non-secret local model settings without coupling the application to a
/// dotfile parser or a specific launch mechanism.
///
/// Precedence is: built-in defaults, the local JSON file, then environment
/// variables. The loader never reads credentials and never logs configuration.
public struct EvieConfigurationLoader: Sendable {
  public static let supportedSchemaVersion = 1

  public let fileURL: URL

  public init(fileURL: URL = EvieConfigurationLoader.defaultFileURL) {
    self.fileURL = fileURL
  }

  public func load(
    environment: [String: String] = ProcessInfo.processInfo.environment
  ) throws -> EvieConfiguration {
    var configuration = EvieConfiguration()
    let selectedFileURL = try resolvedFileURL(environment: environment)

    if FileManager.default.fileExists(atPath: selectedFileURL.path) {
      let file = try decodeFile(at: selectedFileURL)
      try apply(file.model, from: selectedFileURL, to: &configuration)
    }

    try apply(environment: environment, to: &configuration)
    try configuration.validate()
    return configuration
  }

  /// Resolves the local file selected by `EVIE_CONFIG_FILE` without reading it.
  /// Settings writers use this to update the same source that the loader reads.
  public func resolvedFileURL(
    environment: [String: String] = ProcessInfo.processInfo.environment
  ) throws -> URL {
    try configurationFileURL(environment: environment)
  }

  public static var defaultFileURL: URL {
    FileManager.default.urls(
      for: .applicationSupportDirectory,
      in: .userDomainMask
    )[0]
    .appendingPathComponent("Evie", isDirectory: true)
    .appendingPathComponent("config.json", isDirectory: false)
  }
}

extension EvieConfigurationLoader {
  public enum LoaderError: Error, Equatable, Sendable {
    case configurationPathMustBeAbsolute
    case unreadableFile(path: String, reason: String)
    case invalidFile(path: String, reason: String)
    case unsupportedSchemaVersion(Int)
    case invalidEnvironmentVariable(String)
  }
}

extension EvieConfigurationLoader.LoaderError: LocalizedError {
  public var errorDescription: String? {
    switch self {
    case .configurationPathMustBeAbsolute:
      "EVIE_CONFIG_FILE must resolve to an absolute path."
    case .unreadableFile(let path, let reason):
      "Could not read Evie configuration at \(path): \(reason)"
    case .invalidFile(let path, let reason):
      "Evie configuration at \(path) is invalid: \(reason)"
    case .unsupportedSchemaVersion(let version):
      "Evie configuration schema version \(version) is not supported."
    case .invalidEnvironmentVariable(let name):
      "Environment variable \(name) has an invalid value."
    }
  }
}

extension EvieConfigurationLoader {
  fileprivate struct ConfigurationFile: Decodable {
    let schemaVersion: Int
    let model: ModelOverrides
  }

  fileprivate struct ModelOverrides: Decodable {
    let endpoint: String?
    let name: String?
    let contextTokens: Int?
    let maxCompletionTokens: Int?
    let temperature: Double?
    let topP: Double?
    let stopSequences: [String]?
    let requestTimeoutSeconds: TimeInterval?
  }

  fileprivate func configurationFileURL(
    environment: [String: String]
  ) throws -> URL {
    guard let rawPath = environment["EVIE_CONFIG_FILE"], !rawPath.isEmpty else {
      return fileURL
    }

    let expandedPath = NSString(string: rawPath).expandingTildeInPath
    guard expandedPath.hasPrefix("/") else {
      throw LoaderError.configurationPathMustBeAbsolute
    }
    return URL(fileURLWithPath: expandedPath, isDirectory: false)
  }

  fileprivate func decodeFile(at url: URL) throws -> ConfigurationFile {
    let data: Data
    do {
      data = try Data(contentsOf: url, options: [.mappedIfSafe])
    } catch {
      throw LoaderError.unreadableFile(
        path: url.path,
        reason: error.localizedDescription
      )
    }

    let decoder = JSONDecoder()
    decoder.keyDecodingStrategy = .convertFromSnakeCase

    let file: ConfigurationFile
    do {
      file = try decoder.decode(ConfigurationFile.self, from: data)
    } catch {
      throw LoaderError.invalidFile(
        path: url.path,
        reason: error.localizedDescription
      )
    }

    guard file.schemaVersion == Self.supportedSchemaVersion else {
      throw LoaderError.unsupportedSchemaVersion(file.schemaVersion)
    }
    return file
  }

  fileprivate func apply(
    _ overrides: ModelOverrides,
    from sourceURL: URL,
    to configuration: inout EvieConfiguration
  ) throws {
    if let rawEndpoint = overrides.endpoint {
      guard let endpoint = URL(string: rawEndpoint) else {
        throw LoaderError.invalidFile(
          path: sourceURL.path,
          reason: "model.endpoint is not a URL"
        )
      }
      configuration.endpoint = endpoint
    }
    if let name = overrides.name {
      configuration.model = name
    }
    if let contextTokens = overrides.contextTokens {
      configuration.contextWindowTokens = contextTokens
    }
    if let maxCompletionTokens = overrides.maxCompletionTokens {
      configuration.maxCompletionTokens = maxCompletionTokens
    }
    if let temperature = overrides.temperature {
      configuration.temperature = temperature
    }
    if let topP = overrides.topP {
      configuration.topP = topP
    }
    if let stopSequences = overrides.stopSequences {
      configuration.stopSequences = stopSequences
    }
    if let requestTimeoutSeconds = overrides.requestTimeoutSeconds {
      configuration.requestTimeout = requestTimeoutSeconds
    }
  }

  fileprivate func apply(
    environment: [String: String],
    to configuration: inout EvieConfiguration
  ) throws {
    if let rawEndpoint = environment["EVIE_MODEL_ENDPOINT"] {
      guard let endpoint = URL(string: rawEndpoint) else {
        throw LoaderError.invalidEnvironmentVariable("EVIE_MODEL_ENDPOINT")
      }
      configuration.endpoint = endpoint
    }
    if let model = environment["EVIE_MODEL_NAME"] {
      configuration.model = model
    }
    if let value = try integer(
      named: "EVIE_MODEL_CONTEXT",
      environment: environment
    ) {
      configuration.contextWindowTokens = value
    }
    if let value = try integer(
      named: "EVIE_MODEL_MAX_COMPLETION",
      environment: environment
    ) {
      configuration.maxCompletionTokens = value
    }
    if let value = try double(
      named: "EVIE_MODEL_TEMPERATURE",
      environment: environment
    ) {
      configuration.temperature = value
    }
    if let value = try double(
      named: "EVIE_MODEL_TOP_P",
      environment: environment
    ) {
      configuration.topP = value
    }
    if let value = try double(
      named: "EVIE_MODEL_TIMEOUT_SECONDS",
      environment: environment
    ) {
      configuration.requestTimeout = value
    }
  }

  fileprivate func integer(
    named name: String,
    environment: [String: String]
  ) throws -> Int? {
    guard let rawValue = environment[name] else {
      return nil
    }
    guard let value = Int(rawValue) else {
      throw LoaderError.invalidEnvironmentVariable(name)
    }
    return value
  }

  fileprivate func double(
    named name: String,
    environment: [String: String]
  ) throws -> Double? {
    guard let rawValue = environment[name] else {
      return nil
    }
    guard let value = Double(rawValue), value.isFinite else {
      throw LoaderError.invalidEnvironmentVariable(name)
    }
    return value
  }
}
