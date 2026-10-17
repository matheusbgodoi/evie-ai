import Darwin
import Foundation
import Testing

@testable import EvieCore

/// `Scripts/evie-brain`, run for real against a temporary support directory and
/// a stand-in for `mlx_vlm.server` that records how it was started and exits,
/// so no model loads.
///
/// The script is the manual way to start the same server Evie's launcher
/// starts, so it must launch exactly what `LocalBrainPolicy` builds: the same
/// argv, the same scrubbed, offline environment. The stand-in exits at once,
/// which also exercises the "exited during startup" path; the only connection
/// attempted is the script's `/health` poll to a loopback port nothing listens
/// on, and only while the stand-in is still alive.
@Suite("Evie brain script")
struct EvieBrainScriptTests {
  @Test("bounded script launch preserves the exact Swift bootstrap, argv and scrubbed environment")
  func boundedLaunchMatchesPolicy() throws {
    let sandbox = try BrainSandbox()
    try sandbox.prepareBoundedStandIn()
    let run = try sandbox.run(
      "start",
      inherited: [
        "EVIE_BRAIN_MAX_KV": "65536", "EVIE_BRAIN_KV_BITS": "8",
        "EVIE_BRAIN_PREFILL_STEP_SIZE": "512", "EVIE_BRAIN_CACHE_LIMIT_MB": "256",
        "PYTHONPATH": "/tmp/forbidden-import-path",
      ]
    )
    #expect(run.status != 0)
    #expect(run.standardError.contains("exited during startup"))
    let runtime = LocalRuntime(
      launcher: .mlxVLM, executable: sandbox.standIn.path, port: sandbox.port,
      maxKVSize: 65_536, kvBits: 8, prefillStepSize: 512, metalCacheLimitMB: 256
    )
    #expect(
      try sandbox.recordedArguments()
        == LocalBrainPolicy.makeArguments(runtime, model: "mlx-community/LensVLM-9B-OptiQ-4bit"))
    #expect(try sandbox.recordedEnvironment()["PYTHONPATH"] == nil)
    #expect(try sandbox.recordedEnvironment()["HF_HUB_OFFLINE"] == "1")
  }

  @Test("bounded script refuses env/PATH shebangs and invalid memory controls before starting")
  func boundedLaunchRejectsInvalidConfiguration() throws {
    let sandbox = try BrainSandbox()
    for settings in [
      ["EVIE_BRAIN_CACHE_LIMIT_MB": "256"],
      ["EVIE_BRAIN_CACHE_LIMIT_MB": "0"],
      ["EVIE_BRAIN_CACHE_LIMIT_MB": "9999999999999999999999999"],
      ["EVIE_BRAIN_KV_BITS": "5"],
      ["EVIE_BRAIN_PREFILL_STEP_SIZE": "-1"],
    ] {
      let run = try sandbox.run("start", inherited: settings)
      #expect(run.status != 0)
      #expect(!sandbox.exists("Runtime/brain.pid"))
      #expect(!sandbox.exists("Runtime/brain.key"))
    }
  }

  @Test("stop recognises an exact bounded Python process and leaves modified bootstrap code alone")
  func stopRecognisesOnlyExactBoundedBootstrap() throws {
    let sandbox = try BrainSandbox()
    defer { try? FileManager.default.removeItem(at: sandbox.root) }
    let interpreter = try sandbox.prepareIsolatedPythonStandIn()
    let runtime = LocalRuntime(
      launcher: .mlxVLM, executable: sandbox.standIn.path, port: sandbox.port,
      maxKVSize: 65_536, kvBits: 8, prefillStepSize: 512, metalCacheLimitMB: 256
    )
    for modified in [false, true] {
      let server = Process()
      server.executableURL = interpreter
      var arguments = LocalBrainPolicy.makeArguments(runtime, model: "synthetic-only")
      if modified { arguments[2] += ";pass" }
      server.arguments = arguments
      server.standardOutput = FileHandle.nullDevice
      server.standardError = FileHandle.nullDevice
      try server.run()
      defer { if server.isRunning { server.terminate() } }
      try sandbox.write("\(server.processIdentifier)\n", to: "Runtime/brain.pid")
      let run = try sandbox.run("stop")
      #expect(run.status == 0)
      if !modified {
        server.waitUntilExit()
        #expect(server.terminationReason == .uncaughtSignal)
        #expect(server.terminationStatus == SIGTERM)
      }
      #expect(server.isRunning == modified)
      #expect(!sandbox.exists("Runtime/brain.pid"))
    }
  }

  @Test("start launches the policy's argv with an offline, scrubbed environment and a fresh key")
  func startUsesThePolicyCommand() throws {
    let sandbox = try BrainSandbox()

    let run = try sandbox.run(
      "start",
      inherited: [
        "MLX_VLM_SERVER_API_KEY": "would-lock-evie-out",
        "MAX_KV_SIZE": "262144",
        "PYTHONPATH": "/tmp/planted",
      ]
    )

    #expect(run.status != 0)
    #expect(run.standardError.contains("exited during startup"))
    let runtime = LocalRuntime(
      launcher: .mlxVLM,
      executable: sandbox.standIn.path,
      port: sandbox.port,
      maxKVSize: 32_768
    )
    #expect(
      try sandbox.recordedArguments()
        == LocalBrainPolicy.makeArguments(runtime, model: "mlx-community/LensVLM-9B-OptiQ-4bit")
    )
    let environment = try sandbox.recordedEnvironment()
    #expect(environment["HF_HUB_OFFLINE"] == "1")
    #expect(environment["PATH"] == "/usr/bin:/bin:/usr/sbin:/sbin")
    // The caller's key never reaches the server; the script's own, made for
    // this launch, does — through the environment, not the argv.
    let key = try #require(environment["MLX_VLM_SERVER_API_KEY"])
    #expect(key != "would-lock-evie-out")
    #expect(key.count == 64 && key.allSatisfy { $0.isHexDigit && !$0.isUppercase })
    #expect(try !sandbox.recordedArguments().contains { $0.contains(key) })
    #expect(environment["MAX_KV_SIZE"] == nil)
    #expect(environment["PYTHONPATH"] == nil)
    // The server is gone, so the record of it and its key are too.
    #expect(!sandbox.exists("Runtime/brain.pid"))
    #expect(!sandbox.exists("Runtime/brain.key"))
    #expect(sandbox.exists("Runtime/brain.log"))
  }

  @Test("start refuses an executable that is not an absolute path")
  func startRefusesARelativeExecutable() throws {
    let sandbox = try BrainSandbox()

    let run = try sandbox.run("start", executable: "mlx_vlm.server")

    #expect(run.status != 0)
    #expect(run.standardError.contains("absolute path"))
    #expect(!sandbox.exists("Runtime/brain.pid"))
  }

  @Test("stop leaves a process alone whose pid the stale file names")
  func stopIgnoresAReusedPID() throws {
    let sandbox = try BrainSandbox()
    let bystander = Process()
    bystander.executableURL = URL(fileURLWithPath: "/bin/sleep")
    bystander.arguments = ["30"]
    try bystander.run()
    defer { bystander.terminate() }
    try sandbox.write("\(bystander.processIdentifier)\n", to: "Runtime/brain.pid")

    let run = try sandbox.run("stop")

    #expect(run.status == 0)
    #expect(bystander.isRunning)
    #expect(!sandbox.exists("Runtime/brain.pid"))
  }

  @Test("stop leaves alone a server not bound to loopback by its last --host")
  func stopIgnoresAServerOffLoopback() throws {
    let sandbox = try BrainSandbox()
    let runtime = LocalRuntime(
      launcher: .mlxVLM, executable: sandbox.lingering.path, port: sandbox.port, maxKVSize: 32_768)
    for exposed in [
      ["--model", "m", "--port", String(sandbox.port)],
      LocalBrainPolicy.makeArguments(runtime, model: "m") + ["--host", "0.0.0.0"],
      LocalBrainPolicy.makeArguments(runtime, model: "m") + ["--hos=0.0.0.0"],
    ] {
      let server = try sandbox.startLingering(arguments: exposed)
      defer { server.terminate() }
      try sandbox.write("\(server.processIdentifier)\n", to: "Runtime/brain.pid")

      let run = try sandbox.run("stop", executable: sandbox.lingering.path)

      #expect(run.status == 0, "\(exposed)")
      #expect(server.isRunning, "\(exposed)")
      #expect(!sandbox.exists("Runtime/brain.pid"))
    }
  }

  @Test("stop stops a server it recognises: the executable, its port, loopback last")
  func stopStopsItsServer() throws {
    let sandbox = try BrainSandbox()
    let runtime = LocalRuntime(
      launcher: .mlxVLM, executable: sandbox.lingering.path, port: sandbox.port, maxKVSize: 32_768)
    let server = try sandbox.startLingering(
      arguments: ["--host", "0.0.0.0"] + LocalBrainPolicy.makeArguments(runtime, model: "m"))
    defer { server.terminate() }
    try sandbox.write("\(server.processIdentifier)\n", to: "Runtime/brain.pid")

    try sandbox.write(LocalBrainKeyFile.makeKey() + "\n", to: "Runtime/brain.key")

    let run = try sandbox.run("stop", executable: sandbox.lingering.path)
    server.waitUntilExit()

    #expect(run.status == 0)
    #expect(!server.isRunning)
    #expect(!sandbox.exists("Runtime/brain.pid"))
    #expect(!sandbox.exists("Runtime/brain.key"))
  }
}

