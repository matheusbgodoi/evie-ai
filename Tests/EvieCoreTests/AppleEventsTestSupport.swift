import CoreServices
import Foundation
import Testing

@testable import EvieCore

/// Whether this test process may send Apple Events to an app, asked without
/// ever showing the Automation consent prompt.
///
/// The grant belongs to whatever launched the test runner — a terminal, an
/// editor — and `osascript` inherits it the same way, so the answer here is the
/// answer the child will get. `askUserIfNeeded: false` is the whole point: the
/// prompt is what turned the suite into a 350 s run on 2026-10-16, because every
/// `osascript` sat waiting on a question nobody was looking at.
enum AppleEventsProbe {
  enum Permission: Equatable {
    case authorized
    /// `errAEEventNotPermitted` (-1743): the switch exists and is off.
    case denied
    /// `errAEEventWouldRequireUserConsent` (-1744): never asked yet.
    case wouldPrompt
    /// `procNotFound` (-600): the target is not running, so nothing can be said.
    case targetNotRunning
    case unknown(OSStatus)
  }

  static func permission(for bundleIdentifier: String) -> Permission {
    var target = AEAddressDesc()
    let bytes = Array(bundleIdentifier.utf8)
    guard
      AECreateDesc(DescType(typeApplicationBundleID), bytes, bytes.count, &target) == noErr
    else {
      return .unknown(OSStatus(paramErr))
    }
    defer { AEDisposeDesc(&target) }

    let status = AEDeterminePermissionToAutomateTarget(
      &target,
      AEEventClass(typeWildCard),
      AEEventID(typeWildCard),
      false
    )
    switch Int(status) {
    case Int(noErr): return .authorized
    case Int(errAEEventNotPermitted): return .denied
    case Int(errAEEventWouldRequireUserConsent): return .wouldPrompt
    case Int(procNotFound): return .targetNotRunning
    default: return .unknown(status)
    }
  }
}

/// The gate on the "runs to the end" expectations: exit 0, which holds once Mail
/// or Calendar has answered an Apple Event, or when the app is closed.
///
/// On by itself when the grant is already there or the app is not running, so
/// this Mac checks them on every run; forced on with
/// `EVIE_LIVE_APPLE_EVENTS=1`, which is how to see what they say in an
/// environment the probe considers unready.
enum LiveAppleEvents {
  static let comment: Comment =
    "requires the Apple Events grant or the app closed (or EVIE_LIVE_APPLE_EVENTS=1)"

  /// A closed app counts: every script asks `application "…" is running` before
  /// it addresses the app and returns `EVIE_APP_FECHADO` with exit 0, sending no
  /// event (checked by "every script asks whether its app is running before it
  /// addresses it"). If the app is opened between the probe and the run without
  /// a grant, the run waits on the prompt and the test reports the precondition.
  static func allowRunningToTheEnd(_ permission: AppleEventsProbe.Permission) -> Bool {
    switch permission {
    case .authorized, .targetNotRunning: true
    case .denied, .wouldPrompt, .unknown: false
    }
  }

  static func areEnabled(for app: EvieAppleApp) -> Bool {
    ProcessInfo.processInfo.environment["EVIE_LIVE_APPLE_EVENTS"] == "1"
      || allowRunningToTheEnd(AppleEventsProbe.permission(for: app.bundleIdentifier))
  }
}

extension EvieAppleApp {
  var bundleIdentifier: String {
    switch self {
    case .mail: "com.apple.mail"
    case .calendar: "com.apple.iCal"
    }
  }
}

/// One script run through the real `/usr/bin/osascript`, the way the client
/// runs it, bounded by a deadline.
///
/// Standard error is kept because it is the only place that says why a run
/// failed: a coercion error (-1700) is the behaviour under test, a refusal
/// (-1743) is a missing precondition, and the two are not the same result.
struct OsascriptRun {
  enum Outcome: Equatable {
    case exited(Int32)
    /// Killed at the deadline — in practice, waiting on the consent prompt.
    case timedOut
  }

  static let defaultTimeout: Duration = .seconds(10)

  let outcome: Outcome
  let standardError: String
  let app: EvieAppleApp

  /// Read with the client's own classifier, so the tests and the product cannot
  /// disagree about what a refusal looks like.
  var lacksAppleEventsGrant: Bool {
    guard case .exited(let status) = outcome else {
      return false
    }
    return EvieMailCalendar.classify(stderr: standardError, exitCode: status, app: app)
      == .notPermitted(app)
  }

