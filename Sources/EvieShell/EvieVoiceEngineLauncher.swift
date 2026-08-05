import Foundation

/// Starts the local voice engine when Evie is actually asked to speak with it.
///
/// The engine holds a 2.4 GB model resident, and the original decision was that
/// nothing that heavy should start itself — the person whose machine it is should
/// say when. That principle is right and is kept: this never runs at login, never
/// runs because Evie launched, and never runs for a system voice.
///
/// What changed is where the decision is read from. Choosing a trained voice in
/// settings *is* the person saying when; requiring them to also know about a
/// shell script meant the honest failure — falling back to a system voice and
/// saying so — fired for someone who had already asked for the cloned one and
/// had no idea why it never happened. Measured on this Mac: the engine had never
/// been started at all, and the log file did not exist, so there was nothing to
/// diagnose from.
///
/// So the trigger is the request to speak, and only that. It stays a separate
/// process, writes the same log and pid file `Scripts/evie-voice` uses, and
/// `Scripts/evie-voice stop` still releases the memory.
@MainActor
final class EvieVoiceEngineLauncher {
  /// Where OmniVoice Studio installs itself. Overridable by the same variable
  /// the script honours, so a non-standard install works in both.
  static var projectURL: URL {
    if let override = ProcessInfo.processInfo.environment["EVIE_VOICE_PROJECT_OVERRIDE"] {
      return URL(fileURLWithPath: override, isDirectory: true)
    }
    return URL(fileURLWithPath: NSHomeDirectory(), isDirectory: true)
      .appendingPathComponent("Library/Application Support")
      .appendingPathComponent("com.debpalash.omnivoice-studio/project", isDirectory: true)
  }

  static var logURL: URL {
    URL(fileURLWithPath: NSHomeDirectory(), isDirectory: true)
      .appendingPathComponent("Library/Logs/Evie/voice-engine.log", isDirectory: false)
  }

  static var pidURL: URL {
    URL(fileURLWithPath: NSHomeDirectory(), isDirectory: true)
      .appendingPathComponent("Library/Application Support/Evie/State", isDirectory: true)
      .appendingPathComponent("voice-engine.pid", isDirectory: false)
  }

  private static var executableURL: URL {
    projectURL.appendingPathComponent(".venv/bin/uvicorn", isDirectory: false)
  }

  /// How long the model may take to load before this gives up. Measured warm at
  /// about eight seconds; sixty leaves room for a cold page-in without leaving
  /// somebody waiting on something that is never coming.
  static let readyTimeout: TimeInterval = 60

  enum LaunchError: LocalizedError, Equatable {
    case notInstalled
    case incompleteEnvironment
    case portHeldByAnother
    case neverBecameReady
    case couldNotLaunch(String)

    var errorDescription: String? {
      switch self {
      case .notInstalled:
        "O motor de voz não está instalado neste Mac."
      case .incompleteEnvironment:
        "O ambiente do motor de voz está incompleto — falta o .venv."
      case .portHeldByAnother:
        "A porta 3900 está ocupada por outro processo."
      case .neverBecameReady:
        "O motor de voz subiu mas não ficou pronto a tempo."
      case .couldNotLaunch(let reason):
        "Não consegui iniciar o motor de voz: \(reason)"
      }
    }
  }

  /// True when the engine can be started at all, so the interface can say
  /// "not installed" rather than offering a button that cannot work.
  static var isInstalled: Bool {
    FileManager.default.isExecutableFile(atPath: executableURL.path)
  }

  private var launch: Task<Void, any Error>?

  /// Brings the engine up and returns once it answers.
  ///
  /// Idempotent and safe to call on every phrase: an engine already answering
  /// returns immediately, and two calls that race share one launch rather than
  /// starting two models.
  func ensureRunning(client: EvieOmniVoiceClient = EvieOmniVoiceClient()) async throws {
    if await client.isHealthy() {
      return
    }
    if let launch {
      return try await launch.value
    }
    let task = Task<Void, any Error> { [client] in
      try Self.spawn()
      try await Self.waitUntilHealthy(client: client)
    }
    launch = task
    defer { launch = nil }
    return try await task.value
  }

