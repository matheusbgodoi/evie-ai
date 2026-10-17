import AppKit
import Carbon.HIToolbox
import CoreGraphics
import EvieCore

/// Mouse, keyboard and scroll events Evie posts during an agent session.
///
/// Every event carries `ScreenPresence.syntheticEventTag` (0xE71E) in
/// `eventSourceUserData`, set on the source and again on the event, so the
/// takeover monitor can tell Evie's input from the person's and the pill's
/// buttons refuse her clicks. Events go to `.cghidEventTap`, where real input
/// enters, so an app handles them as it would a person's.
///
/// Posting needs the Accessibility grant ("controlar o computador"):
/// `mayPost` asks without prompting; `requestAccess` shows the prompt and is
/// called only from the person's start of a session (S5d), never here.
///
/// The executor (`ComputerExecutor`) calls these only inside
/// `ScreenPresence.postingSyntheticInput`, which releases the plain-Esc stop
/// key while Evie posts.
@MainActor
final class SyntheticInput: SyntheticInputPosting {
  /// Steps of a drag between press and release, and the pause between them:
  /// an app that tracks the mouse needs to see it move to take a drag for one.
  static let dragSteps = 12
  static let dragStepPause: Duration = .milliseconds(10)

  private let source: CGEventSource?

  init() {
    source = CGEventSource(stateID: .hidSystemState)
    source?.userData = ScreenPresence.syntheticEventTag
  }

  var mayPost: Bool {
    CGPreflightPostEventAccess()
  }

  /// The macOS prompt. Only a person's start of a session asks.
  func requestAccess() -> Bool {
    CGRequestPostEventAccess()
  }

  func move(to point: CGPoint) {
    postMouse(.mouseMoved, at: point, button: .left)
  }

  func click(at point: CGPoint, button: MouseButton, count: Int) {
    move(to: point)
    let (down, up, cgButton) = Self.eventTypes(for: button)
    // A double click is press-release twice, the second pair saying it is
    // the second click; apps count clicks by this state, not by timing.
    for clickState in 1...max(1, min(count, 3)) {
      postMouse(down, at: point, button: cgButton, clickState: clickState)
      postMouse(up, at: point, button: cgButton, clickState: clickState)
    }
  }

  func drag(
    from start: CGPoint, to end: CGPoint,
    checking: @MainActor (CGPoint) async throws -> Void
  ) async throws {
    try await checking(start)
    move(to: start)
    postMouse(.leftMouseDown, at: start, button: .left)
    var last = start
    do {
      for step in 1...Self.dragSteps {
        let fraction = CGFloat(step) / CGFloat(Self.dragSteps)
        let point = CGPoint(
          x: start.x + (end.x - start.x) * fraction, y: start.y + (end.y - start.y) * fraction)
        try await Task.sleep(for: Self.dragStepPause)
        try await checking(point)
        postMouse(.leftMouseDragged, at: point, button: .left)
        last = point
      }
    } catch {
      // Release the already-held button without moving further. Cancellation
      // must never leave the user's mouse down or continue to the destination.
      postMouse(.leftMouseUp, at: last, button: .left)
      throw error
    }
    postMouse(.leftMouseUp, at: end, button: .left)
  }

  /// A wheel event in lines at `point`. The wheel counts positive upward,
  /// so moving down the page is a negative count. [VERIFY] with natural
  /// scrolling on and off: a posted event is expected not to be inverted.
  func scroll(at point: CGPoint, dx: Int, dy: Int) {
    move(to: point)
    guard
      let event = CGEvent(
        scrollWheelEvent2Source: source, units: .line, wheelCount: 2,
        wheel1: Int32(clamping: -dy), wheel2: Int32(clamping: -dx), wheel3: 0)
    else {
      return
    }
    event.location = point
    post(event)
  }

  func press(_ chord: KeyChord) {
    guard let key = KeyboardLayoutKeys.key(for: chord.key) else {
      return
    }
    var flags = Self.flags(for: chord.modifiers)
    if key.shift {
      flags.insert(.maskShift)
    }
    for isDown in [true, false] {
      guard let event = CGEvent(keyboardEventSource: source, virtualKey: key.code, keyDown: isDown)
      else {
        continue
      }
      event.flags = flags
      post(event)
    }
  }

