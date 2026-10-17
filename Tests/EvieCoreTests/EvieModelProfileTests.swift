import Foundation
import Testing

@testable import EvieCore

@Suite("Evie model profiles")
struct EvieModelProfileTests {
  @Test("a profile cannot promise more context than its configured server")
  func contextExceedsServer() {
    var set = EvieModelProfileSet.builtIn
    set.profiles[0].contextTokens = 200_705
    #expect(throws: (any Error).self) { try set.validate() }
  }

  @Test("a local profile cannot exceed its launched KV capacity")
  func contextExceedsLocalRuntime() {
    var set = EvieModelProfileSet.builtIn
    guard case .localOnDemand(let runtime) = set.profiles[1].runtime else { return }
    set.profiles[1].serverContextTokens = nil
    set.profiles[1].contextTokens = runtime.maxKVSize + 1
    #expect(throws: (any Error).self) { try set.validate() }
  }

  @Test("the public provider example loads without an owner connection")
  func publicProviderExample() throws {
    let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
      .deletingLastPathComponent().deletingLastPathComponent()
    let file = root.appendingPathComponent("config/examples/model-v2.example.json")
    let loaded = try EvieConfigurationLoader(fileURL: file).loadProfiles(environment: [:])
    #expect(loaded.activeProfile.displayName == "Minha IA")
    #expect(loaded.activeProfile.endpoint.host == "models.example.invalid")
    #expect(loaded.activeProfile.credential?.boundHost == loaded.activeProfile.endpoint.host)
    #expect(loaded.activeProfile.runtime == .remoteGateway)
  }

