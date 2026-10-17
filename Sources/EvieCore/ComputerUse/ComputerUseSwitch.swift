import Foundation

/// Whether agent mode is available at all: the Settings switch, unless the
/// environment forces it off.
///
/// `EVIE_COMPUTER_USE=0` (or `false`, `off`) is the override for a launch
/// that must not act on the Mac whatever the switch says — a test run, a
/// demo on someone else's screen. Nothing in the environment turns it on:
/// a switch the person turned off stays off.
public enum ComputerUseSwitch {
  public static let environmentKey = "EVIE_COMPUTER_USE"

  public static func isEnabled(preferences: EviePreferences, environment: [String: String])
    -> Bool
  {
    preferences.computerUseEnabled && !forcedOff(environment: environment)
  }

  public static func forcedOff(environment: [String: String]) -> Bool {
    guard let value = environment[environmentKey] else {
      return false
    }
    let folded = value.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
    return ["0", "false", "off", "no", "nao", "não"].contains(folded)
  }

  /// Why the switch is off, for the session card and Settings.
  public static func unavailableReason(
    preferences: EviePreferences,
    environment: [String: String]
  ) -> String? {
    if forcedOff(environment: environment) {
      return "O modo agente está desligado nesta execução (EVIE_COMPUTER_USE=0)."
    }
    if !preferences.computerUseEnabled {
      return "O modo agente está desligado em \(EvieSettingsSection.screenAndAgent.path)."
    }
    return nil
  }
}
