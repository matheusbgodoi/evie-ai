import AppKit
import Darwin
import EvieCore
import Foundation

private struct BoundaryFailure: Error { let message: String }
private struct Snapshot: Decodable {
  let pid: Int32
  let model: String
  let host: String
  let port: Int
  let maxKVSize: Int
  let maxNumSeqs: Int
  let kvBits: Int?
  let prefillStepSize: Int?
  let cacheLimitBytes: Int
  enum CodingKeys: String, CodingKey {
    case pid, model, host, port
    case maxKVSize = "max_kv_size"
    case maxNumSeqs = "max_num_seqs"
    case kvBits = "kv_bits"
    case prefillStepSize = "prefill_step_size"
    case cacheLimitBytes = "cache_limit_bytes"
  }
}

@main
struct LocalBrainValidation {
  @MainActor
  static func main() {
    let application = NSApplication.shared
    application.setActivationPolicy(.prohibited)
    Task { @MainActor in
      do {
        try await validateOnce()
        print("PASS: strict ESRCH after stop while AppKit host remains alive")
        application.terminate(nil)
      } catch {
        print("FAIL: \(error)")
        exit(1)
      }
    }
    application.run()
  }

  @MainActor
  private static func validateOnce() async throws {
    guard CommandLine.arguments.count == 3 else {
      throw BoundaryFailure(message: "Expected fixture CLI and temporary state directory")
    }
    let executable = CommandLine.arguments[1]
    let directory = URL(fileURLWithPath: CommandLine.arguments[2], isDirectory: true)
      .appendingPathComponent(UUID().uuidString, isDirectory: true)
    let port = try availablePort()
    let keyFile = LocalBrainKeyFile(url: directory.appendingPathComponent("brain.key"))
    let launcher = EvieLocalBrainLauncher(
      policy: LocalBrainPolicy(
        idleUnloadAfter: .seconds(600), minimumAvailableBytes: 0, voiceEngineBytes: 0),
      keyFile: keyFile, storageDirectory: directory)
    let sessionConfiguration = URLSessionConfiguration.ephemeral
    sessionConfiguration.timeoutIntervalForRequest = 5
    sessionConfiguration.timeoutIntervalForResource = 5
    let session = URLSession(configuration: sessionConfiguration)
    defer { session.invalidateAndCancel() }
    do {
      var runtime = LocalRuntime(
        launcher: .mlxVLM, executable: executable, port: port, maxKVSize: 32_768,
        kvBits: 8, prefillStepSize: 256, metalCacheLimitMB: 256)
      var profile = EvieModelProfileSet.builtIn.profile(id: EvieModelProfile.macProfileID)!
      profile.runtime = .localOnDemand(runtime)
      profile.endpoint = runtime.endpoint
      profile.model = "fixture-model-A"
      profile.contextTokens = runtime.maxKVSize
      _ = try await launcher.ensureRunning(profile)
      guard let key = keyFile.read() else {
        throw BoundaryFailure(message: "Temporary key missing")
      }
      let old = try await snapshot(on: port, key: key, session: session)
      try check(
        old.model == profile.model && old.maxKVSize == 32_768, "initial CLI options differ")
      try check(
        old.maxNumSeqs == 1 && old.kvBits == 8 && old.prefillStepSize == 256,
        "bounded runtime CLI controls differ")
      try check(old.cacheLimitBytes == 268_435_456, "real MLX allocator limit not applied")
      let unauthorized = try await status(on: port, key: nil, session: session)
      let wrongKey = try await status(on: port, key: "synthetic-wrong-token", session: session)
      try check(unauthorized == 401 && wrongKey == 401, "server did not enforce actual HTTP key")

      runtime.maxKVSize = 65_536
      profile.runtime = .localOnDemand(runtime)
      profile.model = "fixture-model-B"
      profile.contextTokens = runtime.maxKVSize
      let serving = try await launcher.isServing(profile)
      try check(serving == nil, "new profile accepted stale KV/model server")
      try check(EvieProcessInspector.isAlive(old.pid), "readiness probe interrupted running server")
      _ = try await launcher.ensureRunning(profile)
      guard let newKey = keyFile.read() else {
        throw BoundaryFailure(message: "Restart key missing")
      }
      let changed = try await snapshot(on: port, key: newKey, session: session)
      try check(
        changed.pid != old.pid && !EvieProcessInspector.isAlive(old.pid), "old server not replaced")
      try check(
        changed.model == "fixture-model-B" && changed.maxKVSize == 65_536,
        "restart did not apply new model/KV controls")
      try check(newKey != key, "restart reused old bearer key")
      try check(
        try await status(on: port, key: key, session: session) == 401,
        "restarted server still accepted prior key")
      try check(changed.cacheLimitBytes == 268_435_456, "restart lost real MLX cache bound")
      _ = try await launcher.ensureRunning(profile)
      let reused = try await snapshot(on: port, key: newKey, session: session)
      try check(reused.pid == changed.pid, "matching profile restarted unnecessarily")
      let ready = try await launcher.isServing(profile)
      try check(ready == profile.endpoint, "matching profile not ready")
      // Model-only edits must also be reconciled even when runtime controls match.
      profile.model = "fixture-model-C"
      let staleModel = try await launcher.isServing(profile)
      try check(staleModel == nil, "model-only edit reused the old model")
      _ = try await launcher.ensureRunning(profile)
      guard let finalKey = keyFile.read() else {
        throw BoundaryFailure(message: "Model-change key missing")
      }
      let final = try await snapshot(on: port, key: finalKey, session: session)
      try check(
        final.pid != changed.pid && final.model == "fixture-model-C"
          && final.maxKVSize == 65_536, "model-only change did not restart correctly")
      _ = try await launcher.ensureRunning(profile)
      let finalReuse = try await snapshot(on: port, key: finalKey, session: session)
      try check(finalReuse.pid == final.pid, "final matching profile did not reuse the server")
      await launcher.stop()
      try check(!EvieProcessInspector.isAlive(final.pid), "managed fixture survived stop")
      try check(
        processIsGone(final.pid), "stopped child PID remains unreaped while harness is alive")
      try check(
        EvieProcessInspector.listeningPID(onPort: port) == nil, "fixture port still occupied")
      try check(
        !FileManager.default.fileExists(atPath: directory.appendingPathComponent("brain.pid").path),
        "temporary PID file survived stop")
      try check(keyFile.read() == nil, "temporary key survived stop")
      print(
        "PASS: real Process + authenticated HTTP + MLX 256 MiB bootstrap; 32K/A → 64K/B and model-only C restart, matching profiles reuse, temporary state removed"
      )
      try await foreignListenerIsPreserved(
        executable: executable, directory: directory, session: session)
    } catch {
      await launcher.stop()
      throw error
    }
  }

