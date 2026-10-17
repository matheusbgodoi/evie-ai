import AppKit
import Carbon
import EvieCore

/// Queries TCC without reading mail, calendar entries, pixels or audio.
/// Requests run only under the explicit --request-permissions launch.
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
    var address = AEAddressDesc()
    let data = Data(bundleID.utf8)
    let created = data.withUnsafeBytes {
      AECreateDesc(DescType(typeApplicationBundleID), $0.baseAddress, $0.count, &address)
    }
    guard created == noErr else { return OSStatus(created) }
    defer { AEDisposeDesc(&address) }
    return AEDeterminePermissionToAutomateTarget(
      &address, AEEventClass(typeWildCard), AEEventID(typeWildCard), request)
  }
}

@MainActor
struct AutomationPermissionItem: PermissionGuideItem {
  let bundleID: String
  let title: String

  func row(given record: PermissionGuideRecord) -> PermissionGuideRow {
    let status = EviePermissionsAudit.automationStatus(bundleID: bundleID, request: false)
    let closed = status == procNotFound
    let mayAsk = status == errAEEventWouldRequireUserConsent || closed
    return PermissionGuideRow(
      id: "automation-\(bundleID)", title: "Automação do \(title)",
      detail:
        "Permite consultar o \(title) quando você pede. Nenhum dado é lido ao pedir a permissão.",
      hint: closed ? "Abra o \(title) para o macOS verificar a autorização." : nil,
      mark: status == noErr ? .satisfied : mayAsk ? .pending : .refused,
      statusText: status == noErr ? "Permitido" : mayAsk ? "Ainda não pedido" : "Não permitido",
      action: status == noErr
        ? nil
        : PermissionGuideRow.Action(
          title: mayAsk ? "Pedir" : "Abrir Ajustes",
          kind: mayAsk ? .request : .openSettings(Self.settingsURL)))
  }

  func perform(_ action: PermissionGuideRow.Action) async -> EviePermission? {
    switch action.kind {
    case .request:
      _ = EviePermissionsAudit.automationStatus(bundleID: bundleID, request: true)
    case .openSettings(let url): NSWorkspace.shared.open(url)
    default: break
    }
    return nil
  }

  private static let settingsURL = URL(
    string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Automation")!
}
