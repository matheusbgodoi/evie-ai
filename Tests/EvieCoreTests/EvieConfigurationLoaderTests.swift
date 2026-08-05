import Foundation
import Testing

@testable import EvieCore

@Suite("Evie configuration loader")
struct EvieConfigurationLoaderTests {
  @Test("uses defaults when no local configuration exists")
  func defaults() throws {
    let loader = EvieConfigurationLoader(fileURL: missingFileURL())
    let configuration = try loader.load(environment: [:])

    #expect(configuration.endpoint == EvieConfiguration.turboFieldfareEndpoint)
    #expect(configuration.model == EvieConfiguration.turboFieldfareModel)
    #expect(configuration.contextWindowTokens == 65_536)
  }

  @Test("environment overrides the local file")
  func precedence() throws {
    let fileURL = try configurationFile(
      """
      {
        "schema_version": 1,
        "model": {
          "endpoint": "http://localhost:8081/v1",
          "name": "file-model",
          "context_tokens": 32768,
          "max_completion_tokens": 2048,
          "temperature": 0.2,
          "top_p": 0.95,
          "stop_sequences": ["STOP"],
          "request_timeout_seconds": 120
        }
      }
      """
    )
    let loader = EvieConfigurationLoader(fileURL: fileURL)
    let configuration = try loader.load(
      environment: [
        "EVIE_MODEL_NAME": "environment-model",
        "EVIE_MODEL_CONTEXT": "65536",
        "EVIE_MODEL_MAX_COMPLETION": "4096",
      ]
    )

    #expect(configuration.endpoint.absoluteString == "http://localhost:8081/v1")
    #expect(configuration.model == "environment-model")
    #expect(configuration.contextWindowTokens == 65_536)
    #expect(configuration.maxCompletionTokens == 4_096)
    #expect(configuration.temperature == 0.2)
    #expect(configuration.stopSequences == ["STOP"])
  }

  @Test("rejects malformed environment values without echoing them")
  func invalidEnvironment() throws {
    let loader = EvieConfigurationLoader(fileURL: missingFileURL())

    #expect(
      throws: EvieConfigurationLoader.LoaderError.invalidEnvironmentVariable(
        "EVIE_MODEL_CONTEXT"
      )
    ) {
      try loader.load(environment: ["EVIE_MODEL_CONTEXT": "not-a-number"])
    }
  }

  @Test("rejects unsupported local schema versions")
  func unsupportedSchema() throws {
    let fileURL = try configurationFile(
      """
      {"schema_version": 99, "model": {}}
      """
    )
    let loader = EvieConfigurationLoader(fileURL: fileURL)

    #expect(
      throws: EvieConfigurationLoader.LoaderError.unsupportedSchemaVersion(99)
    ) {
      try loader.load(environment: [:])
    }
  }

  @Test("resolves the same absolute file selected by the environment")
  func selectedFileURL() throws {
    let selectedURL = missingFileURL().standardizedFileURL
    let loader = EvieConfigurationLoader()

    let resolved = try loader.resolvedFileURL(
      environment: ["EVIE_CONFIG_FILE": selectedURL.path]
    )

    #expect(resolved.standardizedFileURL == selectedURL)
  }
}

extension EvieConfigurationLoaderTests {
  fileprivate func missingFileURL() -> URL {
    FileManager.default.temporaryDirectory
      .appendingPathComponent(UUID().uuidString, isDirectory: true)
      .appendingPathComponent("config.json", isDirectory: false)
  }

  fileprivate func configurationFile(_ contents: String) throws -> URL {
    let directory = FileManager.default.temporaryDirectory
      .appendingPathComponent(UUID().uuidString, isDirectory: true)
    try FileManager.default.createDirectory(
      at: directory,
      withIntermediateDirectories: true
    )
    let fileURL = directory.appendingPathComponent("config.json", isDirectory: false)
    try Data(contents.utf8).write(to: fileURL, options: [.atomic])
    return fileURL
  }
}
