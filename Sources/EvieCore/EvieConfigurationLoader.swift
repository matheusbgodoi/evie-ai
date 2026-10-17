import Foundation

/// Resolves non-secret local model settings without coupling the application to a
/// dotfile parser or a specific launch mechanism.
///
/// Precedence is: the built-in profiles, the local JSON file, then environment
/// variables. `EVIE_MODEL_PROFILE` picks the profile in use; the other
/// `EVIE_MODEL_*` variables override that profile for this run only. The loader
/// never reads credentials and never logs configuration.
///
/// It writes in one case: a schema v1 file is migrated to v2 in place, with the
/// original bytes kept beside it as `config.json.v1.bak`. Otherwise every Settings
/// save would meet a v1 file again, and the v1 endpoint — the loopback Gemma —
/// would keep competing with the built-in PC.
public struct EvieConfigurationLoader: Sendable {
  public static let supportedSchemaVersion = 2
  /// The single-endpoint schema, still read so that it can be migrated.
  public static let legacySchemaVersion = 1

  public let fileURL: URL

  public init(fileURL: URL = EvieConfigurationLoader.defaultFileURL) {
    self.fileURL = fileURL
  }

  /// The configuration of the profile in use.
  public func load(
    environment: [String: String] = ProcessInfo.processInfo.environment
  ) throws -> EvieConfiguration {
    try loadProfiles(environment: environment).configuration
  }

  /// Every profile in the file and the one in use. Throws when the file or the
  /// environment cannot be used; `loadWithDiagnostics` is the non-throwing form.
  public func loadProfiles(
    environment: [String: String] = ProcessInfo.processInfo.environment
  ) throws -> EvieLoadedConfiguration {
    let selectedFileURL = try resolvedFileURL(environment: environment)
    var profiles = EvieModelProfileSet.builtIn
    if FileManager.default.fileExists(atPath: selectedFileURL.path) {
      profiles = try readProfiles(at: selectedFileURL)
    }

    var active = try activeProfile(in: profiles, environment: environment)
    try apply(environment: environment, to: &active)
    try active.configuration.validate()
    do { try active.validateContextCapacity() } catch {
      throw LoaderError.invalidEnvironmentVariable("EVIE_MODEL_CONTEXT")
    }
    do {
      try active.validateLocalEndpoint()
    } catch {
      // The file's endpoint passed `profiles.validate()`, so the override
      // moved it.
      throw LoaderError.invalidEnvironmentVariable("EVIE_MODEL_ENDPOINT")
    }
    return EvieLoadedConfiguration(profiles: profiles, activeProfile: active)
  }

  /// Same resolution as `loadProfiles`, but a file or environment that cannot be
  /// used yields the built-in set — the PC — together with the reason, which the
  /// app shows as "Configuração local inválida". Launch never blocks on it.
  public func loadWithDiagnostics(
    environment: [String: String] = ProcessInfo.processInfo.environment
  ) -> (loaded: EvieLoadedConfiguration, failure: (any Error)?) {
    do {
      return (try loadProfiles(environment: environment), nil)
    } catch {
      return (.builtIn, error)
    }
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

/// What the loader resolved: the set as the file has it, and the profile in use.
public struct EvieLoadedConfiguration: Sendable, Equatable {
  /// The profiles without environment overrides, which is what a save writes
  /// back: a variable set for one run must not end up in the file.
  public let profiles: EvieModelProfileSet
  /// The profile `EVIE_MODEL_PROFILE` or the preference order chose, with the
  /// `EVIE_MODEL_*` overrides applied.
  public let activeProfile: EvieModelProfile

  public init(profiles: EvieModelProfileSet, activeProfile: EvieModelProfile) {
    self.profiles = profiles
    self.activeProfile = activeProfile
  }

  public var configuration: EvieConfiguration {
    activeProfile.configuration
  }

  public static let builtIn = EvieLoadedConfiguration(
    profiles: .builtIn,
    activeProfile: EvieModelProfileSet.builtIn.preferredProfile
  )
}

extension EvieConfigurationLoader {
  public enum LoaderError: Error, Equatable, Sendable {
    case configurationPathMustBeAbsolute
    case unreadableFile(path: String, reason: String)
    case invalidFile(path: String, reason: String)
    case unsupportedSchemaVersion(Int)
    case invalidEnvironmentVariable(String)
    case migrationFailed(path: String, reason: String)
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
    case .migrationFailed(let path, let reason):
      "Could not rewrite the Evie configuration at \(path) in the current format: \(reason)"
    }
  }
}

extension EvieConfigurationLoader {
  fileprivate struct SchemaHeader: Decodable {
    let schemaVersion: Int

    enum CodingKeys: String, CodingKey {
      case schemaVersion = "schema_version"
    }
  }

