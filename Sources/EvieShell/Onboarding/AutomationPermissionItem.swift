import AppKit
import Carbon
import EvieCore

/// The target must be running before macOS can determine Automation consent.
/// Rendering reads cached state; a permission dialog never blocks the UI actor.
@MainActor
final class AutomationPermissionItem: PermissionGuideItem {
  private let bundleID: String
  private let title: String
  private let probe: @Sendable (Bool) async -> OSStatus
  private let openTarget: @MainActor () async throws -> Void
  private let openSettings: @MainActor (URL) -> Bool
  private var status: OSStatus?
  private var failureHint: String?
  private var requesting = false
  private var refreshTask: Task<Void, Never>?
  private var generation: UInt64 = 0
  private var onChange: (@MainActor () -> Void)?

  init(
    bundleID: String, title: String,
    probe: (@Sendable (Bool) async -> OSStatus)? = nil,
    openTarget: (@MainActor () async throws -> Void)? = nil,
    openSettings: (@MainActor (URL) -> Bool)? = nil
  ) {
    self.bundleID = bundleID
    self.title = title
    let nativeProbe = AutomationPermissionProbe(bundleID: bundleID)
    self.probe = probe ?? { await nativeProbe.check(request: $0) }
    self.openTarget = openTarget ?? { try await Self.openApplication(bundleID: bundleID) }
    self.openSettings = openSettings ?? { NSWorkspace.shared.open($0) }
  }

  func observeRowChanges(_ onChange: @escaping @MainActor () -> Void) {
    self.onChange = onChange
  }

  func refreshStatus() {
    guard refreshTask == nil, !requesting else { return }
    let ticket = generation
    refreshTask = Task { [weak self] in
      guard let self else { return }
      let result = await probe(false)
      guard !Task.isCancelled, generation == ticket else { return }
      status = result
      if result == noErr { failureHint = nil }
      refreshTask = nil
      onChange?()
    }
  }

  func prepareForRequest() async {
    refreshStatus()
    await refreshTask?.value
  }

  func row(given record: PermissionGuideRecord) -> PermissionGuideRow {
    let mark: PermissionGuideRow.Mark
    let text: String
    let hint: String?
    let action: PermissionGuideRow.Action?
    if requesting {
      (mark, text, hint, action) = (.pending, "Solicitando…", nil, nil)
    } else if let failureHint {
      (mark, text, hint, action) = (
        .pending, "Não concluído", failureHint,
        .init(
          title: "Tentar novamente",
          kind: status == OSStatus(errAEEventNotPermitted)
            ? .openSettings(Self.settingsURL) : .request)
      )
    } else {
      switch status {
      case .some(let code) where code == OSStatus(noErr):
        (mark, text, hint, action) = (.satisfied, "Permitido", nil, nil)
      case .some(let code) where code == OSStatus(procNotFound):
        (mark, text, hint, action) = (
          .pending, "Aplicativo fechado",
          "Ao permitir, a Evie abre o \(title) e verifica a autorização do macOS.",
          .init(title: "Permitir", kind: .request)
        )
      case .some(let code) where code == OSStatus(errAEEventWouldRequireUserConsent):
        (mark, text, hint, action) = (
          .pending, "Ainda não pedido", nil, .init(title: "Permitir", kind: .request)
        )
      case .some(let code) where code == OSStatus(errAEEventNotPermitted):
        (mark, text, hint, action) = (
          .refused, "Não permitido",
          "Autorize a Evie em Privacidade e Segurança › Automação.",
          .init(title: "Abrir Ajustes", kind: .openSettings(Self.settingsURL))
        )
      case .some(let code):
        (mark, text, hint, action) = (
          .pending, "Não verificado", "O macOS retornou o código \(code).",
          .init(title: "Verificar novamente", kind: .request)
        )
      case nil:
        (mark, text, hint, action) = (.pending, "Verificando…", nil, nil)
      }
    }
    return PermissionGuideRow(
      id: "automation-\(bundleID)", title: "Automação do \(title)",
      detail:
        "Permite consultar o \(title) quando você pede. Nenhum dado é lido ao pedir a permissão.",
      hint: hint, mark: mark, statusText: text, action: action)
  }

  func perform(_ action: PermissionGuideRow.Action) async -> EviePermission? {
    switch action.kind {
    case .request:
      guard !requesting else { return nil }
      generation &+= 1
      refreshTask?.cancel()
      refreshTask = nil
      requesting = true
      failureHint = nil
      onChange?()
      defer {
        requesting = false
        onChange?()
      }
      do {
        try await openTarget()
        status = await probe(true)
      } catch {
        failureHint = "Não consegui abrir o \(title): \(error.localizedDescription)"
      }
    case .openSettings(let url):
      if openSettings(url) {
        failureHint = nil
      } else {
        failureHint = "Não consegui abrir os Ajustes do Sistema. Tente novamente."
      }
      onChange?()
    default: break
    }
    return nil
  }

  private static func openApplication(bundleID: String) async throws {
    if !NSRunningApplication.runningApplications(withBundleIdentifier: bundleID).isEmpty { return }
    guard let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleID) else {
      throw CocoaError(.fileNoSuchFile)
    }
    let configuration = NSWorkspace.OpenConfiguration()
    configuration.activates = false
    configuration.hides = true
    _ = try await NSWorkspace.shared.openApplication(at: url, configuration: configuration)
  }

  private static let settingsURL = URL(
    string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Automation")!
}

/// Dedicated queue: neither rendering nor a waiting TCC dialog occupies the
/// MainActor or Swift's cooperative executor. It never reads application data.
struct AutomationPermissionProbe: Sendable {
  let bundleID: String
  private let queue = DispatchQueue(label: "app.evie.automation-permission", qos: .utility)

  func check(request: Bool) async -> OSStatus {
    await withCheckedContinuation { continuation in
      queue.async {
        continuation.resume(returning: Self.status(bundleID: bundleID, request: request))
      }
    }
  }

  static func status(bundleID: String, request: Bool) -> OSStatus {
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
