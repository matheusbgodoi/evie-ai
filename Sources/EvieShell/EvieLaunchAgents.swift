import EvieCore
import Foundation

/// The files in `~/Library/LaunchAgents`, and `launchctl`.
///
/// Two things have to stay in step: the plist on disk, and whether `launchd` is
/// currently holding the job. They are not the same thing — a plist deleted
/// while its job is loaded keeps firing until the user logs out, and a job
/// bootstrapped from a file that has since changed keeps the old times. Every
/// operation here does both halves, in the order that leaves nothing running
/// which has no file behind it.
struct EvieLaunchAgents: Sendable {
  let directory: URL
  let logDirectory: URL
  /// The binary `launchd` will run. Evie's own, normally; injectable so a check
  /// can point a job at something else.
  let executable: URL

  init(
    directory: URL = EvieLaunchAgents.defaultDirectory,
    logDirectory: URL = EvieLaunchAgents.defaultLogDirectory,
    executable: URL = EvieLaunchAgents.defaultExecutable
  ) {
    self.directory = directory
    self.logDirectory = logDirectory
    self.executable = executable
  }

  static var defaultDirectory: URL {
    FileManager.default.homeDirectoryForCurrentUser
      .appendingPathComponent("Library/LaunchAgents", isDirectory: true)
  }

  static var defaultLogDirectory: URL {
    FileManager.default.homeDirectoryForCurrentUser
      .appendingPathComponent("Library/Logs/Evie", isDirectory: true)
  }

  /// The executable inside this very bundle.
  ///
  /// Resolved at the moment a schedule is installed, not hard-coded, because a
  /// person who moves Evie.app out of `~/Applications` should be able to fix
  /// their schedules by saving them again rather than by editing plists.
  static var defaultExecutable: URL {
    Bundle.main.executableURL ?? URL(fileURLWithPath: CommandLine.arguments[0])
  }

  enum Failure: Error, Equatable, Sendable {
    case couldNotWritePlist
    case launchctlFailed(command: String, status: Int32, output: String)
  }

  func plistURL(for schedule: EvieSchedule) -> URL {
    directory.appendingPathComponent(
      EvieScheduleAgent.fileName(forIdentifier: schedule.id),
      isDirectory: false
    )
  }

  func logURL(for schedule: EvieSchedule) -> URL {
    logDirectory.appendingPathComponent(
      EvieScheduleAgent.logFileName(forIdentifier: schedule.id),
      isDirectory: false
    )
  }

  /// Writes the job and hands it to `launchd`.
  ///
  /// Any previous version is booted out first. `bootstrap` on a label that is
  /// already loaded fails with "service already loaded" and leaves the *old*
  /// times in place — so an edit that looked like it saved would go on firing at
  /// the hour the user had just changed.
  func install(_ schedule: EvieSchedule) throws {
    try FileManager.default.createDirectory(
      at: directory,
      withIntermediateDirectories: true
    )
    try FileManager.default.createDirectory(
      at: logDirectory,
      withIntermediateDirectories: true
    )

    let plist = EvieScheduleAgent.propertyList(
      for: schedule,
      executable: executable,
      logDirectory: logDirectory
    )
    guard let data = try? plist.xmlData() else {
      throw Failure.couldNotWritePlist
    }
    unload(schedule)
    try data.write(to: plistURL(for: schedule), options: .atomic)
    try bootstrap(plistURL(for: schedule))
  }

  /// Unloads the job and removes the file, in that order.
  ///
  /// The other order leaves `launchd` holding a job whose plist is gone, which
  /// keeps running until logout and cannot be unloaded by path any more.
  func remove(_ schedule: EvieSchedule) {
    unload(schedule)
    try? FileManager.default.removeItem(at: plistURL(for: schedule))
  }

  /// Whether `launchd` currently holds this job.
  func isLoaded(_ schedule: EvieSchedule) -> Bool {
    let result = launchctl(["print", "\(domain)/\(schedule.label)"])
    return result.status == 0
  }

  /// Runs the job now, without waiting for its trigger.
  ///
  /// `kickstart` rather than launching the binary ourselves, so what is proved
  /// is the job `launchd` holds — including its arguments and its log paths —
  /// and not a second path that happens to look similar.
  func runNow(_ schedule: EvieSchedule) throws {
    let result = launchctl(["kickstart", "-k", "\(domain)/\(schedule.label)"])
    guard result.status == 0 else {
      throw Failure.launchctlFailed(
        command: "kickstart",
        status: result.status,
        output: result.output
      )
    }
  }

  /// Every Evie schedule plist in the folder, whether or not the store still
  /// knows about it. Used to sweep up jobs left behind by a store that was
  /// edited or lost.
  func installedIdentifiers() -> [String] {
    let prefix = "com.matheusbgodoi.evie.schedule."
    let names = (try? FileManager.default.contentsOfDirectory(atPath: directory.path)) ?? []
    return names.compactMap { name in
      guard name.hasPrefix(prefix), name.hasSuffix(".plist") else {
        return nil
      }
      return String(name.dropFirst(prefix.count).dropLast(".plist".count))
    }
  }
}

extension EvieLaunchAgents {
  /// `gui/<uid>` — the user's own session. Not `user/<uid>`, which exists whether
  /// anybody is logged in or not: these jobs open a window's worth of machinery
  /// and post a notification, and both want a logged-in session.
  fileprivate var domain: String {
    "gui/\(getuid())"
  }

  fileprivate func bootstrap(_ url: URL) throws {
    let result = launchctl(["bootstrap", domain, url.path])
    guard result.status == 0 else {
      throw Failure.launchctlFailed(
        command: "bootstrap",
        status: result.status,
        output: result.output
      )
    }
  }

  /// Failure is ignored on purpose: "not loaded" is the state this wants, and
  /// `bootout` reports it as an error.
  fileprivate func unload(_ schedule: EvieSchedule) {
    _ = launchctl(["bootout", "\(domain)/\(schedule.label)"])
  }

  /// `bootstrap`/`bootout`, not `load`/`unload`. The old spelling still works and
  /// is documented as deprecated; it also reports success for jobs it did not
  /// load, which is how a schedule can appear to install and never fire.
  fileprivate func launchctl(_ arguments: [String]) -> (status: Int32, output: String) {
    let process = Process()
    process.executableURL = URL(fileURLWithPath: "/bin/launchctl")
    process.arguments = arguments
    let pipe = Pipe()
    process.standardOutput = pipe
    process.standardError = pipe
    do {
      try process.run()
    } catch {
      return (-1, "\(error)")
    }
    // Read before waiting. `launchctl print` writes more than a pipe buffer
    // holds, and a full pipe with nobody reading it is a process that never
    // exits.
    let data = pipe.fileHandleForReading.readDataToEndOfFile()
    process.waitUntilExit()
    return (
      process.terminationStatus,
      String(data: data, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
    )
  }
}