  @MainActor
  private static func foreignListenerIsPreserved(
    executable: String, directory: URL, session: URLSession
  ) async throws {
    let foreign = directory.appendingPathComponent("foreign-cli")
    try FileManager.default.copyItem(at: URL(fileURLWithPath: executable), to: foreign)
    let port = try availablePort()
    let runtime = LocalRuntime(
      launcher: .mlxVLM, executable: executable, port: port, maxKVSize: 32_768)
    let process = Process()
    process.executableURL = foreign
    process.arguments = LocalBrainPolicy.makeArguments(runtime, model: "fixture-foreign")
    process.environment = LocalBrainPolicy.makeEnvironment(
      inheriting: ProcessInfo.processInfo.environment, apiKey: LocalBrainKeyFile.makeKey())
    process.standardInput = FileHandle.nullDevice
    process.standardOutput = FileHandle.nullDevice
    process.standardError = FileHandle.nullDevice
    try process.run()
    defer {
      kill(process.processIdentifier, SIGTERM)
      var code: Int32 = 0
      _ = waitpid(process.processIdentifier, &code, 0)
    }
    let deadline = ContinuousClock.now + .seconds(5)
    while EvieProcessInspector.listeningPID(onPort: port) == nil, ContinuousClock.now < deadline {
      try await Task.sleep(for: .milliseconds(20))
    }
    try check(
      EvieProcessInspector.listeningPID(onPort: port) == process.processIdentifier,
      "foreign fixture did not listen")
    var profile = EvieModelProfileSet.builtIn.profile(id: EvieModelProfile.macProfileID)!
    profile.runtime = .localOnDemand(runtime)
    profile.endpoint = runtime.endpoint
    profile.model = "fixture-foreign"
    let isolated = directory.appendingPathComponent("foreign-state", isDirectory: true)
    let launcher = EvieLocalBrainLauncher(
      policy: LocalBrainPolicy(
        idleUnloadAfter: .seconds(600), minimumAvailableBytes: 0, voiceEngineBytes: 0),
      keyFile: LocalBrainKeyFile(url: isolated.appendingPathComponent("brain.key")),
      storageDirectory: isolated)
    var refused = false
    do { _ = try await launcher.ensureRunning(profile) } catch LocalBrainLaunchError.portHeld {
      refused = true
    }
    await launcher.stop()
    try check(refused, "foreign process not refused")
    try check(
      EvieProcessInspector.isAlive(process.processIdentifier), "foreign process was signalled")
    try check(
      try await status(on: port, key: nil, session: session) == 401,
      "foreign process stopped responding after refused launch")
    try check(
      !FileManager.default.fileExists(atPath: isolated.path), "foreign refusal created state")
    print(
      "PASS: foreign loopback listener refused and left alive; cleanup only terminates explicitly owned fixture"
    )
  }

