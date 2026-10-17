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
///
/// A Carbon hot key cannot tell who pressed it: the event it delivers carries
/// no `eventSourceUserData`, so an Esc Evie posts herself (tagged
/// `ScreenPresence.syntheticEventTag`) would stop her own session. Instead,
/// the key is released for as long as Evie is posting input — see
/// `suspend()` — and the synthetic Esc reaches the app it was meant for.
@MainActor
final class PresenceEscapeKey {
  var onPress: () -> Void = {}
  /// Held for the session: registered, and shown as the pill's keycap. Stays
  /// true while suspended, since the key comes back as soon as the posting
  /// ends.
  private(set) var isArmed = false
  /// How many postings of synthetic input are under way. The key is
  /// registered only at zero.
  private var suspensions = 0
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
    guard suspensions == 0 else {
      // Registered when the posting ends; until then the session counts it
      // as held, as it will be.
      isArmed = true
      return true
    }
    isArmed = register()
    return isArmed
  }

  func disarm() {
    unregister()
    isArmed = false
  }

  /// Releases the key while Evie posts input, so her own Esc is not taken
  /// for the user's. Every call is matched by one `endSuspension()`; nested
  /// postings keep it released until the last one ends.
  func suspend() {
    suspensions += 1
    unregister()
  }

  /// Takes the key back for the session, if the session still wants it and
  /// no other posting is under way. If the system refuses it now — another
  /// app took Esc in the meantime — the session goes on without it, and Parar
  /// remains.
  func endSuspension() {
    guard suspensions > 0 else {
      return
    }
    suspensions -= 1
    if suspensions == 0, isArmed {
      isArmed = register()
    }
  }

  private func register() -> Bool {
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
    return status == noErr && reference != nil
  }

  private func unregister() {
    if let reference {
      UnregisterEventHotKey(reference)
    }
    reference = nil
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
        // A press that was already queued when a posting began is dropped
        // with the rest: it cannot be told apart from Evie's own.
        if key.isArmed, key.suspensions == 0 {
          key.onPress()
        }
      }
    }
    return noErr
  }
}
