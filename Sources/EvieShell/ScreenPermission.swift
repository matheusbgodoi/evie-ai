import AppKit
import EvieCore

/// The Screen Recording permission, asked for at most once.
///
/// `CGPreflightScreenCaptureAccess` answers without prompting. The prompt
/// itself (`CGRequestScreenCaptureAccess`) appears once per app; after that the
/// call returns at once and shows nothing, so whether it was already shown is
/// kept in the first-run guide's record, which the guide reads too. A grant
/// made in System Settings applies only after Evie is opened again, which is
/// why the first look after the prompt still ends in the settings card.
@MainActor
final class ScreenPermission: ScreenCapturePermission {
  private let guide: PermissionGuideViewModel

  init(guide: PermissionGuideViewModel) {
    self.guide = guide
  }

  var isGranted: Bool {
    CGPreflightScreenCaptureAccess()
  }

  /// A bare `swift build` binary never prompts: macOS would ask on behalf of
  /// the terminal that launched it, and grant the terminal.
  var wasRequested: Bool {
    !guide.isBundled || guide.wasRequested(.screenRecording)
  }

  func request() -> Bool {
    let granted = CGRequestScreenCaptureAccess()
    guide.markRequested(.screenRecording)
    return granted
  }

  /// Privacy & Security › Screen & System Audio Recording.
  func openSettings() {
    NSWorkspace.shared.open(EviePermission.screenRecording.settingsURL)
  }
}

extension ScreenPresence: ScreenSeeingIndicator {
  func showSeeing(on display: CGDirectDisplayID) async {
    await show(.seeing(displays: [display]))
  }

  /// A paused session is not a look's to end: hiding then is a stop, which
  /// would cancel the session's work. `EvieScreenLook` refuses a look while
  /// paused; this keeps the end of a glow from ever being that stop.
  func endSeeing(succeeded: Bool) {
    guard !isPaused else {
      return
    }
    hide(outcome: succeeded ? .success : .failed)
  }
}
