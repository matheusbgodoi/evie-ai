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
  @Test("start launches the policy's argv with an offline, scrubbed environment")
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
    #expect(environment["MLX_VLM_SERVER_API_KEY"] == nil)
    #expect(environment["MAX_KV_SIZE"] == nil)
    #expect(environment["PYTHONPATH"] == nil)
    // The server is gone, so the record of it is too.
    #expect(!sandbox.exists("Runtime/brain.pid"))
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
