import Foundation
import Testing

@testable import EvieCore

/// `Scripts/evie-runtime launch` and `launch-custom`, run for real against a
/// temporary support directory and a stand-in for `Scripts/evie-app`, so no
/// app opens and no model starts.
///
/// Since the PC is the default brain (v2 S2a), `launch` must not start the
/// loopback Gemma, which only the `custom` profile uses and which holds about
/// 15 GB. The temporary directory has no server binary, so a `launch` that
/// still started Gemma fails before Evie is opened, and the stand-in records
/// nothing. Neither test reaches the network: `launch` makes no request, and
/// `launch-custom` refuses on the configuration before it would probe the port.
@Suite("Evie runtime launch")
struct EvieRuntimeLaunchTests {
  @Test("launch opens Evie without starting the local Gemma")
  func launchLeavesGemmaAlone() throws {
    let sandbox = try LaunchSandbox()

    let run = try sandbox.run("launch")

    #expect(run.status == 0)
    #expect(try sandbox.recordedOpen() == "args=run profile=unset")
    #expect(!sandbox.exists("State/turbo-fieldfare-server.pid"))
    #expect(!sandbox.exists("config.json"))
  }

  @Test("launch-custom refuses a configuration without the Gemma it serves")
  func launchCustomNeedsTheCustomProfile() throws {
    let sandbox = try LaunchSandbox()
    try sandbox.write(EvieConfigurationStore.encode(.builtIn), to: "config.json")

    let run = try sandbox.run("launch-custom")

    #expect(run.status != 0)
    #expect(run.standardError.contains("custom"))
    #expect(try sandbox.recordedOpen() == nil)
    #expect(!sandbox.exists("State/turbo-fieldfare-server.pid"))
  }

  @Test("launch-custom refuses a custom profile that points elsewhere")
  func launchCustomNeedsTheServedEndpoint() throws {
    let sandbox = try LaunchSandbox()
    var set = EvieModelProfileSet.builtIn
    set.profiles.append(
      EvieModelProfile(
        id: "custom",
        displayName: "Personalizado",
        endpoint: URL(string: "http://127.0.0.1:9999/v1")!,
        model: "another-model",
        contextTokens: 8_192,
        maxCompletionTokens: 1_024,
        capabilities: .init(vision: false, tools: false),
        thinkingStyle: .none,
        runtime: .remoteGateway,
        location: .thisMac,
        family: .unknown,
        coordinateConvention: .pixels
      )
    )
    try sandbox.write(EvieConfigurationStore.encode(set), to: "config.json")

    let run = try sandbox.run("launch-custom")

    #expect(run.status != 0)
    #expect(run.standardError.contains("http://127.0.0.1:38433/v1"))
    #expect(try sandbox.recordedOpen() == nil)
  }
}

/// A support directory, a log directory and an `evie-app` stand-in that writes
/// what it was asked to do instead of opening anything.
private struct LaunchSandbox {
  struct Run {
    let status: Int32
    let standardError: String
  }

  let root: URL
  var support: URL { root.appendingPathComponent("Support", isDirectory: true) }
  var logs: URL { root.appendingPathComponent("Logs", isDirectory: true) }
  var openRecord: URL { root.appendingPathComponent("opened.txt") }
  var appStandIn: URL { root.appendingPathComponent("evie-app") }

  init() throws {
    root = FileManager.default.temporaryDirectory
      .appendingPathComponent(UUID().uuidString, isDirectory: true)
    try FileManager.default.createDirectory(at: support, withIntermediateDirectories: true)
    let standIn = """
      #!/bin/zsh
      print -r -- "args=$* profile=${EVIE_MODEL_PROFILE:-unset}" > \(openRecord.path)
      """
    try standIn.write(to: appStandIn, atomically: true, encoding: .utf8)
    try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: appStandIn.path)
  }

  func run(_ command: String) throws -> Run {
    let script = URL(fileURLWithPath: #filePath)
      .deletingLastPathComponent()
      .deletingLastPathComponent()
      .deletingLastPathComponent()
      .appendingPathComponent("Scripts/evie-runtime")
    let process = Process()
    process.executableURL = URL(fileURLWithPath: "/bin/zsh")
    process.arguments = [script.path, command]
    process.environment = [
      "HOME": FileManager.default.homeDirectoryForCurrentUser.path,
      "PATH": "/usr/bin:/bin:/usr/sbin:/sbin",
      "EVIE_SUPPORT_DIR_OVERRIDE": support.path,
      "EVIE_LOG_DIR_OVERRIDE": logs.path,
      "EVIE_APP_SCRIPT_OVERRIDE": appStandIn.path,
    ]
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

  func write(_ data: Data, to relativePath: String) throws {
    try data.write(to: support.appendingPathComponent(relativePath))
  }

  func exists(_ relativePath: String) -> Bool {
    FileManager.default.fileExists(atPath: support.appendingPathComponent(relativePath).path)
  }

  /// The stand-in's record, or nil when Evie was never opened.
  func recordedOpen() throws -> String? {
    guard FileManager.default.fileExists(atPath: openRecord.path) else { return nil }
    return try String(contentsOf: openRecord, encoding: .utf8)
      .trimmingCharacters(in: .whitespacesAndNewlines)
  }
}