  private static func status(on port: Int, key: String?, session: URLSession) async throws -> Int {
    var request = URLRequest(url: URL(string: "http://127.0.0.1:\(port)/health")!)
    if let key { request.setValue("Bearer \(key)", forHTTPHeaderField: "Authorization") }
    let (_, response) = try await session.data(for: request)
    guard let http = response as? HTTPURLResponse else {
      throw BoundaryFailure(message: "non-HTTP fixture")
    }
    return http.statusCode
  }

  private static func snapshot(on port: Int, key: String, session: URLSession) async throws
    -> Snapshot
  {
    var request = URLRequest(url: URL(string: "http://127.0.0.1:\(port)/snapshot")!)
    request.setValue("Bearer \(key)", forHTTPHeaderField: "Authorization")
    let (data, response) = try await session.data(for: request)
    try check((response as? HTTPURLResponse)?.statusCode == 200, "authorized HTTP snapshot failed")
    return try JSONDecoder().decode(Snapshot.self, from: data)
  }

  private static func processIsGone(_ pid: pid_t) -> Bool {
    kill(pid, 0) == -1 && errno == ESRCH
  }

  private static func availablePort() throws -> Int {
    let descriptor = socket(AF_INET, SOCK_STREAM, 0)
    guard descriptor >= 0 else { throw POSIXError(.EIO) }
    defer { close(descriptor) }
    var address = sockaddr_in()
    address.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
    address.sin_family = sa_family_t(AF_INET)
    address.sin_addr.s_addr = inet_addr("127.0.0.1")
    let bound = withUnsafePointer(to: &address) {
      $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
        bind(descriptor, $0, socklen_t(MemoryLayout<sockaddr_in>.size))
      }
    }
    guard bound == 0 else { throw POSIXError(.EADDRINUSE) }
    var length = socklen_t(MemoryLayout<sockaddr_in>.size)
    let result = withUnsafeMutablePointer(to: &address) {
      $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { getsockname(descriptor, $0, &length) }
    }
    guard result == 0 else { throw POSIXError(.EIO) }
    return Int(UInt16(bigEndian: address.sin_port))
  }

  private static func check(_ condition: Bool, _ message: String) throws {
    guard condition else { throw BoundaryFailure(message: message) }
  }
}