  @Test("the PC RTX 3090 is the built-in default, with its key reference and no key")
  func pcProfile() throws {
    let set = EvieModelProfileSet.builtIn
    let pc = try #require(set.profile(id: "pc-3090"))

    #expect(set.preferredProfile.id == "pc-3090")
    #expect(set.preferenceOrder == ["pc-3090", "mac-local"])
    #expect(set.macFallback == .ask)
    #expect(pc.displayName == "PC RTX 3090")
    #expect(pc.endpoint.absoluteString == "https://models.example.invalid/v1")
    #expect(pc.model == "qwen-daily")
    #expect(pc.contextTokens == 200_704)
    #expect(pc.serverContextTokens == 200_704)
    #expect(pc.maxCompletionTokens == 16_384)
    #expect(pc.capabilities == .init(vision: true, tools: true))
    #expect(pc.thinkingStyle == .templateKwargs)
    #expect(pc.defaultReasoning == .off)
    #expect(
      pc.credential
        == CredentialReference(
          service: "com.matheusbgodoi.evie.model",
          account: "pc-3090",
          boundHost: "models.example.invalid"
        )
    )
    #expect(pc.runtime == .remoteGateway)
    #expect(pc.location == .yourPC)
    #expect(pc.family == .qwen)
    #expect(pc.coordinateConvention == .normalized1000)
  }

  @Test("the Mac profile looks without tools and names the exact model it serves")
  func macProfile() throws {
    let mac = try #require(EvieModelProfileSet.builtIn.profile(id: "mac-local"))

    #expect(mac.displayName == "Mac local")
    #expect(mac.endpoint.absoluteString == "http://127.0.0.1:38480/v1")
    #expect(mac.model == "mlx-community/LensVLM-9B-OptiQ-4bit")
    #expect(mac.contextTokens == 131_072)
    #expect(mac.serverContextTokens == 131_072)
    #expect(mac.maxCompletionTokens == 2_048)
    #expect(mac.capabilities == .init(vision: true, tools: false))
    #expect(mac.thinkingStyle == .topLevel)
    #expect(mac.defaultReasoning == .off)
    #expect(mac.credential == nil)
    #expect(mac.location == .thisMac)
    guard case .localOnDemand(let runtime) = mac.runtime else {
      Issue.record("the Mac profile must be started on demand, got \(mac.runtime)")
      return
    }
    #expect(runtime.port == 38_480)
    #expect(runtime.maxKVSize == 131_072)
    #expect(runtime.kvBits == 8)
    #expect(runtime.prefillStepSize == 512)
    #expect(runtime.metalCacheLimitMB == 256)
    #expect(runtime.executable.hasPrefix("/"))
  }

  @Test("every built-in profile passes the transport policy and validates")
  func builtInsAreUsable() throws {
    try EvieModelProfileSet.builtIn.validate()
    for profile in EvieModelProfileSet.builtIn.profiles {
      let verdict = ModelTransportPolicy().evaluate(
        profile.endpoint,
        credentialHost: profile.credential?.boundHost
      )
      #expect(verdict == .allowed, "\(profile.id)")
    }
  }

  @Test("a profile becomes the configuration the client reads")
  func configurationFromProfile() throws {
    let pc = try #require(EvieModelProfileSet.builtIn.profile(id: "pc-3090"))
    let configuration = pc.configuration

    #expect(configuration.endpoint == pc.endpoint)
    #expect(configuration.model == "qwen-daily")
    #expect(configuration.contextWindowTokens == 200_704)
    #expect(configuration.maxCompletionTokens == 16_384)
    #expect(configuration.credential == pc.credential)
    #expect(configuration.thinkingStyle == .templateKwargs)
    #expect(configuration.defaultReasoning == .off)
    #expect(configuration.requestTimeout == pc.requestTimeout)
  }

  @Test("the configuration defaults are the built-in PC, not Gemma on 38433")
  func configurationDefaults() {
    #expect(EvieConfiguration.builtIn == EvieModelProfileSet.builtIn.preferredProfile.configuration)
    #expect(EvieConfiguration.defaultEndpoint.host == "models.example.invalid")
    #expect(EvieConfiguration.defaultModel == "qwen-daily")
    #expect(EvieConfiguration.defaultContextWindow == 200_704)
  }

  @Test("a set with a repeated id, an unknown preference or no profiles is refused")
  func setValidation() throws {
    var repeated = EvieModelProfileSet.builtIn
    repeated.profiles.append(repeated.profiles[0])
    #expect(throws: EvieModelProfileSet.ValidationError.duplicateProfileID("pc-3090")) {
      try repeated.validate()
    }

    var unknown = EvieModelProfileSet.builtIn
    unknown.preferenceOrder = ["pc-3090", "nowhere"]
    #expect(throws: EvieModelProfileSet.ValidationError.unknownProfileInOrder("nowhere")) {
      try unknown.validate()
    }

    var empty = EvieModelProfileSet.builtIn
    empty.profiles = []
    empty.preferenceOrder = []
    #expect(throws: EvieModelProfileSet.ValidationError.noProfiles) {
      try empty.validate()
    }

    var relative = EvieModelProfileSet.builtIn
    try relative.updateProfile(id: "mac-local") { profile in
      profile.runtime = .localOnDemand(
        LocalRuntime(
          launcher: .mlxVLM, executable: "mlx_vlm.server", port: 38_480, maxKVSize: 32_768)
      )
    }
    #expect(throws: EvieModelProfileSet.ValidationError.invalidLocalRuntime(id: "mac-local")) {
      try relative.validate()
    }
  }

  @Test("a Mac brain's address is the one Evie starts it on: 127.0.0.1, its own port, /v1")
  func localEndpointIsTheRuntimes() throws {
    let mac = try #require(EvieModelProfileSet.builtIn.profile(id: "mac-local"))
    guard case .localOnDemand(let runtime) = mac.runtime else {
      Issue.record("the Mac profile must be started on demand")
      return
    }
    #expect(runtime.endpoint == mac.endpoint)

    let elsewhere = [
      "http://127.0.0.1:9999/v1",
      "http://localhost:38480/v1",
      "http://[::1]:38480/v1",
      "https://127.0.0.1:38480/v1",
      "http://127.0.0.1/v1",
      "http://127.0.0.1:38480/v2",
      "http://127.0.0.1:38480/v1/chat/completions",
      "http://evie@127.0.0.1:38480/v1",
    ]
    for address in elsewhere {
      var set = EvieModelProfileSet.builtIn
      try set.updateProfile(id: "mac-local") { $0.endpoint = URL(string: address)! }
      #expect(
        throws: EvieModelProfileSet.ValidationError.localEndpointMismatch(
          id: "mac-local", expected: "http://127.0.0.1:38480/v1"),
        "\(address)"
      ) {
        try set.validate()
      }
    }

    var trailingSlash = EvieModelProfileSet.builtIn
    try trailingSlash.updateProfile(id: "mac-local") {
      $0.endpoint = URL(string: "http://127.0.0.1:38480/v1/")!
    }
    try trailingSlash.validate()
  }

  @Test("the preferred profile is the first one in the order that exists")
  func preferredProfile() throws {
    var set = EvieModelProfileSet.builtIn
    set.preferenceOrder = ["mac-local", "pc-3090"]
    #expect(set.preferredProfile.id == "mac-local")

    set.preferenceOrder = []
    #expect(set.preferredProfile.id == set.profiles[0].id)
  }
}

