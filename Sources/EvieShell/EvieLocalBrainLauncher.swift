import Darwin
import EvieCore
import Foundation

/// Starts the brain that runs on this Mac — LensVLM under `mlx_vlm.server` —
/// when a turn needs it, and stops it when nothing has used it for ten minutes
/// or when Evie quits (ADR 0015).
///
/// It follows `EvieVoiceEngineLauncher`: a separate process, never started at
/// login or at launch, only when asked for; the same pid file and log the
/// script uses (`Scripts/evie-brain`, `Application Support/Evie/Runtime`); and a
/// port held by something else is refused rather than fought over. What it adds
/// is that it never takes "something answered on the port" for "the brain
/// answered": the conversation and the screen go there, so before a turn uses
/// the server, the process listening on the port must be the configured
/// executable serving that port, and after a start it must be the process this
/// launcher spawned. A pid from the pid file is never signalled before its
/// image and argv are checked, because pids get reused.
///
/// Every rule is `LocalBrainPolicy`'s (EvieCore, tested); this type carries them
/// out against the real process table.
@MainActor
final class EvieLocalBrainLauncher: LocalBrainStarting {
  static var runtimeDirectory: URL {
    URL(fileURLWithPath: NSHomeDirectory(), isDirectory: true)
      .appendingPathComponent("Library/Application Support/Evie/Runtime", isDirectory: true)
  }

  static var pidURL: URL {
    runtimeDirectory.appendingPathComponent("brain.pid", isDirectory: false)
  }

  static var logURL: URL {
    runtimeDirectory.appendingPathComponent("brain.log", isDirectory: false)
  }

  /// Measured 2026-10-16 on this Mac: `/health` answered 5.4 s after launch
  /// with the weights in the page cache. Ninety seconds leaves room for a read
  /// from disk after a reboot without leaving a turn waiting on a server that
  /// is never coming.
  static let readyTimeout: Duration = .seconds(90)
  /// The grace between SIGTERM and SIGKILL. Measured: uvicorn exits within
  /// 0.35 s of SIGTERM.
  static let stopGrace: Duration = .seconds(5)
  /// How often the idle clock is read. A minute either way on a ten-minute
  /// timeout does not matter; waking up more often would.
  static let idleCheckInterval: Duration = .seconds(30)
  /// Past this the log is moved aside at the next start. At INFO each
  /// request writes about ten lines.
  static let logRotationBytes = 10 << 20

  private let policy: LocalBrainPolicy
  private let healthSession: URLSession
  /// The server this launcher spawned. Keeping the `Process` keeps its exit
  /// observable and its pid ours until it is reaped.
  private var child: Process?
  /// The server Evie manages: her child, or one `Scripts/evie-brain` started
  /// that she has since used. It is the one the idle timer and quit stop.
  private var managed: (pid: pid_t, runtime: LocalRuntime)?
  private var lastUse: ContinuousClock.Instant?
  private var launch: Task<URL, any Error>?
  private var idleWatch: Task<Void, Never>?

  init(policy: LocalBrainPolicy = .standard) {
    self.policy = policy
    let configuration = URLSessionConfiguration.ephemeral
    configuration.timeoutIntervalForRequest = 3
    configuration.urlCache = nil
    healthSession = URLSession(configuration: configuration)
  }

  // MARK: - LocalBrainStarting

  func ensureRunning(_ profile: EvieModelProfile) async throws -> URL {
    if let launch {
      return try await launch.value
    }
    let runtime = try Self.runtime(of: profile)
    let task = Task<URL, any Error> { @MainActor [weak self] in
      guard let self else { throw CancellationError() }
      return try await bringUp(profile, runtime: runtime)
    }
    launch = task
    defer { launch = nil }
    return try await task.value
  }

  func isServing(_ profile: EvieModelProfile) throws -> URL? {
    let runtime = try Self.runtime(of: profile)
    guard let listener = EvieProcessInspector.listeningPID(onPort: runtime.port) else {
      return nil
    }
    guard Self.isServer(listener, runtime: runtime) else {
      throw LocalBrainLaunchError.portHeld(port: runtime.port)
    }
    adopt(listener, runtime: runtime)
    return runtime.endpoint
  }

  func noteUse() {
    lastUse = .now
  }

  // MARK: - Stopping

  /// Stops the managed server: SIGTERM, then SIGKILL after five seconds. A
  /// pid that is no longer this server is left alone and only forgotten.
  func stop() {
    idleWatch?.cancel()
    idleWatch = nil
    guard let (pid, runtime) = managed.map({ ($0.pid, $0.runtime) }) else {
      return
    }
    managed = nil
    child = nil
    lastUse = nil
    defer { Self.removePIDFile(ifItNames: pid) }
    guard Self.isServer(pid, runtime: runtime) else {
      return
    }
    kill(pid, SIGTERM)
    if !Self.waitForExit(of: pid, within: Self.stopGrace) {
      kill(pid, SIGKILL)
      _ = Self.waitForExit(of: pid, within: .seconds(2))
    }
  }

