import AppKit
import Carbon.HIToolbox
import EvieCore

/// Where the front app and Evie's own windows are, as the window server
/// reports them now. Read for every observation: windows move between steps.
@MainActor
final class ComputerScreenLocator: ComputerScreenLocating {
  func frontApp() -> ComputerAppIdentity? {
    guard let app = NSWorkspace.shared.frontmostApplication else {
      return nil
    }
    return ComputerAppIdentity(
      bundleID: app.bundleIdentifier,
      name: app.localizedName ?? app.bundleIdentifier ?? "app \(app.processIdentifier)",
      processID: app.processIdentifier
    )
  }

  func displayUnderPointer() -> CGDirectDisplayID? {
    guard let pointer = CGEvent(source: nil)?.location else {
      return nil
    }
    return display(containing: pointer)
  }

  func displayFrame(_ display: CGDirectDisplayID) -> CGRect? {
    let bounds = CGDisplayBounds(display)
    return bounds.isEmpty ? nil : bounds
  }

  func display(containing point: CGPoint) -> CGDirectDisplayID? {
    ScreenCaptureService.currentLayout()?.display(containingGlobalCG: point)?.id
  }

  /// The first normal (layer 0), visible window of the process in the window
  /// server's front-to-back order.
  func frontWindowFrame(ofProcess processID: Int32) -> CGRect? {
    Self.onScreenWindows().first { window in
      window.owner == processID && window.layer == 0 && window.alpha > 0
    }?.bounds
  }

  func evieWindowFrames() -> [CGRect] {
    let own = ProcessInfo.processInfo.processIdentifier
    return Self.onScreenWindows().filter { $0.owner == own }.map(\.bounds)
  }

  func secureInputEnabled() -> Bool {
    IsSecureEventInputEnabled()
  }

  private struct WindowInfo {
    let owner: pid_t
    let layer: Int
    let alpha: Double
    let bounds: CGRect
  }

  private static func onScreenWindows() -> [WindowInfo] {
    guard
      let windows = CGWindowListCopyWindowInfo(
        [.optionOnScreenOnly, .excludeDesktopElements],
        kCGNullWindowID
      ) as? [[CFString: Any]]
    else {
      return []
    }
    return windows.compactMap { window in
      guard let owner = window[kCGWindowOwnerPID] as? pid_t,
        let boundsDictionary = window[kCGWindowBounds] as? NSDictionary,
        let bounds = CGRect(dictionaryRepresentation: boundsDictionary as CFDictionary)
      else {
        return nil
      }
      return WindowInfo(
        owner: owner,
        layer: window[kCGWindowLayer] as? Int ?? 0,
        alpha: window[kCGWindowAlpha] as? Double ?? 1,
        bounds: bounds
      )
    }
  }
}

extension ScreenPresence: ComputerObservingIndicator {
  func showObserving(on display: CGDirectDisplayID, step: Int) async {
    await show(.observing(displays: [display], step: step))
  }

  /// A paused session is not the loop's to end quietly: hiding then is a
  /// stop, which cancels the session's work — the same guard as `endSeeing`.
  func endObserving(succeeded: Bool) {
    guard !isPaused else {
      return
    }
    hide(outcome: succeeded ? .success : .failed)
  }
}