@Suite("Evie configuration schema v2")
struct EvieConfigurationSchemaV2Tests {
  @Test("a v1 file becomes a v2 set with the built-ins first and its own profile kept")
  func migratesV1() throws {
    let original = """
      {
        "schema_version": 1,
        "model": {
          "endpoint": "http://127.0.0.1:38433/v1",
          "name": "gemma-4-26b-a4b-it",
          "max_completion_tokens": 2048,
          "temperature": 0.2,
          "top_p": 0.95,
          "stop_sequences": ["STOP"]
        }
      }
      """
    let fileURL = try configurationFile(original)

    let loaded = try EvieConfigurationLoader(fileURL: fileURL).loadProfiles(environment: [:])

    #expect(loaded.profiles.profiles.map(\.id) == ["pc-3090", "mac-local", "custom"])
    #expect(loaded.profiles.preferenceOrder == ["pc-3090", "mac-local"])
    #expect(loaded.activeProfile.id == "pc-3090")
    let custom = try #require(loaded.profiles.profile(id: "custom"))
    #expect(custom.endpoint.absoluteString == "http://127.0.0.1:38433/v1")
    #expect(custom.model == "gemma-4-26b-a4b-it")
    // Absent from the file, so the v1 default it meant then: 65536.
    #expect(custom.contextTokens == 65_536)
    #expect(custom.maxCompletionTokens == 2_048)
    #expect(custom.temperature == 0.2)
    #expect(custom.topP == 0.95)
    #expect(custom.stopSequences == ["STOP"])
    #expect(custom.requestTimeout == 300)
    #expect(custom.credential == nil)
    #expect(custom.thinkingStyle == .none)
    #expect(custom.capabilities == .init(vision: false, tools: true))
    #expect(custom.location == .thisMac)
    #expect(custom.family == .gemma)

    let backupURL = fileURL.appendingPathExtension("v1.bak")
    #expect(try Data(contentsOf: backupURL) == Data(original.utf8))
    #expect(try permissions(of: backupURL) == 0o600)
    #expect(try schemaVersion(of: fileURL) == 2)
    #expect(try permissions(of: fileURL) == 0o600)

    // The rewritten file reads back as the same set, and is not migrated twice.
    let reread = try EvieConfigurationLoader(fileURL: fileURL).loadProfiles(environment: [:])
    #expect(reread.profiles == loaded.profiles)
    #expect(try Data(contentsOf: backupURL) == Data(original.utf8))
  }