  /// Schema v1: one endpoint, every field optional, each absent field meaning
  /// the v1 built-in default.
  fileprivate struct LegacyFile: Decodable {
    let model: LegacyModel
  }

  fileprivate struct LegacyModel: Decodable {
    let endpoint: String?
    let name: String?
    let contextTokens: Int?
    let maxCompletionTokens: Int?
    let temperature: Double?
    let topP: Double?
    let stopSequences: [String]?
    let requestTimeoutSeconds: TimeInterval?
  }

  /// What a v1 file's absent fields meant when it was written: the loopback
  /// Gemma served by `Scripts/evie-runtime`. Kept only for migration.
  fileprivate static let legacyDefaults = EvieModelProfile(
    id: EvieModelProfile.customProfileID,
    displayName: "Personalizado",
    endpoint: URL(string: "http://127.0.0.1:38433/v1")!,
    model: "gemma-4-26b-a4b-it",
    contextTokens: 65_536,
    maxCompletionTokens: 4_096,
    // v1 offered tools and never sent pixels: images reached the model as OCR
    // text and a description.
    capabilities: .init(vision: false, tools: true),
    thinkingStyle: .none,
    runtime: .remoteGateway,
    location: .thisMac,
    family: .gemma,
    coordinateConvention: .pixels
  )

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

  /// Decodes the `schema_version` header first and branches on it: v2 is read
  /// as it is, v1 is migrated and written back, anything else is refused.
  fileprivate func readProfiles(at url: URL) throws -> EvieModelProfileSet {
    let data: Data
    do {
      data = try Data(contentsOf: url, options: [.mappedIfSafe])
    } catch {
      throw LoaderError.unreadableFile(
        path: url.path,
        reason: error.localizedDescription
      )
    }

    let version = try decode(SchemaHeader.self, from: data, at: url).schemaVersion
    let profiles: EvieModelProfileSet
    switch version {
    case Self.supportedSchemaVersion:
      // No key strategy: every v2 type names its keys.
      profiles = try decode(EvieModelProfileSet.self, from: data, at: url)
    case Self.legacySchemaVersion:
      let legacy = try decode(LegacyFile.self, from: data, at: url, snakeCase: true)
      profiles = try migrated(legacy.model, from: url)
    default:
      throw LoaderError.unsupportedSchemaVersion(version)
    }

    do {
      try profiles.validate()
    } catch {
      throw LoaderError.invalidFile(path: url.path, reason: error.localizedDescription)
    }

    if version == Self.legacySchemaVersion {
      do {
        // The backup is written from the bytes read above, not copied from the
        // file: a second process migrating at the same moment may already have
        // replaced the file with v2, and copying that would lose the v1 original.
        try EvieConfigurationStore(fileURL: url).replaceLegacyFile(
          originalBytes: data,
          with: profiles
        )
      } catch {
        throw LoaderError.migrationFailed(path: url.path, reason: error.localizedDescription)
      }
    }
    return profiles
  }

