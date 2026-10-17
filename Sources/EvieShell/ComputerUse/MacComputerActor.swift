import AppKit
import EvieCore

/// This Mac as computer use drives it: the observer and the executor wired
/// to the real screen, input, Accessibility, pasteboard and presence.
///
/// Every rule is EvieCore's (`ComputerObserver`, `ComputerExecutor`,
/// `ClipboardSession`, the broker's policy); the parts here only reach the
/// system. There is no actor without a broker: `make` takes the broker whose
/// commits it will check, and returns nothing while agent mode is switched
/// off ("Deixar a Evie controlar o Mac", or `EVIE_COMPUTER_USE=0`).
@MainActor
enum MacComputerActor {
  static func make(
    broker: EvieAgentModeBroker,
    presence: ScreenPresence,
    focus: FocusCoordinator,
    screenPermission: any ScreenCapturePermission,
    preferences: EviePreferences,
    environment: [String: String] = ProcessInfo.processInfo.environment
  ) -> ComputerExecutor? {
    guard ComputerUseSwitch.isEnabled(preferences: preferences, environment: environment) else {
      return nil
    }
    let locator = ComputerScreenLocator()
    let observer = ComputerObserver(
      capturer: ScreenCaptureService(),
      locator: locator,
      accessibility: AccessibilitySnapshotter(),
      indicator: presence,
      screenPermission: screenPermission
    )
    return ComputerExecutor(
      observer: observer,
      broker: broker,
      mac: ComputerExecutor.Mac(
        input: SyntheticInput(),
        accessibility: AccessibilityActions(),
        focus: focus,
        launcher: AppLauncher(),
        indicator: presence,
        locator: locator,
        clipboard: ClipboardSession(pasteboard: SystemPasteboard())
      )
    )
  }

  /// The policy over the apps installed now, for a session's broker.
  static func policy() -> ComputerActionPolicy {
    ComputerActionPolicy(resolver: InstalledApps.catalog())
  }
}

/// The presence as the executor uses it: global points in, display-local
/// top-left points out, as the panels draw them.
extension ScreenPresence: ComputerActingIndicator {
  func showActing(on display: CGDirectDisplayID) async {
    await show(.acting(display))
  }

  func lookAt(_ rect: CGRect, on display: CGDirectDisplayID) {
    lookAt(ScreenRect(displayID: display, rect: Self.local(rect, on: display)))
  }

  func willClick(at point: CGPoint, on display: CGDirectDisplayID, label: String?) async -> Bool {
    await willClick(Self.local(point, on: display), label: label) == .proceed
  }

  func didClick(at point: CGPoint, on display: CGDirectDisplayID) {
    didClick(at: Self.local(point, on: display))
  }

  func typing(field: CGRect?, on display: CGDirectDisplayID, app: String) {
    typing(
      field: field.map { ScreenRect(displayID: display, rect: Self.local($0, on: display)) },
      app: app)
  }

  private static func local(_ point: CGPoint, on display: CGDirectDisplayID) -> ScreenPoint {
    let origin = CGDisplayBounds(display).origin
    return ScreenPoint(displayID: display, x: point.x - origin.x, y: point.y - origin.y)
  }

  private static func local(_ rect: CGRect, on display: CGDirectDisplayID) -> CGRect {
    let origin = CGDisplayBounds(display).origin
    return rect.offsetBy(dx: -origin.x, dy: -origin.y)
  }
}
