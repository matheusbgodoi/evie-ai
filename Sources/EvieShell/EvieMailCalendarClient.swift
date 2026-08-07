import EvieCore
import Foundation

/// The only part of Evie that talks to another application on this Mac.
///
/// Everything it hands to `osascript` is a constant compiled into the binary —
/// the programs in `EvieAppleScripts` — and everything variable travels beside them
/// as process arguments after `--`, where `osascript` hands it to `on run argv`
/// as a value. Nothing the model writes and nothing a message contains is ever
/// concatenated into a script. That is the whole security posture of this file,
/// and it is the reason it is short enough to read in one sitting.
struct EvieMailCalendarClient:
  EvieMailCalendarReading, EvieCalendarWriting, EvieMailSending, Sendable
{
  static let executable = URL(fileURLWithPath: "/usr/bin/osascript")

  /// How long a read may take before it is abandoned.
  ///
  /// Generous, because Mail is genuinely slow: measured on this Mac against a
  /// 1,952-message inbox, five messages with their bodies took 5.8 s, and the
  /// unread filter alone took 7.3 s. The ceiling exists for the case where Mail
  /// is mid-sync and simply never answers, which would otherwise hold the turn
  /// open until the person gave up on the application rather than on the
  /// question.
  var timeout: TimeInterval = 90

  /// More than any answer needs, and a hard stop on a mailbox that decides to
  /// hand over everything it has.
  static let maximumOutputBytes = 512 * 1_024

  func readMail(count: Int, unreadOnly: Bool) async throws -> [EvieMailMessage] {
    let output = try await run(
      EvieAppleScripts.readMail,
      arguments: [String(count), unreadOnly ? "unread" : "all"],
      app: .mail
    )
    return EvieMailCalendar.parseMessages(output)
  }

  func searchMail(term: String, count: Int) async throws -> [EvieMailMessage] {
    let output = try await run(
      EvieAppleScripts.searchMail,
      arguments: [term, String(count)],
      app: .mail
    )
    return EvieMailCalendar.parseMessages(output)
  }

  func readCalendar(from: Date, to: Date, limit: Int) async throws -> [EvieCalendarEvent] {
    let calendar = Calendar.current
    let start = calendar.dateComponents([.year, .month, .day], from: from)
    let end = calendar.dateComponents([.year, .month, .day], from: to)
    guard
      let y1 = start.year, let m1 = start.month, let d1 = start.day,
      let y2 = end.year, let m2 = end.month, let d2 = end.day
    else {
      throw EvieMailCalendarError.badDateRange
    }

    // Six integers rather than a formatted date. A date literal in AppleScript
    // is read in the machine's locale, and this Mac is pt-BR; numbers are not.
    let output = try await run(
      EvieAppleScripts.readCalendar,
      arguments: [y1, m1, d1, y2, m2, d2, limit].map(String.init),
      app: .calendar
    )
    return EvieMailCalendar.parseEvents(output)
  }

  func listCalendars() async throws -> [String] {
    let output = try await run(EvieAppleScripts.listCalendars, arguments: [], app: .calendar)
    return
      output
      .split(separator: EvieMailCalendar.fieldSeparator, omittingEmptySubsequences: true)
      .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
      .filter { !$0.isEmpty }
  }

  func listMailAccounts() async throws -> [String] {
    let output = try await run(EvieAppleScripts.listMailAccounts, arguments: [], app: .mail)
    return
      output
      .split(separator: EvieMailCalendar.fieldSeparator, omittingEmptySubsequences: true)
      .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
      .filter { !$0.isEmpty }
  }

  /// The one call in this file that reaches another person.
  ///
  /// It looks exactly like the reads, and that is the point: the subject, the
  /// body, the sending address and each recipient travel as process arguments
  /// beside a script that is a compiled-in constant, so a body a model wrote out
  /// of something in an e-mail is a body. Every recipient is its own argument —
  /// nothing is joined with commas and split again, because that split is where
  /// one stray character becomes an extra address.
  ///
  /// It returns nothing and throws instead. There is no useful value here: the
  /// message either went or it did not, and a `Bool` nobody is forced to read is
  /// how "enviado" ends up on screen for a message that never left.
  func sendMail(_ proposal: EvieMailProposal) async throws {
    let output = try await run(
      EvieAppleScripts.sendMail,
      arguments: [proposal.subject, proposal.body, proposal.sender] + proposal.recipients,
      app: .mail
    )
    switch output.trimmingCharacters(in: .whitespacesAndNewlines) {
    case EvieMailCalendar.sentMarker:
      return
    case EvieMailCalendar.missingAccountMarker:
      throw EvieMailCalendarError.accountGone(proposal.sender)
    default:
      // Anything else, including the empty string, is a script that did not get
      // to its last line. Reported as not sent, which is the safe direction to be
      // wrong in: he checks Sent and finds it, rather than believing it went.
      throw EvieMailCalendarError.notSent
    }
  }

  func saveMailDraft(_ proposal: EvieMailProposal) async throws {
    let output = try await run(
      EvieAppleScripts.saveMailDraft,
      arguments: [proposal.subject, proposal.body, proposal.sender] + proposal.recipients,
      app: .mail
    )
    switch output.trimmingCharacters(in: .whitespacesAndNewlines) {
    case EvieMailCalendar.draftedMarker:
      return
    case EvieMailCalendar.missingAccountMarker:
      throw EvieMailCalendarError.accountGone(proposal.sender)
    default:
      throw EvieMailCalendarError.failed(.mail, "o Mail não guardou o rascunho")
    }
  }

  /// The one call in this file that changes something.
  ///
  /// It looks exactly like the reads, and that is the point: the title, the
  /// calendar name and the location travel as process arguments beside a script
  /// that is a compiled-in constant, so a title written by a model out of
  /// something in an e-mail is a title. The ten integers are the two moments,
  /// never a formatted date — the script rebuilds them with arithmetic, which no
  /// locale can reinterpret.
  func createEvent(_ proposal: EvieCalendarEventProposal) async throws -> String {
    let moments =
      EvieMailCalendar.components(of: proposal.startsAt)
      + EvieMailCalendar.components(of: proposal.endsAt)
    let output = try await run(
      EvieAppleScripts.createEvent,
      arguments: [proposal.title, proposal.calendarName, proposal.location]
        + moments.map(String.init),
      app: .calendar
    )
    let landed = output.trimmingCharacters(in: .whitespacesAndNewlines)
    guard landed != EvieMailCalendar.missingCalendarMarker else {
      throw EvieMailCalendarError.calendarGone(proposal.calendarName)
    }
    guard !landed.isEmpty else {
      throw EvieMailCalendarError.failed(.calendar, "o Calendário não confirmou o compromisso")
    }
    return landed
  }
}

