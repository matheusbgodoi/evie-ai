import Foundation
import Testing

@testable import EvieCore

@Suite("Local runtime profile persistence")
struct LocalRuntimePersistenceTests {
  @Test("the real configuration store and loader preserve every bounded runtime control")
  func boundedProfileRoundTrip() throws {
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: directory) }
    let file = directory.appendingPathComponent("config.json")
    var profiles = EvieModelProfileSet.builtIn
    try profiles.updateProfile(id: "mac-local") { profile in
      if case .localOnDemand(var runtime) = profile.runtime {
        runtime.kvBits = 8
        runtime.prefillStepSize = 512
        runtime.metalCacheLimitMB = 256
        profile.runtime = .localOnDemand(runtime)
      }
    }
    try EvieConfigurationStore(fileURL: file).save(profiles)
    let loaded = try EvieConfigurationLoader(fileURL: file).loadProfiles(
      environment: ["EVIE_MODEL_PROFILE": "mac-local"])
    #expect(loaded.profiles == profiles)
    let expected = try #require(profiles.profile(id: "mac-local"))
    #expect(loaded.activeProfile.runtime == expected.runtime)
    let bytes = try Data(contentsOf: file)
    let document = try #require(JSONSerialization.jsonObject(with: bytes) as? [String: Any])
    let stored = try #require(document["profiles"] as? [[String: Any]])
    let mac = try #require(stored.first(where: { $0["id"] as? String == "mac-local" }))
    let runtime = try #require(mac["runtime"] as? [String: Any])
    #expect(runtime["kv_bits"] as? Int == 8)
    #expect(runtime["prefill_step_size"] as? Int == 512)
    #expect(runtime["metal_cache_limit_mb"] as? Int == 256)
  }

  @Test("a legacy schema-v2 local profile without optional controls loads as nil and stays legacy")
  func legacyProfileWithoutOptionalControls() throws {
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: directory) }
    let file = directory.appendingPathComponent("config.json")
    var profiles = EvieModelProfileSet.builtIn
    try profiles.updateProfile(id: "mac-local") { profile in
      if case .localOnDemand(var runtime) = profile.runtime {
        runtime.kvBits = nil
        runtime.prefillStepSize = nil
        runtime.metalCacheLimitMB = nil
        profile.runtime = .localOnDemand(runtime)
      }
    }
    try EvieConfigurationStore(fileURL: file).save(profiles)
    let bytes = try Data(contentsOf: file)
    let text = String(decoding: bytes, as: UTF8.self)
    #expect(!text.contains("kv_bits"))
    #expect(!text.contains("prefill_step_size"))
    #expect(!text.contains("metal_cache_limit_mb"))
    let loaded = try EvieConfigurationLoader(fileURL: file).loadProfiles(environment: [:])
    #expect(loaded.profiles == profiles)
    let local = try #require(loaded.profiles.profile(id: "mac-local"))
    guard case .localOnDemand(let runtime) = local.runtime else {
      Issue.record("The legacy local profile must remain an on-demand runtime.")
      return
    }
    #expect(runtime.kvBits == nil)
    #expect(runtime.prefillStepSize == nil)
    #expect(runtime.metalCacheLimitMB == nil)
    #expect(LocalBrainPolicy.makeArguments(runtime, model: local.model).first == "--model")
  }
}
