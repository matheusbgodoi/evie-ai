import Carbon
import EvieCore

/// Queries TCC without reading mail, calendar entries, pixels or audio.
/// Interactive requests are handled by AutomationPermissionItem.
@MainActor
enum EviePermissionsAudit {
  private static let automationTargets = ["com.apple.mail", "com.apple.iCal"]

  static func report() -> [String] {
    let permissions = EviePermission.allCases.map {
      "\($0.rawValue): \(String(describing: SystemPermissionItem.status(of: $0)))"
    }
    return permissions
      + automationTargets.map {
        "automation \($0): OSStatus \(automationStatus(bundleID: $0, request: false))"
      }
  }

  static func automationStatus(bundleID: String, request: Bool) -> OSStatus {
    AutomationPermissionProbe.status(bundleID: bundleID, request: request)
  }
}