extension EvieMailCalendarClient {
  /// Runs one script and returns what it printed.
  ///
  /// `SecureProcessRunner` is the right shape for this and cannot be used: it
  /// sends both output streams to `/dev/null`, and the output is the entire
  /// point here. So this is its own launcher, kept to the same rules — an
  /// absolute path, no shell anywhere in the chain, an argument vector rather
  /// than a command line, and a timeout that kills rather than waits.
  fileprivate func run(
    _ script: String,
    arguments: [String],
    app: EvieAppleApp
  ) async throws -> String {
    // A NUL cannot survive `execve`, and Foundation's behaviour on one is
    // undefined rather than documented. Refused here, where it is still a
    // sentence somebody can read.
    guard arguments.allSatisfy({ !$0.contains("\0") }) else {
      throw EvieMailCalendarError.failed(app, "argumento inválido")
    }

    let deadline = timeout
    return try await withTaskCancellationHandler {
      try await withCheckedThrowingContinuation { continuation in
        // Off the main actor on purpose: this blocks for seconds at a time, and
        // the overlay has to keep drawing its "lendo seu Mail…" line while it
        // does.
        DispatchQueue.global(qos: .userInitiated).async {
          continuation.resume(
            with: Result {
              try Self.launch(script, arguments: arguments, app: app, timeout: deadline)
            }
          )
        }
      }
    } onCancel: {
      // Nothing to do: the child is bounded by its own timeout, and a half-read
      // mailbox is discarded by the continuation's caller either way.
    }
  }

