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
/// executable serving that port on loopback alone, and after a start it must
/// be the process this launcher spawned. Every start gets a key of its own
/// (`LocalBrainKeyFile`, ADR 0017) in the server's environment, and a server
/// is used only once it has refused `/health` without that key and answered it
/// with it. A pid from the pid file is never signalled before its image and
/// argv are checked, because pids get reused.
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
  /// How often the idle clock is read. A minute either way on a ten-minute
  /// timeout does not matter; waking up more often would.
  static let idleCheckInterval: Duration = .seconds(30)
  /// Past this the log is moved aside at the next start. At INFO each
  /// request writes about ten lines.
  static let logRotationBytes = 10 << 20

  private let policy: LocalBrainPolicy
  private let shutdown: LocalBrainShutdown
  private let keyFile: LocalBrainKeyFile
  private let storageDirectory: URL
  private var pidFileURL: URL { storageDirectory.appendingPathComponent("brain.pid") }
  private var logFileURL: URL { storageDirectory.appendingPathComponent("brain.log") }
  private let healthSession: URLSession
  /// The server this launcher spawned. Keeping the `Process` keeps its exit
  /// observable and its pid ours until it is reaped.
  private var child: Process?
  /// The server Evie manages: her child, or one `Scripts/evie-brain` started
  /// that she has since used. It is the one the idle timer and quit stop.
  private var managed: (pid: pid_t, runtime: LocalRuntime)?
  /// The server last seen holding to the key, by pid and start time, so a
  /// turn on it does not ask twice and a reused pid is asked again.
  private var keyVerified: (pid: pid_t, started: UInt64)?
  private var lastUse: ContinuousClock.Instant?
  /// The start under way, shared by the turns waiting on it and cancelled
  /// when none of them still wants it.
  private let wake = LocalBrainWake<URL>()
  /// A stop under way. A start waits for it, so a new server is never
  /// launched onto a port the old one still holds.
  private var stopping: Task<Void, Never>?
  private var idleWatch: Task<Void, Never>?

  init(
    policy: LocalBrainPolicy = .standard,
    shutdown: LocalBrainShutdown = .standard,
    keyFile: LocalBrainKeyFile = .standard,
    storageDirectory: URL = EvieLocalBrainLauncher.runtimeDirectory
  ) {
    self.policy = policy
    self.shutdown = shutdown
    self.keyFile = keyFile
    self.storageDirectory = storageDirectory
    let configuration = URLSessionConfiguration.ephemeral
    configuration.timeoutIntervalForRequest = 3
    configuration.urlCache = nil
    healthSession = URLSession(configuration: configuration)
  }

  // MARK: - LocalBrainStarting

  /// Cancelling the turn that waits here — the last one, when several do —
  /// cancels the start, and a child that has not answered yet is stopped.
  func ensureRunning(_ profile: EvieModelProfile) async throws -> URL {
    let runtime = try Self.runtime(of: profile)
    await stopping?.value
    return try await wake.value { [weak self] in
      guard let self else { throw CancellationError() }
      return try await bringUp(profile, runtime: runtime)
    }
  }

  func isServing(_ profile: EvieModelProfile) async throws -> URL? {
    let runtime = try Self.runtime(of: profile)
    // A server being stopped is not serving; the turn's wake waits for the
    // stop and starts another.
    guard stopping == nil,
      let listener = EvieProcessInspector.listeningPID(onPort: runtime.port)
    else {
      return nil
    }
    guard Self.isServer(listener, runtime: runtime) else {
      throw LocalBrainLaunchError.portHeld(port: runtime.port)
    }
    try await confirmKey(of: listener, runtime: runtime)
    guard Self.servesProfile(listener, runtime: runtime, model: profile.model) else { return nil }
    adopt(listener, runtime: runtime)
    return runtime.endpoint
  }

  func noteUse() {
    lastUse = .now
  }

  // MARK: - Stopping

  /// Stops the managed server: SIGTERM, then SIGKILL after five seconds
  /// (`LocalBrainShutdown`), waiting by suspending, so the main actor — the
  /// overlay — keeps running. With `.graceOnly`, for quit, it does not wait
  /// for SIGKILL to land. A pid that is no longer this server is left alone
  /// and only forgotten.
  func stop(waiting: LocalBrainShutdown.Wait = .untilGone) async {
    if let stopping {
      await stopping.value
      return
    }
    idleWatch?.cancel()
    idleWatch = nil
    guard let (pid, runtime) = managed.map({ ($0.pid, $0.runtime) }) else {
      return
    }
    managed = nil
    child = nil
    lastUse = nil
    keyVerified = nil
    guard Self.isServer(pid, runtime: runtime) else {
      forgetFiles(ofServer: pid)
      return
    }
    let shutdown = shutdown
    let task = Task { @MainActor [weak self] in
      _ = await shutdown.stop(
        signal: { kill(pid, $0) },
        isAlive: { EvieProcessInspector.isAlive(pid) },
        waiting: waiting
      )
      self?.forgetFiles(ofServer: pid)
    }
    stopping = task
    await task.value
    stopping = nil
  }

  /// SIGTERM without waiting, for the last moment of quit when
  /// `prepareForTermination` did not get to `stop(waiting: .graceOnly)`.
  func stopWithoutWaiting() {
    guard let (pid, runtime) = managed.map({ ($0.pid, $0.runtime) }) else {
      return
    }
    managed = nil
    if Self.isServer(pid, runtime: runtime) {
      kill(pid, SIGTERM)
    }
  }

  /// At Evie's launch: a pid file that names no live server is removed; one
  /// that names a live server — left by a crash, or started by the script — is
  /// taken over, so the idle timer stops it if nothing uses it.
  func reconcilePIDFile(for profiles: EvieModelProfileSet) {
    guard let pid = recordedPID() else {
      return
    }
    let runtimes = profiles.profiles.compactMap { profile -> LocalRuntime? in
      if case .localOnDemand(let runtime) = profile.runtime { runtime } else { nil }
    }
    guard let runtime = runtimes.first(where: { Self.isServer(pid, runtime: $0) }),
      EvieProcessInspector.listens(pid, onPort: runtime.port)
    else {
      try? FileManager.default.removeItem(at: pidFileURL)
      keyFile.remove()
      return
    }
    adopt(pid, runtime: runtime)
  }

  // MARK: - Starting

  private func bringUp(_ profile: EvieModelProfile, runtime: LocalRuntime) async throws -> URL {
    // Reconfigure only when a turn actually needs the new runtime. A Settings
    // save or background readiness probe must not interrupt a running reply.
    if let managed, managed.runtime != runtime {
      await stop()
      try Task.checkCancellation()
    }
    if let listener = EvieProcessInspector.listeningPID(onPort: runtime.port) {
      // Something already holds the port: only the configured server is
      // waited for (it may still be loading), anything else is refused.
      guard Self.isServer(listener, runtime: runtime) else {
        throw LocalBrainLaunchError.portHeld(port: runtime.port)
      }
      // Started by the script, or by an earlier Evie: its key is the file's.
      guard let key = keyFile.read() else {
        throw LocalBrainLaunchError.unverifiedKey(port: runtime.port)
      }
      try await waitUntilHealthy(runtime: runtime, pid: listener, key: key)
      try await confirmKey(of: listener, runtime: runtime)
      if Self.servesProfile(listener, runtime: runtime, model: profile.model) {
        adopt(listener, runtime: runtime)
        return runtime.endpoint
      }
      // An authenticated Evie server with old context/model options is ours
      // to restart; a foreign listener above is never signalled.
      adopt(listener, runtime: runtime)
      await stop()
      try Task.checkCancellation()
      guard EvieProcessInspector.listeningPID(onPort: runtime.port) == nil else {
        throw LocalBrainLaunchError.portHeld(port: runtime.port)
      }
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
    // Cancelled while the checks ran: nothing has been spawned yet.
    try Task.checkCancellation()

    let (process, key) = try spawn(runtime, model: profile.model)
    child = process
    managed = (process.processIdentifier, runtime)
    do {
      try await waitUntilHealthy(runtime: runtime, pid: process.processIdentifier, key: key)
      // `/health` says something answered; the conversation goes only to the
      // process spawned here, and only once it holds to its key — which also
      // catches an mlx-vlm that no longer reads the variable.
      guard
        let listener = EvieProcessInspector.listeningPID(onPort: runtime.port),
        EvieProcessInspector.selfAndDescendants(of: process.processIdentifier).contains(listener)
      else {
        throw LocalBrainLaunchError.notOurServer(port: runtime.port)
      }
      try await confirmKey(of: listener, runtime: runtime)
    } catch {
      // Also how a cancelled wake ends: the child has not answered yet, and
      // nobody is waiting for it any more.
      await stop()
      throw error
    }
    noteUse()
    watchIdleTime()
    // Where the server was just bound and checked, not the profile's own
    // address: the turn goes only where who listens was checked.
    return runtime.endpoint
  }

  /// Launches the server with a key made for this launch, written 0600 beside
  /// the pid file first, so a server is never up without its key on disk.
  private func spawn(_ runtime: LocalRuntime, model: String) throws -> (Process, String) {
    let manager = FileManager.default
    do {
      try manager.createDirectory(
        at: storageDirectory,
        withIntermediateDirectories: true,
        attributes: [.posixPermissions: 0o700]
      )
    } catch {
      throw LocalBrainLaunchError.couldNotLaunch(error.localizedDescription)
    }
    let log = try openLog()
    defer { try? log.close() }
    let head: String
    if runtime.metalCacheLimitMB != nil {
      let handle = try FileHandle(forReadingFrom: URL(fileURLWithPath: runtime.executable))
      defer { try? handle.close() }
      head = String(decoding: try handle.read(upToCount: 512) ?? Data(), as: UTF8.self)
    } else {
      head = ""
    }
    guard let executable = LocalBrainPolicy.launchExecutable(runtime, scriptHead: head) else {
      throw LocalBrainLaunchError.couldNotLaunch(
        "O launcher local precisa de um interpretador Python absoluto no cabeçalho.")
    }
    let key = LocalBrainKeyFile.makeKey()
    do {
      try keyFile.write(key)
    } catch {
      throw LocalBrainLaunchError.couldNotLaunch(
        "não consegui guardar a chave: \(error.localizedDescription)")
    }

    let process = Process()
    process.executableURL = URL(fileURLWithPath: executable, isDirectory: false)
    process.currentDirectoryURL = storageDirectory
    process.arguments = LocalBrainPolicy.makeArguments(runtime, model: model)
    process.environment = LocalBrainPolicy.makeEnvironment(
      inheriting: ProcessInfo.processInfo.environment, apiKey: key)
    process.standardOutput = log
    process.standardError = log
    // No stdin: the server reads none, and an inherited one would tie an 8 GB
    // model to Evie's terminal when she is run from one.
    process.standardInput = FileHandle.nullDevice
    do {
      try process.run()
    } catch {
      keyFile.remove()
      throw LocalBrainLaunchError.couldNotLaunch(error.localizedDescription)
    }
    // The file `Scripts/evie-brain` writes, so `stop` and `status` there see
    // the server Evie started.
    try? String(process.processIdentifier).write(
      to: pidFileURL, atomically: true, encoding: .utf8)
    try? manager.setAttributes([.posixPermissions: 0o600], ofItemAtPath: pidFileURL.path)
    return (process, key)
  }

  /// Polls `/health` with the key until it answers, the process dies, or the
  /// start takes longer than `readyTimeout`.
  private func waitUntilHealthy(runtime: LocalRuntime, pid: pid_t, key: String) async throws {
    let health = Self.healthURL(runtime)
    let deadline = ContinuousClock.now + Self.readyTimeout
    while ContinuousClock.now < deadline {
      try Task.checkCancellation()
      guard EvieProcessInspector.isAlive(pid) else {
        throw LocalBrainLaunchError.exitedDuringStartup
      }
      if let status = await status(of: health, key: key), (200...299).contains(status) {
        return
      }
      try await Task.sleep(for: .milliseconds(500))
    }
    throw LocalBrainLaunchError.neverAnswered(seconds: Int(Self.readyTimeout.components.seconds))
  }

  /// The listener refuses `/health` without the key in `brain.key` and
  /// answers it with it (`LocalBrainPolicy.enforcesKey`). Asked once per
  /// server: a server's key does not change while it runs.
  private func confirmKey(of pid: pid_t, runtime: LocalRuntime) async throws {
    let started = EvieProcessInspector.startTime(of: pid)
    if let started, let keyVerified, keyVerified.pid == pid, keyVerified.started == started {
      return
    }
    let health = Self.healthURL(runtime)
    let withoutKey = await status(of: health, key: nil)
    var withKey: Int?
    if let key = keyFile.read() {
      withKey = await status(of: health, key: key)
    }
    guard let started,
      LocalBrainPolicy.enforcesKey(statusWithoutKey: withoutKey, statusWithKey: withKey)
    else {
      throw LocalBrainLaunchError.unverifiedKey(port: runtime.port)
    }
    keyVerified = (pid, started)
  }

  private func status(of health: URL, key: String?) async -> Int? {
    var request = URLRequest(url: health)
    if let key {
      request.setValue("Bearer \(key)", forHTTPHeaderField: "Authorization")
    }
    guard let (_, response) = try? await healthSession.data(for: request) else {
      return nil
    }
    return (response as? HTTPURLResponse)?.statusCode
  }

  private static func healthURL(_ runtime: LocalRuntime) -> URL {
    URL(string: "http://127.0.0.1:\(runtime.port)/health")!
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
        guard !wake.isRunning, let lastUse else { continue }
        if policy.shouldUnload(lastUse: lastUse, now: .now) {
          idleWatch = nil
          await stop()
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

  /// The pid's argv names the configured executable and port with
  /// `--host 127.0.0.1` last, it listens on nothing but loopback, and its image
  /// is that executable — or, for a `#!` script, the interpreter it names —
  /// with symlinks resolved.
  static func isServer(_ pid: pid_t, runtime: LocalRuntime) -> Bool {
    guard
      EvieProcessInspector.isAlive(pid),
      let arguments = EvieProcessInspector.arguments(of: pid),
      LocalBrainPolicy.argumentsIdentifyServer(arguments, runtime: runtime),
      LocalBrainPolicy.listensOnlyOnLoopback(
        EvieProcessInspector.listeningSockets(of: pid).map(\.address)),
      let image = EvieProcessInspector.executablePath(of: pid)
    else {
      return false
    }
    return expectedImages(for: runtime.executable).contains(image)
  }

  private static func servesProfile(_ pid: pid_t, runtime: LocalRuntime, model: String) -> Bool {
    guard let arguments = EvieProcessInspector.arguments(of: pid) else { return false }
    return LocalBrainPolicy.argumentsServeProfile(arguments, runtime: runtime, model: model)
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

  private func recordedPID() -> pid_t? {
    guard let text = try? String(contentsOf: pidFileURL, encoding: .utf8) else {
      return nil
    }
    return pid_t(text.trimmingCharacters(in: .whitespacesAndNewlines))
  }

  /// Removes the pid file and the key that went with it, when the pid file
  /// names this server: the key opens nothing once the server is gone.
  private func forgetFiles(ofServer pid: pid_t) {
    if recordedPID() == pid {
      try? FileManager.default.removeItem(at: pidFileURL)
      keyFile.remove()
    }
  }

  private func openLog() throws -> FileHandle {
    let manager = FileManager.default
    let path = logFileURL.path
    if let size = (try? manager.attributesOfItem(atPath: path))?[.size] as? Int,
      size > Self.logRotationBytes
    {
      let previous = storageDirectory.appendingPathComponent("brain.log.1", isDirectory: false)
      try? manager.removeItem(at: previous)
      try? manager.moveItem(at: logFileURL, to: previous)
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