  @Test("version 99 gives the built-ins and a diagnostic, without throwing or writing")
  func unknownVersion() throws {
    let contents = #"{"schema_version": 99, "profiles": []}"#
    let fileURL = try configurationFile(contents)

    let (loaded, failure) = EvieConfigurationLoader(fileURL: fileURL)
      .loadWithDiagnostics(environment: [:])

    #expect(loaded.profiles == .builtIn)
    #expect(loaded.activeProfile.id == "pc-3090")
    #expect(
      failure as? EvieConfigurationLoader.LoaderError == .unsupportedSchemaVersion(99)
    )
    #expect(try Data(contentsOf: fileURL) == Data(contents.utf8))
    #expect(!FileManager.default.fileExists(atPath: fileURL.appendingPathExtension("v1.bak").path))
  }

  @Test("a load failure yields the built-in PC profile, not Gemma on 38433")
  func failureFallsBackToBuiltIn() throws {
    let fileURL = try configurationFile("{not-valid-json")

    let (loaded, failure) = EvieConfigurationLoader(fileURL: fileURL)
      .loadWithDiagnostics(environment: [:])

    #expect(failure != nil)
    #expect(loaded.configuration == EvieConfiguration.builtIn)
    #expect(loaded.configuration.endpoint.host == "models.example.invalid")
    #expect(loaded.configuration.endpoint.port != 38_433)
  }

  @Test("a missing file is the built-in set with no diagnostic")
  func missingFile() throws {
    let (loaded, failure) = EvieConfigurationLoader(fileURL: missingFileURL())
      .loadWithDiagnostics(environment: [:])

    #expect(failure == nil)
    #expect(loaded.profiles == .builtIn)
    #expect(loaded.configuration == .builtIn)
  }

  @Test("a v2 set round-trips through the store and is written as v2")
  func storeRoundTrip() throws {
    let fileURL = missingFileURL()
    var set = EvieModelProfileSet.builtIn
    set.macFallback = .automatic
    set.preferenceOrder = ["mac-local", "pc-3090"]
    try set.updateProfile(id: "pc-3090") { profile in
      profile.contextTokens = 100_000
      profile.defaultReasoning = .low
      profile.temperature = 0.35
      profile.stopSequences = ["FIM"]
    }

    try EvieConfigurationStore(fileURL: fileURL).save(set)
    let loaded = try EvieConfigurationLoader(fileURL: fileURL).loadProfiles(environment: [:])

    #expect(try schemaVersion(of: fileURL) == 2)
    #expect(loaded.profiles == set)
    #expect(loaded.activeProfile.id == "mac-local")
  }

  @Test("the file holds where the key is kept, never a key")
  func noSecretInJSON() throws {
    let fileURL = missingFileURL()
    try EvieConfigurationStore(fileURL: fileURL).save(.builtIn)
    let json = try String(contentsOf: fileURL, encoding: .utf8)
    let object = try #require(
      try JSONSerialization.jsonObject(with: Data(json.utf8)) as? [String: Any]
    )
    let profiles = try #require(object["profiles"] as? [[String: Any]])
    let pc = try #require(profiles.first { $0["id"] as? String == "pc-3090" })

    #expect(
      pc["credential"] as? [String: String]
        == [
          "service": "com.matheusbgodoi.evie.model",
          "account": "pc-3090",
          "bound_host": "models.example.invalid",
        ]
    )
    for forbidden in [#""token""#, #""key""#, "api_key", "apiKey", "password", "secret", "Bearer"] {
      #expect(!json.contains(forbidden), "\(forbidden)")
    }
  }

  @Test("the settings save keeps a v2 file v2 and changes only the profile in use")
  func settingsSaveKeepsV2() throws {
    let fileURL = missingFileURL()
    var set = EvieModelProfileSet.builtIn
    set.profiles.append(customProfile())
    try EvieConfigurationStore(fileURL: fileURL).save(set)

    let saved = try EvieConfigurationStore(fileURL: fileURL).saveActiveProfile(
      reading: EvieConfigurationLoader(fileURL: fileURL),
      environment: [:],
      otherwise: .builtIn
    ) { profile in
      profile.temperature = 0.4
      profile.maxCompletionTokens = 4_096
    }

    let reread = try EvieConfigurationLoader(fileURL: fileURL).loadProfiles(environment: [:])
    #expect(try schemaVersion(of: fileURL) == 2)
    #expect(reread.profiles == saved)
    #expect(reread.profiles.profiles.map(\.id) == ["pc-3090", "mac-local", "custom"])
    #expect(reread.activeProfile.temperature == 0.4)
    #expect(reread.activeProfile.maxCompletionTokens == 4_096)
    #expect(reread.profiles.profile(id: "mac-local") == set.profile(id: "mac-local"))
    #expect(reread.profiles.profile(id: "custom") == set.profile(id: "custom"))
  }

  @Test("the settings save edits the profile EVIE_MODEL_PROFILE selected")
  func settingsSaveFollowsSelection() throws {
    let fileURL = missingFileURL()
    try EvieConfigurationStore(fileURL: fileURL).save(.builtIn)

    _ = try EvieConfigurationStore(fileURL: fileURL).saveActiveProfile(
      reading: EvieConfigurationLoader(fileURL: fileURL),
      environment: ["EVIE_MODEL_PROFILE": "mac-local", "EVIE_MODEL_NAME": "not-saved"],
      otherwise: .builtIn
    ) { profile in
      profile.requestTimeout = 45
    }

    let reread = try EvieConfigurationLoader(fileURL: fileURL).loadProfiles(environment: [:])
    #expect(reread.profiles.profile(id: "mac-local")?.requestTimeout == 45)
    #expect(
      reread.profiles.profile(id: "mac-local")?.model == "mlx-community/LensVLM-9B-OptiQ-4bit")
    #expect(
      reread.profiles.profile(id: "pc-3090") == EvieModelProfileSet.builtIn.profile(id: "pc-3090"))
  }

  @Test("the settings save turns a v1 file into v2 instead of writing v1 back")
  func settingsSaveMigratesV1() throws {
    let fileURL = try configurationFile(
      #"{"schema_version": 1, "model": {"name": "file-model"}}"#
    )

    _ = try EvieConfigurationStore(fileURL: fileURL).saveActiveProfile(
      reading: EvieConfigurationLoader(fileURL: fileURL),
      environment: [:],
      otherwise: .builtIn
    ) { profile in
      profile.temperature = nil
    }

    let reread = try EvieConfigurationLoader(fileURL: fileURL).loadProfiles(environment: [:])
    #expect(try schemaVersion(of: fileURL) == 2)
    #expect(reread.profiles.profile(id: "custom")?.model == "file-model")
  }

  @Test("the settings save repairs a damaged file from the baseline it was given")
  func settingsSaveRepairs() throws {
    let fileURL = try configurationFile("{not-valid-json")
    var baseline = EvieModelProfileSet.builtIn
    baseline.macFallback = .off

    let saved = try EvieConfigurationStore(fileURL: fileURL).saveActiveProfile(
      reading: EvieConfigurationLoader(fileURL: fileURL),
      environment: [:],
      otherwise: baseline
    ) { profile in
      profile.topP = 0.8
    }

    #expect(saved.macFallback == .off)
    #expect(saved.preferredProfile.topP == 0.8)
    #expect(
      try EvieConfigurationLoader(fileURL: fileURL).loadProfiles(environment: [:]).profiles == saved
    )
  }

  @Test("the settings save keeps a damaged file as config.json.damaged.bak before repairing it")
  func settingsSaveBacksUpDamagedFile() throws {
    let damaged = #"{"schema_version": 2, "profiles": [{"id": "pc-3090", "endpoint": "#
    let fileURL = try configurationFile(damaged)
    let store = EvieConfigurationStore(fileURL: fileURL)

    _ = try store.saveActiveProfile(
      reading: EvieConfigurationLoader(fileURL: fileURL),
      environment: [:],
      otherwise: .builtIn
    ) { profile in
      profile.topP = 0.8
    }

    #expect(store.damagedBackupURL.lastPathComponent == "config.json.damaged.bak")
    #expect(try String(contentsOf: store.damagedBackupURL, encoding: .utf8) == damaged)
    #expect(try permissions(of: store.damagedBackupURL) == 0o600)
    #expect(
      try EvieConfigurationLoader(fileURL: fileURL).loadProfiles(environment: [:]).activeProfile
        .topP == 0.8)
  }

  @Test("the settings save refuses to replace a file written by a newer schema")
  func settingsSaveRefusesNewerSchema() throws {
    let newer = #"{"schema_version": 3, "profiles": [], "brains": {"future": true}}"#
    let fileURL = try configurationFile(newer)
    let store = EvieConfigurationStore(fileURL: fileURL)

    #expect(throws: EvieConfigurationStore.SaveError.newerSchema(3)) {
      try store.saveActiveProfile(
        reading: EvieConfigurationLoader(fileURL: fileURL),
        environment: [:],
        otherwise: .builtIn
      ) { profile in
        profile.topP = 0.8
      }
    }
    #expect(try String(contentsOf: fileURL, encoding: .utf8) == newer)
    #expect(!FileManager.default.fileExists(atPath: store.damagedBackupURL.path))
    #expect(
      EvieConfigurationStore.SaveError.newerSchema(3).localizedDescription.contains("mais nova"))
  }

  @Test("the settings save leaves a file it cannot read, and so cannot back up, in place")
  func settingsSaveKeepsUnreadableFile() throws {
    let original = #"{"schema_version": 2, "#
    let fileURL = try configurationFile(original)
    try FileManager.default.setAttributes([.posixPermissions: 0o000], ofItemAtPath: fileURL.path)
    defer {
      try? FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: fileURL.path)
    }
    let store = EvieConfigurationStore(fileURL: fileURL)

    #expect(throws: EvieConfigurationStore.SaveError.self) {
      try store.saveActiveProfile(
        reading: EvieConfigurationLoader(fileURL: fileURL),
        environment: [:],
        otherwise: .builtIn
      ) { profile in
        profile.topP = 0.8
      }
    }
    try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: fileURL.path)
    #expect(try String(contentsOf: fileURL, encoding: .utf8) == original)
    #expect(!FileManager.default.fileExists(atPath: store.damagedBackupURL.path))
  }

  @Test("EVIE_MODEL_PROFILE selects a profile and EVIE_MODEL_* override only that one")
  func environmentSelection() throws {
    let fileURL = missingFileURL()
    try EvieConfigurationStore(fileURL: fileURL).save(.builtIn)
    let loader = EvieConfigurationLoader(fileURL: fileURL)

    let mac = try loader.loadProfiles(
      environment: ["EVIE_MODEL_PROFILE": "mac-local", "EVIE_MODEL_MAX_COMPLETION": "1024"]
    )
    #expect(mac.activeProfile.id == "mac-local")
    #expect(mac.configuration.maxCompletionTokens == 1_024)
    #expect(mac.configuration.thinkingStyle == .topLevel)
    // Overrides are for this run only; what a save writes back is unchanged.
    #expect(mac.profiles == .builtIn)

    let pc = try loader.loadProfiles(environment: ["EVIE_MODEL_NAME": "qwen-uncensored"])
    #expect(pc.activeProfile.id == "pc-3090")
    #expect(pc.configuration.model == "qwen-uncensored")
    #expect(pc.configuration.credential == EvieModelProfileSet.builtIn.preferredProfile.credential)

    #expect(
      throws: EvieConfigurationLoader.LoaderError.invalidEnvironmentVariable("EVIE_MODEL_PROFILE")
    ) {
      try loader.loadProfiles(environment: ["EVIE_MODEL_PROFILE": "nowhere"])
    }
  }

  @Test("EVIE_MODEL_ENDPOINT cannot point the Mac brain anywhere but where Evie starts it")
  func environmentCannotMoveTheMacBrain() throws {
    let fileURL = missingFileURL()
    try EvieConfigurationStore(fileURL: fileURL).save(.builtIn)
    let loader = EvieConfigurationLoader(fileURL: fileURL)

    #expect(
      throws: EvieConfigurationLoader.LoaderError.invalidEnvironmentVariable("EVIE_MODEL_ENDPOINT")
    ) {
      try loader.loadProfiles(
        environment: [
          "EVIE_MODEL_PROFILE": "mac-local",
          "EVIE_MODEL_ENDPOINT": "http://127.0.0.1:9999/v1",
        ]
      )
    }
    let (fallback, failure) = loader.loadWithDiagnostics(
      environment: [
        "EVIE_MODEL_PROFILE": "mac-local",
        "EVIE_MODEL_ENDPOINT": "http://127.0.0.1:9999/v1",
      ]
    )
    #expect(fallback == .builtIn)
    #expect(failure != nil)
  }

  @Test("a v2 file with an invalid profile is refused and the built-ins are used")
  func invalidV2() throws {
    let fileURL = missingFileURL()
    var set = EvieModelProfileSet.builtIn
    set.preferenceOrder = ["pc-3090", "nowhere"]
    let directory = fileURL.deletingLastPathComponent()
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    // Written past the store, which would refuse it.
    try EvieConfigurationStore.encode(set).write(to: fileURL)

    let (loaded, failure) = EvieConfigurationLoader(fileURL: fileURL)
      .loadWithDiagnostics(environment: [:])

    #expect(loaded.profiles == .builtIn)
    guard case .invalidFile = failure as? EvieConfigurationLoader.LoaderError else {
      Issue.record("expected invalidFile, got \(String(describing: failure))")
      return
    }
  }

  @Test("the runtime script seeds a v2 file the loader accepts")
  func runtimeScriptSeedsV2() throws {
    let support = FileManager.default.temporaryDirectory
      .appendingPathComponent(UUID().uuidString, isDirectory: true)
    let logs = support.appendingPathComponent("Logs", isDirectory: true)
    let script = URL(fileURLWithPath: #filePath)
      .deletingLastPathComponent()
      .deletingLastPathComponent()
      .deletingLastPathComponent()
      .appendingPathComponent("Scripts/evie-runtime")

    let process = Process()
    process.executableURL = URL(fileURLWithPath: "/bin/zsh")
    process.arguments = [script.path, "configure"]
    process.environment = [
      "HOME": FileManager.default.homeDirectoryForCurrentUser.path,
      "PATH": "/usr/bin:/bin:/usr/sbin:/sbin",
      "EVIE_SUPPORT_DIR_OVERRIDE": support.path,
      "EVIE_LOG_DIR_OVERRIDE": logs.path,
    ]
    process.standardOutput = FileHandle.nullDevice
    try process.run()
    process.waitUntilExit()
    #expect(process.terminationStatus == 0)

    let fileURL = support.appendingPathComponent("config.json")
    // Read before the loader runs: a v1 seed would pass every check below once
    // migrated, so the header and the absence of a backup are what prove the
    // script writes v2 itself.
    #expect(try schemaVersion(of: fileURL) == 2)
    #expect(try permissions(of: fileURL) == 0o600)
    let loaded = try EvieConfigurationLoader(fileURL: fileURL).loadProfiles(environment: [:])
    #expect(!FileManager.default.fileExists(atPath: fileURL.appendingPathExtension("v1.bak").path))
    #expect(Array(loaded.profiles.profiles.prefix(2)) == EvieModelProfileSet.builtIn.profiles)
    #expect(loaded.profiles.preferenceOrder == EvieModelProfileSet.builtIn.preferenceOrder)
    #expect(loaded.profiles.macFallback == EvieModelProfileSet.builtIn.macFallback)
    let gemma = try #require(loaded.profiles.profile(id: "custom"))
    #expect(gemma.endpoint.absoluteString == "http://127.0.0.1:38433/v1")
    #expect(gemma.model == "gemma-4-26b-a4b-it")
    #expect(loaded.activeProfile.id == "pc-3090")
  }
}