  /// At Evie's launch: a pid file that names no live server is removed; one
  /// that names a live server — left by a crash, or started by the script — is
  /// taken over, so the idle timer stops it if nothing uses it.
  func reconcilePIDFile(for profiles: EvieModelProfileSet) {
    guard let pid = Self.recordedPID() else {
      return
    }
    let runtimes = profiles.profiles.compactMap { profile -> LocalRuntime? in
      if case .localOnDemand(let runtime) = profile.runtime { runtime } else { nil }
    }
    guard let runtime = runtimes.first(where: { Self.isServer(pid, runtime: $0) }),
      EvieProcessInspector.listens(pid, onPort: runtime.port)
    else {
      try? FileManager.default.removeItem(at: Self.pidURL)
      return
    }
    adopt(pid, runtime: runtime)
  }

  // MARK: - Starting

  private func bringUp(_ profile: EvieModelProfile, runtime: LocalRuntime) async throws -> URL {
    if let listener = EvieProcessInspector.listeningPID(onPort: runtime.port) {
      // Something already holds the port: only the configured server is
      // waited for (it may still be loading), anything else is refused.
      guard Self.isServer(listener, runtime: runtime) else {
        throw LocalBrainLaunchError.portHeld(port: runtime.port)
      }
      try await waitUntilHealthy(profile, runtime: runtime, pid: listener)
      adopt(listener, runtime: runtime)
      return runtime.endpoint
    }
    guard FileManager.default.isExecutableFile(atPath: runtime.executable) else {
      throw LocalBrainLaunchError.notInstalled(executable: runtime.executable)
    }
    let verdict = policy.startVerdict(
      availableBytes: Self.availableMemoryBytes(),
      voiceEngineResident: EvieVoiceEngineLauncher.isPortBound()
    )
    if case .refuse(let explanation) = verdict {
      throw LocalBrainLaunchError.lowMemory(explanation)
    }

    let process = try spawn(runtime, model: profile.model)
    child = process
    managed = (process.processIdentifier, runtime)
    do {
      try await waitUntilHealthy(profile, runtime: runtime, pid: process.processIdentifier)
      // `/health` says something answered; the conversation goes only to the
      // process spawned here.
      guard
        let listener = EvieProcessInspector.listeningPID(onPort: runtime.port),
        EvieProcessInspector.selfAndDescendants(of: process.processIdentifier).contains(listener)
      else {
        throw LocalBrainLaunchError.notOurServer(port: runtime.port)
      }
    } catch {
      stop()
      throw error
    }
    noteUse()
    watchIdleTime()
    // Where the server was just bound and checked, not the profile's own
    // address: the turn goes only where who listens was checked.
    return runtime.endpoint
  }

  private func spawn(_ runtime: LocalRuntime, model: String) throws -> Process {
    let manager = FileManager.default
    do {
      try manager.createDirectory(
        at: Self.runtimeDirectory,
        withIntermediateDirectories: true,
        attributes: [.posixPermissions: 0o700]
      )
    } catch {
      throw LocalBrainLaunchError.couldNotLaunch(error.localizedDescription)
    }
    let log = try Self.openLog()
    defer { try? log.close() }

    let process = Process()
    process.executableURL = URL(fileURLWithPath: runtime.executable, isDirectory: false)
    process.arguments = LocalBrainPolicy.makeArguments(runtime, model: model)
    process.environment = LocalBrainPolicy.makeEnvironment(
      inheriting: ProcessInfo.processInfo.environment)
    process.standardOutput = log
    process.standardError = log
    // No stdin: the server reads none, and an inherited one would tie an 8 GB
    // model to Evie's terminal when she is run from one.
    process.standardInput = FileHandle.nullDevice
    do {
      try process.run()
    } catch {
      throw LocalBrainLaunchError.couldNotLaunch(error.localizedDescription)
    }
    // The file `Scripts/evie-brain` writes, so `stop` and `status` there see
    // the server Evie started.
    try? String(process.processIdentifier).write(
      to: Self.pidURL, atomically: true, encoding: .utf8)
    try? manager.setAttributes([.posixPermissions: 0o600], ofItemAtPath: Self.pidURL.path)
    return process
  }

  /// Polls `/health` until it answers, the process dies, or the start takes
  /// longer than `readyTimeout`.
  private func waitUntilHealthy(
    _ profile: EvieModelProfile,
    runtime: LocalRuntime,
    pid: pid_t
  ) async throws {
    let health = URL(string: "http://127.0.0.1:\(runtime.port)/health")!
    let deadline = ContinuousClock.now + Self.readyTimeout
    while ContinuousClock.now < deadline {
      guard EvieProcessInspector.isAlive(pid) else {
        throw LocalBrainLaunchError.exitedDuringStartup
      }
      if await answers(health) {
        return
      }
      try await Task.sleep(for: .milliseconds(500))
    }
    throw LocalBrainLaunchError.neverAnswered(seconds: Int(Self.readyTimeout.components.seconds))
  }

  private func answers(_ health: URL) async -> Bool {
    guard let (_, response) = try? await healthSession.data(from: health) else {
      return false
    }
    return ((response as? HTTPURLResponse)?.statusCode).map { (200...299).contains($0) } ?? false
  }

  // MARK: - Idle

