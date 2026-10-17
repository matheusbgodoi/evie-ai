import AppKit
import EvieCore

/// Who has the keyboard while Evie acts, and who gets it back afterwards.
///
/// When the overlay opens, the app in front is the person's — the one they
/// were using when they called Evie — and `recordFrontmost` keeps it, so a
/// session can hand focus back to it at the end (`restore`).
///
/// Before each action the executor asks `bringToFront` for the app the
/// observation was of. Evie first gives up any key window of hers, since a
/// key window takes the keystrokes even when it does not activate her app
/// (the overlay is a non-activating panel that becomes key for typing); it
/// is not ordered out, because the chat and its confirmation card stay on
/// screen. Then `NSApp.yieldActivation(to:)` and `activate(from:)`, the
/// cooperative activation of macOS 14, which only an active app can grant;
/// when Evie is not active herself — the usual case, since her panel does not
/// activate her — a plain `activate()` asks instead. Either way the answer is
/// whether that process is frontmost afterwards, read from the window
/// server: an activation is a request that can be refused, and the executor
/// posts nothing to an app that is not in front.
@MainActor
final class FocusCoordinator: ComputerFocusing {
  /// How long a requested activation may take to land. An app already
  /// running comes forward in tens of milliseconds; a busy one takes longer.
  static let activationWait: Duration = .seconds(2)
  static let pollInterval: Duration = .milliseconds(25)

  private(set) var personsApp: NSRunningApplication?

  /// Keeps the frontmost app, unless it is Evie herself.
  func recordFrontmost() {
    guard let front = NSWorkspace.shared.frontmostApplication,
      front.processIdentifier != ProcessInfo.processInfo.processIdentifier
    else {
      return
    }
    personsApp = front
  }

  func bringToFront(_ app: ComputerAppIdentity) async -> Bool {
    for window in NSApp.windows where window.isKeyWindow {
      window.resignKey()
    }
    if Self.isFrontmost(app.processID) {
      return true
    }
    guard let running = NSRunningApplication(processIdentifier: app.processID),
      !running.isTerminated
    else {
      return false
    }
    if NSApp.isActive {
      NSApp.yieldActivation(to: running)
      running.activate(from: NSRunningApplication.current, options: [])
      if await Self.waitUntilFrontmost(app.processID, within: .milliseconds(600)) {
        return true
      }
    }
    running.activate(options: [])
    return await Self.waitUntilFrontmost(app.processID, within: Self.activationWait)
  }

  /// Gives the front back to the app the person was using, if it still runs.
  @discardableResult
  func restore() async -> Bool {
    guard let app = personsApp, !app.isTerminated else {
      return false
    }
    return await bringToFront(
      ComputerAppIdentity(
        bundleID: app.bundleIdentifier, name: app.localizedName ?? "",
        processID: app.processIdentifier))
  }

  static func isFrontmost(_ processID: Int32) -> Bool {
    NSWorkspace.shared.frontmostApplication?.processIdentifier == processID
  }

  private static func waitUntilFrontmost(_ processID: Int32, within limit: Duration) async -> Bool {
    let deadline = ContinuousClock.now + limit
    while ContinuousClock.now < deadline {
      if isFrontmost(processID) {
        return true
      }
      try? await Task.sleep(for: pollInterval)
    }
    return isFrontmost(processID)
  }
}
