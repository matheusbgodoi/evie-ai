import Foundation
import Testing

@testable import EvieCore

@Suite("Evie configuration store")
struct EvieConfigurationStoreTests {
  @Test("round-trips model preferences through the loader")
  func roundTrip() throws {
    let fileURL = temporaryFileURL()
    let configuration = EvieConfiguration(
      endpoint: URL(string: "http://127.0.0.1:9999/v1")!,
      model: "local-test-model",
      contextWindowTokens: 32_768,
      maxCompletionTokens: 2_048,
      temperature: 0.35,
      topP: 0.8,
      stopSequences: ["STOP"],
      requestTimeout: 45
    )

    try EvieConfigurationStore(fileURL: fileURL).save(configuration)
    let loaded = try EvieConfigurationLoader(fileURL: fileURL).load(environment: [:])

    #expect(loaded == configuration)
  }

  @Test("restricts the configuration directory and file to the current user")
  func permissions() throws {
    let fileURL = temporaryFileURL()

    try EvieConfigurationStore(fileURL: fileURL).save(EvieConfiguration())

    let fileAttributes = try FileManager.default.attributesOfItem(atPath: fileURL.path)
    let directoryAttributes = try FileManager.default.attributesOfItem(
      atPath: fileURL.deletingLastPathComponent().path
    )
    #expect((fileAttributes[.posixPermissions] as? NSNumber)?.intValue == 0o600)
    #expect((directoryAttributes[.posixPermissions] as? NSNumber)?.intValue == 0o700)
  }

  @Test("does not write an invalid configuration")
  func rejectsInvalidConfiguration() throws {
    let fileURL = temporaryFileURL()
    var configuration = EvieConfiguration()
    configuration.temperature = 3

    #expect(throws: EvieConfiguration.ValidationError.invalidTemperature) {
      try EvieConfigurationStore(fileURL: fileURL).save(configuration)
    }
    #expect(!FileManager.default.fileExists(atPath: fileURL.path))
  }

  @Test("a valid save atomically repairs an invalid selected file")
  func repairsInvalidFile() throws {
    let fileURL = temporaryFileURL()
    try FileManager.default.createDirectory(
      at: fileURL.deletingLastPathComponent(),
      withIntermediateDirectories: true
    )
    try Data("{not-valid-json".utf8).write(to: fileURL)
    var baseline = EvieConfiguration()
    baseline.temperature = 0.15

    try EvieConfigurationStore(fileURL: fileURL).save(baseline)
    let repaired = try EvieConfigurationLoader(fileURL: fileURL).load(environment: [:])

    #expect(repaired == baseline)
    let attributes = try FileManager.default.attributesOfItem(atPath: fileURL.path)
    #expect((attributes[.posixPermissions] as? NSNumber)?.intValue == 0o600)
  }
}

extension EvieConfigurationStoreTests {
  fileprivate func temporaryFileURL() -> URL {
    FileManager.default.temporaryDirectory
      .appendingPathComponent(UUID().uuidString, isDirectory: true)
      .appendingPathComponent("config.json", isDirectory: false)
  }
}
