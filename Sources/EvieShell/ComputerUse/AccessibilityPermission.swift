import AppKit
import ApplicationServices
import EvieCore

/// The Accessibility permission, which reading other apps' elements and,
/// from S5c, acting in them need.
///
/// Nothing here runs at launch. `isTrusted` never prompts; the macOS prompt
/// (`AXIsProcessTrustedWithOptions` with the prompt option) is shown only by
/// `request()`, which a person's start of a computer-use session calls
/// (S5d) — never a diagnostic, never a timer. The prompt only opens System
/// Settings; the switch there is the grant, and it takes effect in this
/// process without a relaunch, which is why `waitUntilTrusted` polls for it
/// (`AccessibilityTrust`).
@MainActor
final class AccessibilityPermission {
  private let guide: PermissionGuideViewModel

  init(guide: PermissionGuideViewModel) {
    self.guide = guide
  }

  var isTrusted: Bool {
    AXIsProcessTrusted()
  }

  /// A bare `swift build` binary never prompts: macOS would ask on behalf of
  /// the terminal that launched it, and grant the terminal.
  var wasRequested: Bool {
    !guide.isBundled || guide.wasRequested(.accessibility)
  }

  /// Shows the macOS prompt once and records that it was shown.
  ///
  /// The key's string value rather than `kAXTrustedCheckOptionPrompt`: the
  /// constant is imported as a mutable global, which Swift 6 reports as
  /// unsafe shared state.
  func request() -> Bool {
    let trusted = AXIsProcessTrustedWithOptions(
      ["AXTrustedCheckOptionPrompt": true] as CFDictionary)
    guide.markRequested(.accessibility)
    return trusted
  }

  /// Waits for the switch in System Settings, asking every 0.5 s.
  func waitUntilTrusted(timeout: Duration) async -> Bool {
    await AccessibilityTrust.waitUntilTrusted(timeout: timeout, isTrusted: { AXIsProcessTrusted() })
  }

  /// Privacy & Security › Accessibility.
  func openSettings() {
    NSWorkspace.shared.open(EviePermission.accessibility.settingsURL)
  }
}