extension EvieConfigurationSchemaV2Tests {
  fileprivate func customProfile() -> EvieModelProfile {
    EvieModelProfile(
      id: "custom",
      displayName: "Personalizado",
      endpoint: URL(string: "http://127.0.0.1:38433/v1")!,
      model: "gemma-4-26b-a4b-it",
      contextTokens: 65_536,
      maxCompletionTokens: 4_096,
      capabilities: .init(vision: false, tools: true),
      thinkingStyle: .none,
      runtime: .remoteGateway,
      location: .thisMac,
      family: .gemma,
      coordinateConvention: .pixels
    )
  }

  fileprivate func missingFileURL() -> URL {
    FileManager.default.temporaryDirectory
      .appendingPathComponent(UUID().uuidString, isDirectory: true)
      .appendingPathComponent("config.json", isDirectory: false)
  }

  fileprivate func configurationFile(_ contents: String) throws -> URL {
    let fileURL = missingFileURL()
    try FileManager.default.createDirectory(
      at: fileURL.deletingLastPathComponent(),
      withIntermediateDirectories: true
    )
    try Data(contents.utf8).write(to: fileURL, options: [.atomic])
    return fileURL
  }

  fileprivate func schemaVersion(of fileURL: URL) throws -> Int? {
    let object = try JSONSerialization.jsonObject(with: Data(contentsOf: fileURL))
    return (object as? [String: Any])?["schema_version"] as? Int
  }

  fileprivate func permissions(of fileURL: URL) throws -> Int? {
    let attributes = try FileManager.default.attributesOfItem(atPath: fileURL.path)
    return (attributes[.posixPermissions] as? NSNumber)?.intValue
  }
}
