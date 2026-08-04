import Carbon.HIToolbox
import Foundation

final class GlobalHotKeyController: @unchecked Sendable {
  enum HotKeyID: UInt32 {
    case summon = 1
    case quickText = 2
  }

  var onSummonPressed: (@MainActor () -> Void)?
  var onSummonReleased: (@MainActor () -> Void)?
  var onQuickText: (@MainActor () -> Void)?

  private static let signature: OSType = 0x4556_4945  // "EVIE"

  private var eventHandler: EventHandlerRef?
  private var summonHotKey: EventHotKeyRef?
  private var quickTextHotKey: EventHotKeyRef?

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

    do {
      try registerHotKeys()
    } catch {
      unregisterHotKeys()
      if let eventHandler {
        RemoveEventHandler(eventHandler)
      }
      self.eventHandler = nil
      throw error
    }
  }

  deinit {
    unregisterHotKeys()
    if let eventHandler {
      RemoveEventHandler(eventHandler)
    }
  }

  private func unregisterHotKeys() {
    if let summonHotKey {
      UnregisterEventHotKey(summonHotKey)
      self.summonHotKey = nil
    }
    if let quickTextHotKey {
      UnregisterEventHotKey(quickTextHotKey)
      self.quickTextHotKey = nil
    }
  }

  private func registerHotKeys() throws {
    let summonID = EventHotKeyID(
      signature: Self.signature,
      id: HotKeyID.summon.rawValue
    )
    var status = RegisterEventHotKey(
      UInt32(kVK_Space),
      UInt32(optionKey),
      summonID,
      GetApplicationEventTarget(),
      0,
      &summonHotKey
    )
    guard status == noErr else {
      throw HotKeyError.registerSummon(status)
    }

    let quickTextID = EventHotKeyID(
      signature: Self.signature,
      id: HotKeyID.quickText.rawValue
    )
    status = RegisterEventHotKey(
      UInt32(kVK_Space),
      UInt32(optionKey | shiftKey),
      quickTextID,
      GetApplicationEventTarget(),
      0,
      &quickTextHotKey
    )
    guard status == noErr else {
      throw HotKeyError.registerQuickText(status)
    }
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
    let kind = GetEventKind(event)
    let id = HotKeyID(rawValue: identifier.id)

    DispatchQueue.main.async {
      MainActor.assumeIsolated {
        switch (id, kind) {
        case (.summon, UInt32(kEventHotKeyPressed)):
          controller.onSummonPressed?()
        case (.summon, UInt32(kEventHotKeyReleased)):
          controller.onSummonReleased?()
        case (.quickText, UInt32(kEventHotKeyPressed)):
          controller.onQuickText?()
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
    case registerSummon(OSStatus)
    case registerQuickText(OSStatus)

    var errorDescription: String? {
      switch self {
      case .installHandler(let status):
        "Não foi possível instalar o handler de atalhos (\(status))."
      case .registerSummon(let status):
        "Não foi possível registrar Option+Space (\(status))."
      case .registerQuickText(let status):
        "Não foi possível registrar Option+Shift+Space (\(status))."
      }
    }
  }
}