  /// The blocking half. Never called on the main actor.
  fileprivate static func launch(
    _ script: String,
    arguments: [String],
    app: EvieAppleApp,
    timeout: TimeInterval
  ) throws -> String {
    let process = Process()
    process.executableURL = executable
    // `--` is what separates the script from its arguments. Without it,
    // `osascript` reads the first argument as another option, and an argument
    // that begins with a dash would change how the program is run rather than
    // what it is asked about.
    process.arguments = ["-e", script, "--"] + arguments
    // An empty environment, so nothing about this shell reaches the child.
    process.environment = [:]

    let outputPipe = Pipe()
    let errorPipe = Pipe()
    process.standardOutput = outputPipe
    process.standardError = errorPipe
    process.standardInput = FileHandle.nullDevice

    do {
      try process.run()
    } catch {
      throw EvieMailCalendarError.failed(app, error.localizedDescription)
    }

    // A watchdog rather than a wait with a deadline, because `waitUntilExit`
    // has none. The flag is read after the wait returns, so a process killed
    // here is reported as a timeout instead of as a mysterious signal.
    //
    // `Process` and `FileHandle` are not `Sendable`, and neither is wrong about
    // that — they are used from two queues here on purpose. The box is where
    // that is admitted rather than hidden.
    let child = ChildProcess(process: process, errorHandle: errorPipe.fileHandleForReading)
    DispatchQueue.global(qos: .utility).asyncAfter(deadline: .now() + timeout) {
      child.terminateIfStillRunning()
    }

    // Both pipes are drained before the wait. A pipe left unread fills at 64 KB
    // and blocks the child forever, which would look exactly like Mail hanging.
    // Standard error is drained on its own queue and joined afterwards, so the
    // buffer is complete by the time it is read.
    let draining = DispatchGroup()
    draining.enter()
    DispatchQueue.global(qos: .utility).async {
      child.readAllErrorOutput()
      draining.leave()
    }
    let outputData = outputPipe.fileHandleForReading.readDataToEndOfFile()
    process.waitUntilExit()
    draining.wait()

    if child.wasTimedOut {
      throw EvieMailCalendarError.timedOut(app)
    }
    let stderrText = String(data: child.errorOutput, encoding: .utf8) ?? ""
    if let failure = EvieMailCalendar.classify(
      stderr: stderrText,
      exitCode: process.terminationStatus,
      app: app
    ) {
      throw failure
    }

    let bounded = outputData.prefix(maximumOutputBytes)
    guard let text = String(data: bounded, encoding: .utf8) else {
      throw EvieMailCalendarError.failed(app, "a resposta não veio como texto")
    }
    if text.trimmingCharacters(in: .whitespacesAndNewlines) == EvieMailCalendar.closedAppMarker {
      throw EvieMailCalendarError.appNotOpen(app)
    }
    return text
  }
}

/// The child, and the two facts about it that three queues share.
///
/// The watchdog runs on one queue, standard error is drained on another, and
/// both are read back on the one that launched the process. Every crossing goes
/// through this lock. Without the flag a killed child is reported as whatever
/// exit status `SIGTERM` happened to produce, which reads as a mysterious
/// failure instead of "o Mail demorou demais".
private final class ChildProcess: @unchecked Sendable {
  private let lock = NSLock()
  private let process: Process
  private let errorHandle: FileHandle
  private var timedOut = false
  private var collectedError = Data()

  init(process: Process, errorHandle: FileHandle) {
    self.process = process
    self.errorHandle = errorHandle
  }

  func terminateIfStillRunning() {
    lock.lock()
    guard process.isRunning else {
      lock.unlock()
      return
    }
    timedOut = true
    lock.unlock()
    process.terminate()
  }

  func readAllErrorOutput() {
    let data = errorHandle.readDataToEndOfFile()
    lock.lock()
    collectedError = data
    lock.unlock()
  }

  var wasTimedOut: Bool {
    lock.lock()
    defer { lock.unlock() }
    return timedOut
  }

  var errorOutput: Data {
    lock.lock()
    defer { lock.unlock() }
    return collectedError
  }
}
