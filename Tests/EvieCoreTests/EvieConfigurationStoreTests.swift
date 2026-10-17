import Foundation
import Testing

@testable import EvieCore

@Suite("Evie configuration store")
struct EvieConfigurationStoreTests {
  @Test("round-trips model preferences through the loader")
  func roundTrip() throws {
    let fileURL = temporaryFileURL()
    var profiles = EvieModelProfileSet.builtIn
    try profiles.updateProfile(id: "pc-3090") { profile in
      profile.endpoint = URL(string: "http://127.0.0.1:9999/v1")!
      profile.model = "local-test-model"
      profile.contextTokens = 32_768
      profile.maxCompletionTokens = 2_048
      profile.temperature = 0.35
      profile.topP = 0.8
      profile.stopSequences = ["STOP"]
      profile.requestTimeout = 45
    }

    try EvieConfigurationStore(fileURL: fileURL).save(profiles)
    let loaded = try EvieConfigurationLoader(fileURL: fileURL).loadProfiles(environment: [:])

    #expect(loaded.profiles == profiles)
    #expect(loaded.configuration == profiles.preferredProfile.configuration)
  }

  @Test("restricts the configuration directory and file to the current user")
  func permissions() throws {
    let fileURL = temporaryFileURL()

    try EvieConfigurationStore(fileURL: fileURL).save(.builtIn)

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
    var profiles = EvieModelProfileSet.builtIn
    try profiles.updateProfile(id: "pc-3090") { $0.temperature = 3 }

    #expect(
      throws: EvieModelProfileSet.ValidationError.invalidProfile(
        id: "pc-3090",
        reason: .invalidTemperature
      )
    ) {
      try EvieConfigurationStore(fileURL: fileURL).save(profiles)
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
    var baseline = EvieModelProfileSet.builtIn
    try baseline.updateProfile(id: "pc-3090") { $0.temperature = 0.15 }

    try EvieConfigurationStore(fileURL: fileURL).save(baseline)
    let repaired = try EvieConfigurationLoader(fileURL: fileURL).loadProfiles(environment: [:])

    #expect(repaired.profiles == baseline)
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