  /// Starts the process, or reports precisely why it could not.
  private static func spawn() throws {
    guard FileManager.default.fileExists(atPath: projectURL.path) else {
      throw LaunchError.notInstalled
    }
    guard FileManager.default.isExecutableFile(atPath: executableURL.path) else {
      throw LaunchError.incompleteEnvironment
    }
    // Refused rather than fought over. Something else answering on this port
    // would be handed Evie's text, and guessing what it is would be worse than
    // saying so.
    guard !isPortBound() else {
      throw LaunchError.portHeldByAnother
    }

    let manager = FileManager.default
    try? manager.createDirectory(
      at: logURL.deletingLastPathComponent(),
      withIntermediateDirectories: true
    )
    try? manager.createDirectory(
      at: pidURL.deletingLastPathComponent(),
      withIntermediateDirectories: true,
      attributes: [.posixPermissions: 0o700]
    )
    if !manager.fileExists(atPath: logURL.path) {
      manager.createFile(atPath: logURL.path, contents: nil)
    }
    guard let log = try? FileHandle(forWritingTo: logURL) else {
      throw LaunchError.couldNotLaunch("não consegui abrir o log")
    }
    // Appended to rather than truncated: the previous run's failure is often the
    // only record of why this one is happening.
    _ = try? log.seekToEnd()

    let process = Process()
    process.executableURL = executableURL
    process.arguments = [
      "main:app", "--app-dir", "backend",
      "--host", "127.0.0.1", "--port", String(EvieOmniVoiceClient.defaultPort),
    ]
    process.currentDirectoryURL = projectURL
    process.standardOutput = log
    process.standardError = log
    // No stdin: the engine reads none, and leaving it inherited would tie a
    // background model to Evie's terminal when she is run from one.
    process.standardInput = FileHandle.nullDevice

    do {
      try process.run()
    } catch {
      throw LaunchError.couldNotLaunch(error.localizedDescription)
    }
    // The same file `Scripts/evie-voice` writes, so `stop` still finds it and
    // the two ways of starting the engine do not disagree about what is running.
    try? String(process.processIdentifier).write(to: pidURL, atomically: true, encoding: .utf8)
    try? manager.setAttributes([.posixPermissions: 0o600], ofItemAtPath: pidURL.path)
  }

  /// Polls until the model is loaded, or gives up.
  private static func waitUntilHealthy(client: EvieOmniVoiceClient) async throws {
    let deadline = Date().addingTimeInterval(readyTimeout)
    while Date() < deadline {
      if await client.isHealthy() {
        return
      }
      try? await Task.sleep(for: .milliseconds(400))
      try Task.checkCancellation()
    }
    throw LaunchError.neverBecameReady
  }

  /// Whether anything is listening on the engine's port.
  ///
  /// Asked by trying to bind it, which is the only answer that is not a guess:
  /// a health check that fails cannot tell "nothing is there" from "something is
  /// there and is not the engine".
  static func isPortBound() -> Bool {
    let descriptor = socket(AF_INET, SOCK_STREAM, 0)
    guard descriptor >= 0 else {
      return false
    }
    defer { close(descriptor) }

    var address = sockaddr_in()
    address.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
    address.sin_family = sa_family_t(AF_INET)
    address.sin_port = UInt16(EvieOmniVoiceClient.defaultPort).bigEndian
    address.sin_addr.s_addr = inet_addr("127.0.0.1")

    let bound = withUnsafePointer(to: &address) { pointer in
      pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) {
        bind(descriptor, $0, socklen_t(MemoryLayout<sockaddr_in>.size))
      }
    }
    return bound != 0
  }
}