  /// One unicode key event carrying `chunk`, with no modifier held: what
  /// arrives is the text, whatever key the event names.
  func type(_ chunk: String) {
    var units = Array(chunk.utf16)
    for isDown in [true, false] {
      guard let event = CGEvent(keyboardEventSource: source, virtualKey: 0, keyDown: isDown) else {
        continue
      }
      event.flags = []
      event.keyboardSetUnicodeString(stringLength: units.count, unicodeString: &units)
      post(event)
    }
  }

  // MARK: - Posting

  private func postMouse(
    _ type: CGEventType,
    at point: CGPoint,
    button: CGMouseButton,
    clickState: Int = 1
  ) {
    guard
      let event = CGEvent(
        mouseEventSource: source, mouseType: type, mouseCursorPosition: point, mouseButton: button)
    else {
      return
    }
    event.flags = []
    event.setIntegerValueField(.mouseEventClickState, value: Int64(clickState))
    post(event)
  }

  private func post(_ event: CGEvent) {
    event.setIntegerValueField(.eventSourceUserData, value: ScreenPresence.syntheticEventTag)
    event.post(tap: .cghidEventTap)
  }

  private static func eventTypes(
    for button: MouseButton
  ) -> (down: CGEventType, up: CGEventType, button: CGMouseButton) {
    switch button {
    case .left: (.leftMouseDown, .leftMouseUp, .left)
    case .right: (.rightMouseDown, .rightMouseUp, .right)
    case .middle: (.otherMouseDown, .otherMouseUp, .center)
    }
  }

  private static func flags(for modifiers: Set<KeyModifier>) -> CGEventFlags {
    var flags: CGEventFlags = []
    for modifier in modifiers {
      switch modifier {
      case .command: flags.insert(.maskCommand)
      case .shift: flags.insert(.maskShift)
      case .option: flags.insert(.maskAlternate)
      case .control: flags.insert(.maskControl)
      }
    }
    return flags
  }
}

/// Which key types a character on the keyboard layout in use.
///
/// A chord names a character ("cmd+/"), and where that character sits moves
/// between layouts, so the layout is asked first (`UCKeyTranslate` over each
/// key, unshifted then shifted); `ComputerKeyCodes`' ANSI table is the
/// fallback, and named keys (Return, the arrows) never move.
enum KeyboardLayoutKeys {
  static func key(for name: String) -> ComputerKeyCodes.Key? {
    if name.count == 1, let key = currentLayout()[name] {
      return key
    }
    return ComputerKeyCodes.key(for: name)
  }

  /// Every character the current layout types without a dead key, lowercased.
  private static func currentLayout() -> [String: ComputerKeyCodes.Key] {
    guard let source = TISCopyCurrentKeyboardLayoutInputSource()?.takeRetainedValue(),
      let raw = TISGetInputSourceProperty(source, kTISPropertyUnicodeKeyLayoutData)
    else {
      return [:]
    }
    let data = Unmanaged<CFData>.fromOpaque(raw).takeUnretainedValue() as Data
    var keys: [String: ComputerKeyCodes.Key] = [:]
    data.withUnsafeBytes { buffer in
      guard let layout = buffer.baseAddress?.assumingMemoryBound(to: UCKeyboardLayout.self) else {
        return
      }
      for shift in [false, true] {
        let modifiers: UInt32 = shift ? UInt32(shiftKey >> 8) & 0xFF : 0
        for code in UInt16(0)..<128 {
          var deadKeys: UInt32 = 0
          var length = 0
          var characters = [UniChar](repeating: 0, count: 4)
          let status = UCKeyTranslate(
            layout, code, UInt16(kUCKeyActionDown), modifiers, UInt32(LMGetKbdType()),
            OptionBits(kUCKeyTranslateNoDeadKeysBit), &deadKeys, characters.count, &length,
            &characters)
          guard status == noErr, length == 1 else {
            continue
          }
          let character = String(utf16CodeUnits: characters, count: length).lowercased()
          if keys[character] == nil, character.count == 1 {
            keys[character] = ComputerKeyCodes.Key(code: code, shift: shift)
          }
        }
      }
    }
    return keys
  }
}
