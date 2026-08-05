import Foundation

/// Persists Evie's non-secret model preferences in the same versioned JSON
/// format consumed by `EvieConfigurationLoader`.
///
/// Credentials intentionally have no representation here. The parent directory
/// and file are restricted to the current user after every write.
public struct EvieConfigurationStore: Sendable {
  public let fileURL: URL

  public init(fileURL: URL = EvieConfigurationLoader.defaultFileURL) {
    self.fileURL = fileURL
  }

  public func save(_ configuration: EvieConfiguration) throws {
    try configuration.validate()

    let directoryURL = fileURL.deletingLastPathComponent()
    try FileManager.default.createDirectory(
      at: directoryURL,
      withIntermediateDirectories: true,
      attributes: [.posixPermissions: 0o700]
    )
    try FileManager.default.setAttributes(
      [.posixPermissions: 0o700],
      ofItemAtPath: directoryURL.path
    )

    let document = ConfigurationDocument(
      schemaVersion: EvieConfigurationLoader.supportedSchemaVersion,
      model: ModelDocument(configuration: configuration)
    )
    let encoder = JSONEncoder()
    encoder.keyEncodingStrategy = .convertToSnakeCase
    encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
    var data = try encoder.encode(document)
    data.append(0x0A)
    try data.write(to: fileURL, options: .atomic)
    try FileManager.default.setAttributes(
      [.posixPermissions: 0o600],
      ofItemAtPath: fileURL.path
    )
  }
}

extension EvieConfigurationStore {
  fileprivate struct ConfigurationDocument: Encodable {
    let schemaVersion: Int
    let model: ModelDocument
  }

  fileprivate struct ModelDocument: Encodable {
    let endpoint: String
    let name: String
    let contextTokens: Int
    let maxCompletionTokens: Int
    let temperature: Double?
    let topP: Double?
    let stopSequences: [String]
    let requestTimeoutSeconds: TimeInterval

    init(configuration: EvieConfiguration) {
      endpoint = configuration.endpoint.absoluteString
      name = configuration.model
      contextTokens = configuration.contextWindowTokens
      maxCompletionTokens = configuration.maxCompletionTokens
      temperature = configuration.temperature
      topP = configuration.topP
      stopSequences = configuration.stopSequences
      requestTimeoutSeconds = configuration.requestTimeout
    }
  }
}
