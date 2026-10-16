import Carbon.HIToolbox
import Foundation

/// Plain Esc as a global stop key, registered only while an agent session is
/// on screen.
///
/// A global hot key takes the key away from every other app for as long as it
/// is registered, and Esc is the key people press most to back out of
/// things. So it is armed when the session starts and released the moment the
/// indicator leaves — never held while idle.
///
/// Its own Carbon handler and signature, apart from `GlobalHotKeyController`:
/// that controller answers only to its own signature and passes everything
/// else on, so the two never see each other's keys.
@MainActor
final class PresenceEscapeKey {
  var onPress: () -> Void = {}
  private(set) var isArmed = false
  private var reference: EventHotKeyRef?
  private var handler: EventHandlerRef?

  private static let signature: OSType = 0x4556_5053  // "EVPS"

  /// Registers Esc. Returns false when the system refuses it — another app
  /// already holds a global Esc — in which case the pill does not show the
  /// keycap, and Parar remains.
  @discardableResult
  func arm() -> Bool {
    guard !isArmed else {
      return true
    }
    if handler == nil {
      var type = EventTypeSpec(
        eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyPressed))
      let status = InstallEventHandler(
        GetApplicationEventTarget(), Self.callback, 1, &type,
        Unmanaged.passUnretained(self).toOpaque(), &handler)
      guard status == noErr else {
        return false
      }
    }
    let status = RegisterEventHotKey(
      UInt32(kVK_Escape), 0, EventHotKeyID(signature: Self.signature, id: 1),
      GetApplicationEventTarget(), 0, &reference)
    isArmed = status == noErr && reference != nil
    return isArmed
  }

  func disarm() {
    if let reference {
      UnregisterEventHotKey(reference)
    }
    reference = nil
    isArmed = false
  }

  isolated deinit {
    disarm()
    if let handler {
      RemoveEventHandler(handler)
    }
  }

  private static let callback: EventHandlerUPP = { _, event, userData in
    guard let event, let userData else {
      return OSStatus(eventNotHandledErr)
    }
    var identifier = EventHotKeyID()
    let status = GetEventParameter(
      event, EventParamName(kEventParamDirectObject), EventParamType(typeEventHotKeyID), nil,
      MemoryLayout<EventHotKeyID>.size, nil, &identifier)
    guard status == noErr, identifier.signature == PresenceEscapeKey.signature else {
      return OSStatus(eventNotHandledErr)
    }
    let key = Unmanaged<PresenceEscapeKey>.fromOpaque(userData).takeUnretainedValue()
    DispatchQueue.main.async {
      MainActor.assumeIsolated {
        if key.isArmed {
          key.onPress()
        }
      }
    }
    return noErr
  }
}