  /// The `--` is what separates the program from its arguments. Without it,
  /// `osascript` reads the first argument as another of its own options.
  static func run(
    _ script: String,
    arguments: [String],
    app: EvieAppleApp,
    timeout: Duration = defaultTimeout
  ) throws -> OsascriptRun {
    let process = Process()
    process.executableURL = URL(fileURLWithPath: "/usr/bin/osascript")
    process.arguments = ["-e", script, "--"] + arguments
    process.standardInput = FileHandle.nullDevice
    process.standardOutput = FileHandle.nullDevice
    let errorPipe = Pipe()
    process.standardError = errorPipe

    let exited = DispatchSemaphore(value: 0)
    process.terminationHandler = { _ in exited.signal() }
    try process.run()

    let finished = exited.wait(timeout: .now() + timeout.timeInterval) == .success
    if !finished {
      process.terminate()
      if exited.wait(timeout: .now() + 2) == .timedOut {
        kill(process.processIdentifier, SIGKILL)
        exited.wait()
      }
    }
    // Read after the exit rather than drained alongside it: an `osascript`
    // error is one line, far below the 64 KB that would block the child.
    let errorData = errorPipe.fileHandleForReading.readDataToEndOfFile()
    return OsascriptRun(
      outcome: finished ? .exited(process.terminationStatus) : .timedOut,
      standardError: String(decoding: errorData, as: UTF8.self),
      app: app
    )
  }
}

extension Duration {
  fileprivate var timeInterval: TimeInterval {
    let (seconds, attoseconds) = components
    return TimeInterval(seconds) + TimeInterval(attoseconds) / 1e18
  }
}

@Suite("Apple Events test gating")
struct AppleEventsTestGatingTests {
  /// The probe must answer without a prompt and without a running target. An
  /// identifier nothing on any Mac has is the one target guaranteed to be absent.
  /// A closed app is not a missing grant for the "runs to the end" tests: every
  /// script returns `EVIE_APP_FECHADO` before it sends an event, so exit 0 holds.
  @Test("an authorized or closed app enables the run-to-the-end checks; a refusal does not")
  func runToTheEndGate() {
    #expect(LiveAppleEvents.allowRunningToTheEnd(.authorized))
    #expect(LiveAppleEvents.allowRunningToTheEnd(.targetNotRunning))
    #expect(!LiveAppleEvents.allowRunningToTheEnd(.denied))
    #expect(!LiveAppleEvents.allowRunningToTheEnd(.wouldPrompt))
    #expect(!LiveAppleEvents.allowRunningToTheEnd(.unknown(-1)))
  }

  @Test("the probe reports an absent app instead of asking about it")
  func probeReportsAbsentTarget() {
    #expect(
      AppleEventsProbe.permission(for: "com.matheusbgodoi.evie.tests.no-such-app")
        == .targetNotRunning
    )
  }

  /// A script that never returns stands in for one blocked on the consent
  /// prompt: the run has to end at the deadline and say that it did.
  @Test("a run that outlives its deadline is stopped and reported as such")
  func runStopsAtTheDeadline() throws {
    let started = ContinuousClock.now

    let run = try OsascriptRun.run(
      "on run argv\n\tdelay 30\nend run",
      arguments: [],
      app: .mail,
      timeout: .milliseconds(500)
    )

    #expect(run.outcome == .timedOut)
    #expect(ContinuousClock.now - started < .seconds(5))
  }

  /// The refusal macOS gives without the grant, raised by the script itself so
  /// the classification is checked without touching anybody's privacy settings.
  @Test("a refused Apple Event is classified as a missing grant")
  func refusalIsAMissingGrant() throws {
    let run = try OsascriptRun.run(
      "on run argv\n\terror \"Not authorized to send Apple events to Mail.\" number -1743\nend run",
      arguments: [],
      app: .mail,
      timeout: .seconds(10)
    )

    #expect(run.outcome != .exited(0))
    #expect(run.standardError.contains("-1743"))
    #expect(run.lacksAppleEventsGrant)
  }

  @Test("an ordinary script error is not mistaken for a missing grant")
  func ordinaryErrorIsNotAGrantProblem() throws {
    let run = try OsascriptRun.run(
      "on run argv\n\treturn (item 1 of argv) as integer\nend run",
      arguments: ["vinte"],
      app: .calendar,
      timeout: .seconds(10)
    )

    #expect(run.outcome != .exited(0))
    #expect(run.standardError.contains("-1700"))
    #expect(!run.lacksAppleEventsGrant)
  }
}
