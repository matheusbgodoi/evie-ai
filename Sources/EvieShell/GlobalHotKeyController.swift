import Carbon.HIToolbox
import EvieCore
import Foundation

/// Registers Evie's global shortcuts from the saved preferences.
///
/// Registration is per action and failure is partial: the system refuses a
/// combination that another application already owns, and losing one shortcut
/// must not cost the user the other seven. The failures are returned so the
/// settings window can name them.
final class GlobalHotKeyController: @unchecked Sendable {
  enum Phase {
    case pressed
    case released
  }

  var onAction: (@MainActor (EvieShortcutAction, Phase) -> Void)?

  private static let signature: OSType = 0x4556_4945  // "EVIE"

  private var eventHandler: EventHandlerRef?
  private var registrations: [UInt32: (action: EvieShortcutAction, reference: EventHotKeyRef)] = [:]

  init() throws {
    var eventTypes = [
      EventTypeSpec(
        eventClass: OSType(kEventClassKeyboard),
        eventKind: UInt32(kEventHotKeyPressed)
      ),
      EventTypeSpec(
        eventClass: OSType(kEventClassKeyboard),
        eventKind: UInt32(kEventHotKeyReleased)
      ),
    ]

    let status = InstallEventHandler(
      GetApplicationEventTarget(),
      Self.eventCallback,
      eventTypes.count,
      &eventTypes,
      Unmanaged.passUnretained(self).toOpaque(),
      &eventHandler
    )
    guard status == noErr else {
      throw HotKeyError.installHandler(status)
    }
  }

  deinit {
    for registration in registrations.values {
      UnregisterEventHotKey(registration.reference)
    }
    if let eventHandler {
      RemoveEventHandler(eventHandler)
    }
  }

  /// Replaces every registration with the current preferences.
  ///
  /// Returns the actions the system refused, so the interface can say which
  /// shortcut is unavailable instead of silently doing nothing when it is
  /// pressed.
  @discardableResult
  func apply(_ preferences: EvieShortcutPreferences) -> [EvieShortcutAction: OSStatus] {
    for registration in registrations.values {
      UnregisterEventHotKey(registration.reference)
    }
    registrations.removeAll()

    var failures: [EvieShortcutAction: OSStatus] = [:]
    for action in EvieShortcutAction.allCases {
      guard let shortcut = preferences.shortcut(for: action) else {
        continue
      }
      let identifier = Self.identifier(for: action)
      var reference: EventHotKeyRef?
      let status = RegisterEventHotKey(
        UInt32(shortcut.keyCode),
        shortcut.modifiers.carbonFlags,
        EventHotKeyID(signature: Self.signature, id: identifier),
        GetApplicationEventTarget(),
        0,
        &reference
      )
      if status == noErr, let reference {
        registrations[identifier] = (action, reference)
      } else {
        failures[action] = status
      }
    }
    return failures
  }

  private static func identifier(for action: EvieShortcutAction) -> UInt32 {
    UInt32((EvieShortcutAction.allCases.firstIndex(of: action) ?? 0) + 1)
  }

  private static let eventCallback: EventHandlerUPP = { _, event, userData in
    guard let event, let userData else {
      return OSStatus(eventNotHandledErr)
    }

    var identifier = EventHotKeyID()
    let status = GetEventParameter(
      event,
      EventParamName(kEventParamDirectObject),
      EventParamType(typeEventHotKeyID),
      nil,
      MemoryLayout<EventHotKeyID>.size,
      nil,
      &identifier
    )
    guard
      status == noErr,
      identifier.signature == GlobalHotKeyController.signature
    else {
      return OSStatus(eventNotHandledErr)
    }

    let controller = Unmanaged<GlobalHotKeyController>
      .fromOpaque(userData)
      .takeUnretainedValue()
    guard let action = controller.registrations[identifier.id]?.action else {
      return OSStatus(eventNotHandledErr)
    }
    let kind = GetEventKind(event)

    DispatchQueue.main.async {
      MainActor.assumeIsolated {
        switch kind {
        case UInt32(kEventHotKeyPressed):
          controller.onAction?(action, .pressed)
        case UInt32(kEventHotKeyReleased):
          // Only hold-to-activate actions care, but delivering it for every
          // action keeps the contract simple and the handler decides.
          controller.onAction?(action, .released)
        default:
          break
        }
      }
    }

    return noErr
  }
}

extension GlobalHotKeyController {
  enum HotKeyError: LocalizedError {
    case installHandler(OSStatus)

    var errorDescription: String? {
      switch self {
      case .installHandler(let status):
        "Não foi possível instalar o handler de atalhos (\(status))."
      }
    }
  }

  /// A sentence naming the shortcuts the system refused, or `nil` when every
  /// registration succeeded.
  static func failureMessage(
    for failures: [EvieShortcutAction: OSStatus],
    preferences: EvieShortcutPreferences
  ) -> String? {
    guard !failures.isEmpty else {
      return nil
    }
    let described =
      EvieShortcutAction.allCases
      .filter { failures[$0] != nil }
      .map { action in
        let combination = preferences.shortcut(for: action)?.displayString ?? "—"
        return "\(action.title) (\(combination))"
      }
    let subject = described.count == 1 ? "Um atalho já está" : "Alguns atalhos já estão"
    return
      "\(subject) em uso por outro app: \(described.joined(separator: ", ")). "
      + "Escolha outra combinação em Configurações › Atalhos."
  }
}
