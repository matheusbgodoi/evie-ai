import Foundation

/// Waiting for the Accessibility switch.
///
/// macOS posts no documented notification when a person turns Evie on in
/// System Settings › Privacy & Security › Accessibility, and
/// `AXIsProcessTrusted()` starts answering true in the same process once they
/// do, so the only way to notice is to ask again. This asks every `interval`
/// until `timeout`, and gives up early if the waiting task is cancelled — the
/// person closed the card or stopped the session.
public enum AccessibilityTrust {
  public static let pollInterval: Duration = .milliseconds(500)

  /// Runs on the caller's actor, so the checks need not be `Sendable`.
  public static func waitUntilTrusted(
    isolation: isolated (any Actor)? = #isolation,
    timeout: Duration,
    interval: Duration = pollInterval,
    isTrusted: () -> Bool,
    sleep: (Duration) async throws -> Void = { try await Task.sleep(for: $0) }
  ) async -> Bool {
    var waited: Duration = .zero
    while !isTrusted() {
      guard waited < timeout else {
        return false
      }
      do {
        try await sleep(interval)
      } catch {
        return false
      }
      waited += interval
    }
    return true
  }
}