  fileprivate func decode<T: Decodable>(
    _ type: T.Type,
    from data: Data,
    at url: URL,
    snakeCase: Bool = false
  ) throws -> T {
    let decoder = JSONDecoder()
    if snakeCase {
      decoder.keyDecodingStrategy = .convertFromSnakeCase
    }
    do {
      return try decoder.decode(type, from: data)
    } catch {
      throw LoaderError.invalidFile(
        path: url.path,
        reason: error.localizedDescription
      )
    }
  }

  /// The v1 endpoint becomes the profile `custom`, appended after the built-ins
  /// and left out of the preference order, so the PC still wins unless the
  /// person selects it by name.
  fileprivate func migrated(
    _ legacy: LegacyModel,
    from sourceURL: URL
  ) throws -> EvieModelProfileSet {
    var custom = Self.legacyDefaults
    if let rawEndpoint = legacy.endpoint {
      guard let endpoint = URL(string: rawEndpoint) else {
        throw LoaderError.invalidFile(
          path: sourceURL.path,
          reason: "model.endpoint is not a URL"
        )
      }
      custom.endpoint = endpoint
    }
    if let name = legacy.name {
      custom.model = name
    }
    if let contextTokens = legacy.contextTokens {
      custom.contextTokens = contextTokens
    }
    if let maxCompletionTokens = legacy.maxCompletionTokens {
      custom.maxCompletionTokens = maxCompletionTokens
    }
    if let temperature = legacy.temperature {
      custom.temperature = temperature
    }
    if let topP = legacy.topP {
      custom.topP = topP
    }
    if let stopSequences = legacy.stopSequences {
      custom.stopSequences = stopSequences
    }
    if let requestTimeoutSeconds = legacy.requestTimeoutSeconds {
      custom.requestTimeout = requestTimeoutSeconds
    }
    custom.location =
      ModelTransportPolicy.isLoopback(custom.endpoint.host ?? "") ? .thisMac : .yourPC
    custom.family = ModelFamily(guessingFromModel: custom.model)
    custom.coordinateConvention = custom.family == .qwen ? .normalized1000 : .pixels

    var profiles = EvieModelProfileSet.builtIn
    profiles.profiles.append(custom)
    return profiles
  }

  fileprivate func activeProfile(
    in profiles: EvieModelProfileSet,
    environment: [String: String]
  ) throws -> EvieModelProfile {
    guard let id = environment["EVIE_MODEL_PROFILE"], !id.isEmpty else {
      return profiles.preferredProfile
    }
    guard let profile = profiles.profile(id: id) else {
      throw LoaderError.invalidEnvironmentVariable("EVIE_MODEL_PROFILE")
    }
    return profile
  }

  fileprivate func apply(
    environment: [String: String],
    to profile: inout EvieModelProfile
  ) throws {
    if let rawEndpoint = environment["EVIE_MODEL_ENDPOINT"] {
      guard let endpoint = URL(string: rawEndpoint) else {
        throw LoaderError.invalidEnvironmentVariable("EVIE_MODEL_ENDPOINT")
      }
      profile.endpoint = endpoint
    }
    if let model = environment["EVIE_MODEL_NAME"] {
      profile.model = model
    }
    if let value = try integer(
      named: "EVIE_MODEL_CONTEXT",
      environment: environment
    ) {
      profile.contextTokens = value
    }
    if let value = try integer(
      named: "EVIE_MODEL_MAX_COMPLETION",
      environment: environment
    ) {
      profile.maxCompletionTokens = value
    }
    if let value = try double(
      named: "EVIE_MODEL_TEMPERATURE",
      environment: environment
    ) {
      profile.temperature = value
    }
    if let value = try double(
      named: "EVIE_MODEL_TOP_P",
      environment: environment
    ) {
      profile.topP = value
    }
    if let value = try double(
      named: "EVIE_MODEL_TIMEOUT_SECONDS",
      environment: environment
    ) {
      profile.requestTimeout = value
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