/// A support directory, a free loopback port, and a stand-in server that writes
/// its argv and environment, one entry per line, and exits.
private struct BrainSandbox {
  struct Run {
    let status: Int32
    let standardError: String
  }

  let root: URL
  let port: Int
  var support: URL { root.appendingPathComponent("Support", isDirectory: true) }
  var standIn: URL { root.appendingPathComponent("mlx_vlm.server") }
  /// A stand-in that stays up for 30 s without a child of its own and listens
  /// on nothing, so only its argv decides whether it is the server.
  var lingering: URL { root.appendingPathComponent("lingering_mlx_vlm.server") }
  var argumentsRecord: URL { root.appendingPathComponent("argv.txt") }
  var environmentRecord: URL { root.appendingPathComponent("env.txt") }

  init() throws {
    root = FileManager.default.temporaryDirectory
      .appendingPathComponent(UUID().uuidString, isDirectory: true)
    port = try Self.freeLoopbackPort()
    try FileManager.default.createDirectory(
      at: support.appendingPathComponent("Runtime"), withIntermediateDirectories: true)
    let script = """
      #!/bin/zsh
      print -rl -- "$@" > \(argumentsRecord.path)
      /usr/bin/env > \(environmentRecord.path)
      exit 3
      """
    try script.write(to: standIn, atomically: true, encoding: .utf8)
    try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: standIn.path)
    let lingeringScript = """
      #!/bin/zsh
      zmodload zsh/zselect
      zselect -t 3000
      """
    try lingeringScript.write(to: lingering, atomically: true, encoding: .utf8)
    try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: lingering.path)
  }

  /// Runs the lingering stand-in with `arguments`, as the kernel runs a `#!`
  /// script: `/bin/zsh <path> <arguments…>`.
  func startLingering(arguments: [String]) throws -> Process {
    let process = Process()
    process.executableURL = lingering
    process.arguments = arguments
    process.standardOutput = FileHandle.nullDevice
    process.standardError = FileHandle.nullDevice
    try process.run()
    return process
  }

  func run(
    _ command: String,
    executable: String? = nil,
    inherited: [String: String] = [:]
  ) throws -> Run {
    let script = URL(fileURLWithPath: #filePath)
      .deletingLastPathComponent()
      .deletingLastPathComponent()
      .deletingLastPathComponent()
      .appendingPathComponent("Scripts/evie-brain")
    let process = Process()
    process.executableURL = URL(fileURLWithPath: "/bin/zsh")
    process.arguments = [script.path, command]
    var environment = inherited
    environment["HOME"] = FileManager.default.homeDirectoryForCurrentUser.path
    environment["PATH"] = "/usr/bin:/bin:/usr/sbin:/sbin"
    environment["EVIE_SUPPORT_DIR_OVERRIDE"] = support.path
    environment["EVIE_BRAIN_EXECUTABLE"] = executable ?? standIn.path
    environment["EVIE_BRAIN_PORT"] = String(port)
    environment["EVIE_BRAIN_READY_SECONDS"] = "5"
    process.environment = environment
    let errors = Pipe()
    process.standardOutput = FileHandle.nullDevice
    process.standardError = errors
    try process.run()
    let errorData = errors.fileHandleForReading.readDataToEndOfFile()
    process.waitUntilExit()
    return Run(
      status: process.terminationStatus,
      standardError: String(decoding: errorData, as: UTF8.self)
    )
  }

  func recordedArguments() throws -> [String] {
    try String(contentsOf: argumentsRecord, encoding: .utf8)
      .split(separator: "\n", omittingEmptySubsequences: false)
      .map(String.init)
      .dropLast()
  }

  /// Records the Python invocation without importing MLX or starting a model.
  /// A separate real-MLX probe verifies the bootstrap's allocator side effect.
  func prepareBoundedStandIn() throws {
    let interpreter = root.appendingPathComponent("python3")
    let record = """
      #!/bin/zsh
      print -rl -- "$@" > \(argumentsRecord.path)
      /usr/bin/env > \(environmentRecord.path)
      exit 3
      """
    try record.write(to: interpreter, atomically: true, encoding: .utf8)
    try FileManager.default.setAttributes(
      [.posixPermissions: 0o700], ofItemAtPath: interpreter.path)
    try "#!\(interpreter.path)\n".write(to: standIn, atomically: true, encoding: .utf8)
  }

  /// Real isolated Python and a tiny fixture module exercise ps/argv parsing.
  /// No installed MLX package, network, model, or production runtime is touched.
  func prepareIsolatedPythonStandIn() throws -> URL {
    let virtualEnvironment = root.appendingPathComponent("python-env", isDirectory: true)
    let setup = Process()
    setup.executableURL = URL(fileURLWithPath: "/usr/bin/python3")
    setup.arguments = ["-m", "venv", "--without-pip", virtualEnvironment.path]
    setup.standardOutput = FileHandle.nullDevice
    setup.standardError = FileHandle.nullDevice
    try setup.run()
    setup.waitUntilExit()
    guard setup.terminationStatus == 0 else { throw CocoaError(.executableRuntimeMismatch) }
    let library = virtualEnvironment.appendingPathComponent("lib", isDirectory: true)
    let version = try #require(
      FileManager.default.contentsOfDirectory(at: library, includingPropertiesForKeys: nil)
        .first(where: { $0.lastPathComponent.hasPrefix("python") }))
    let module = version.appendingPathComponent("site-packages/mlx", isDirectory: true)
    try FileManager.default.createDirectory(at: module, withIntermediateDirectories: true)
    try "".write(
      to: module.appendingPathComponent("__init__.py"), atomically: true, encoding: .utf8)
    try "def set_cache_limit(limit): return 0\n".write(
      to: module.appendingPathComponent("core.py"), atomically: true, encoding: .utf8)
    let interpreter = virtualEnvironment.appendingPathComponent("bin/python3")
    try "#!\(interpreter.path)\nimport time\ntime.sleep(30)\n".write(
      to: standIn, atomically: true, encoding: .utf8)
    return interpreter
  }

  func recordedEnvironment() throws -> [String: String] {
    let lines = try String(contentsOf: environmentRecord, encoding: .utf8)
      .split(separator: "\n")
    return Dictionary(
      lines.compactMap { line -> (String, String)? in
        guard let equals = line.firstIndex(of: "=") else { return nil }
        return (String(line[..<equals]), String(line[line.index(after: equals)...]))
      },
      uniquingKeysWith: { _, last in last }
    )
  }

  func write(_ text: String, to relativePath: String) throws {
    try text.write(
      to: support.appendingPathComponent(relativePath), atomically: true, encoding: .utf8)
  }

  func exists(_ relativePath: String) -> Bool {
    FileManager.default.fileExists(atPath: support.appendingPathComponent(relativePath).path)
  }

  /// A port the kernel just handed out and nothing listens on, so the stand-in
  /// never shares one with a real brain on 38480.
  private static func freeLoopbackPort() throws -> Int {
    let descriptor = socket(AF_INET, SOCK_STREAM, 0)
    guard descriptor >= 0 else { throw POSIXError(.EMFILE) }
    defer { close(descriptor) }
    var address = sockaddr_in()
    address.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
    address.sin_family = sa_family_t(AF_INET)
    address.sin_port = 0
    address.sin_addr.s_addr = inet_addr("127.0.0.1")
    let bound = withUnsafePointer(to: &address) {
      $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
        bind(descriptor, $0, socklen_t(MemoryLayout<sockaddr_in>.size))
      }
    }
    guard bound == 0 else { throw POSIXError(.EADDRINUSE) }
    var length = socklen_t(MemoryLayout<sockaddr_in>.size)
    let named = withUnsafeMutablePointer(to: &address) {
      $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
        getsockname(descriptor, $0, &length)
      }
    }
    guard named == 0 else { throw POSIXError(.EINVAL) }
    return Int(UInt16(bigEndian: address.sin_port))
  }
}
