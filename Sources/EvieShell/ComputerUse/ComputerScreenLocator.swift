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

  /// Evie's windows a click can land on: the overlay, the pill, Settings.
  ///
  /// Not the presence panels: they cover each display edge to edge and
  /// ignore the mouse, so a click passes through them to the app below.
  /// Listing them (as the window server's list did until S5c's live check
  /// on 2026-10-16) put every point of the screen inside "a window of
  /// Evie's" and refused every click.
  func evieWindowFrames() -> [CGRect] {
    guard let layout = ScreenCaptureService.currentLayout() else {
      return []
    }
    return NSApp.windows
      .filter { $0.isVisible && !$0.ignoresMouseEvents }
      .map { layout.globalCGRect(fromAppKit: $0.frame) }
  }

  /// The window server's front-to-back list, Evie's own windows (the
  /// click-through presence panels among them) and invisible ones passed
  /// over: the first window holding the point is the one a click there
  /// reaches.
  func windowOwner(at point: CGPoint) -> Int32? {
    let own = ProcessInfo.processInfo.processIdentifier
    return Self.onScreenWindows().first { window in
      window.owner != own && window.alpha > 0 && window.bounds.contains(point)
    }?.owner
  }

  /// The same list, every visible window with the app that owns it: the
  /// policy judges a point by its window's owner and finds an open
  /// launcher's panel by its owner. A process with no running application
  /// (the window server's menu bar) keeps the owner name the list gives.
  func windows() -> [ComputerWindowSummary] {
    let own = ProcessInfo.processInfo.processIdentifier
    var owners: [pid_t: ComputerAppIdentity] = [:]
    func owner(of window: WindowInfo) -> ComputerAppIdentity {
      if let known = owners[window.owner] {
        return known
      }
      let app = NSRunningApplication(processIdentifier: window.owner)
      let identity = ComputerAppIdentity(
        bundleID: app?.bundleIdentifier,
        name: app?.localizedName ?? window.ownerName ?? "processo \(window.owner)",
        processID: window.owner
      )
      owners[window.owner] = identity
      return identity
    }
    return Self.onScreenWindows().compactMap { window in
      guard window.owner != own, window.alpha > 0 else {
        return nil
      }
      return ComputerWindowSummary(owner: owner(of: window), frame: window.bounds, layer: window.layer)
    }
  }

  func secureInputEnabled() -> Bool {
    IsSecureEventInputEnabled()
  }

  private struct WindowInfo {
    let owner: pid_t
    let ownerName: String?
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
        ownerName: window[kCGWindowOwnerName] as? String,
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