  private func adopt(_ pid: pid_t, runtime: LocalRuntime) {
    if managed?.pid != pid {
      managed = (pid, runtime)
      if child?.processIdentifier != pid {
        child = nil
      }
    }
    if lastUse == nil {
      noteUse()
    }
    watchIdleTime()
  }

  private func watchIdleTime() {
    guard idleWatch == nil else {
      return
    }
    idleWatch = Task { @MainActor [weak self] in
      while !Task.isCancelled {
        try? await Task.sleep(for: Self.idleCheckInterval)
        guard let self, !Task.isCancelled else { return }
        // A start in progress is not idle time.
        guard launch == nil, let lastUse else { continue }
        if policy.shouldUnload(lastUse: lastUse, now: .now) {
          idleWatch = nil
          stop()
          return
        }
      }
    }
  }

  // MARK: - Process checks

  private static func runtime(of profile: EvieModelProfile) throws -> LocalRuntime {
    guard case .localOnDemand(let runtime) = profile.runtime else {
      throw LocalBrainLaunchError.couldNotLaunch("\(profile.displayName) não roda neste Mac.")
    }
    return runtime
  }

  /// The pid's argv names the configured executable and port, and its image
  /// is that executable — or, for a `#!` script, the interpreter it names —
  /// with symlinks resolved.
  static func isServer(_ pid: pid_t, runtime: LocalRuntime) -> Bool {
    guard
      EvieProcessInspector.isAlive(pid),
      let arguments = EvieProcessInspector.arguments(of: pid),
      LocalBrainPolicy.argumentsIdentifyServer(arguments, runtime: runtime),
      let image = EvieProcessInspector.executablePath(of: pid)
    else {
      return false
    }
    return expectedImages(for: runtime.executable).contains(image)
  }

  private static func expectedImages(for executable: String) -> Set<String> {
    var images: Set<String> = [resolved(executable)]
    if let handle = FileHandle(forReadingAtPath: executable) {
      defer { try? handle.close() }
      let head = String(decoding: (try? handle.read(upToCount: 512)) ?? Data(), as: UTF8.self)
      if let interpreter = LocalBrainPolicy.interpreterPath(fromScriptHead: head) {
        images.insert(resolved(interpreter))
      }
    }
    return images
  }

  private static func resolved(_ path: String) -> String {
    URL(fileURLWithPath: path).resolvingSymlinksInPath().path
  }

  private static func recordedPID() -> pid_t? {
    guard let text = try? String(contentsOf: pidURL, encoding: .utf8) else {
      return nil
    }
    return pid_t(text.trimmingCharacters(in: .whitespacesAndNewlines))
  }

  private static func removePIDFile(ifItNames pid: pid_t) {
    if recordedPID() == pid {
      try? FileManager.default.removeItem(at: pidURL)
    }
  }

  /// Polls rather than waits: the server may not be Evie's child, and a child
  /// is reaped by `Process` itself.
  private static func waitForExit(of pid: pid_t, within grace: Duration) -> Bool {
    let deadline = ContinuousClock.now + grace
    while ContinuousClock.now < deadline {
      if !EvieProcessInspector.isAlive(pid) {
        return true
      }
      usleep(50_000)
    }
    return !EvieProcessInspector.isAlive(pid)
  }

  private static func openLog() throws -> FileHandle {
    let manager = FileManager.default
    let path = logURL.path
    if let size = (try? manager.attributesOfItem(atPath: path))?[.size] as? Int,
      size > logRotationBytes
    {
      let previous = runtimeDirectory.appendingPathComponent("brain.log.1", isDirectory: false)
      try? manager.removeItem(at: previous)
      try? manager.moveItem(at: logURL, to: previous)
    }
    if !manager.fileExists(atPath: path) {
      manager.createFile(atPath: path, contents: nil, attributes: [.posixPermissions: 0o600])
    }
    guard let log = FileHandle(forWritingAtPath: path) else {
      throw LocalBrainLaunchError.couldNotLaunch("não consegui abrir o log")
    }
    // Appended to rather than truncated: the previous run's failure is often
    // the only record of why this one is happening.
    _ = try? log.seekToEnd()
    let stamp = ISO8601DateFormatter().string(from: Date())
    try? log.write(contentsOf: Data("--- \(stamp) Evie launcher start\n".utf8))
    return log
  }

  /// Free + inactive + purgeable pages, what macOS can hand out without paging
  /// out anything in use. `os_proc_available_memory` is unavailable on macOS.
  static func availableMemoryBytes() -> UInt64 {
    var statistics = vm_statistics64()
    var count = mach_msg_type_number_t(
      MemoryLayout<vm_statistics64>.size / MemoryLayout<integer_t>.size)
    let result = withUnsafeMutablePointer(to: &statistics) {
      $0.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
        host_statistics64(mach_host_self(), HOST_VM_INFO64, $0, &count)
      }
    }
    guard result == KERN_SUCCESS else {
      return 0
    }
    let pages =
      UInt64(statistics.free_count) + UInt64(statistics.inactive_count)
      + UInt64(statistics.purgeable_count)
    return pages * UInt64(getpagesize())
  }
}
