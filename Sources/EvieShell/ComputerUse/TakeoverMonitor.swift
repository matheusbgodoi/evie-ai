import AppKit
import EvieCore

/// Notices the person taking the Mac back during an agent session.
///
/// Two `NSEvent` monitors: a global one for input that goes to other apps,
/// and a local one for input that goes to Evie herself — a click on her
/// overlay or a key in her field is the person too. What counts is
/// `ComputerTakeoverRule`'s: anything Evie did not post (her events carry
/// `EvieSyntheticInput.tag`), except a pointer event without movement.
/// Mouse-entered and exited are not watched at all, since a window of Evie's
/// appearing under a still pointer sends them with no user data.
///
/// Verified 2026-10-16 (M5 24 GB, macOS 27.2): a tagged mouse move posted at
/// `.cghidEventTap` reached a global `NSEvent` monitor with
/// `eventSourceUserData` 0xE71E intact, as it reached a listen-only
/// `CGEventTap`, so no tap — and no Input Monitoring grant — is needed. The
/// local monitor reads the same field from the same event record; it was not
/// observed live, because that needs Evie to be the active app. A global
/// monitor sees key events only with the Accessibility grant, which a session
/// needs anyway. Neither monitor can change or swallow an event.
///
/// Watching starts with the session and stops with it; nothing is watched
/// otherwise.
@MainActor
final class TakeoverMonitor {
  /// The person took over: pause the session.
  var onTakeover: () -> Void = {}

  private var rule = ComputerTakeoverRule()
  private var global: Any?
  private var local: Any?

  static let watched: NSEvent.EventTypeMask = [
    .mouseMoved, .leftMouseDown, .rightMouseDown, .otherMouseDown, .leftMouseDragged,
    .rightMouseDragged, .otherMouseDragged, .scrollWheel, .keyDown, .flagsChanged,
  ]

  var isWatching: Bool {
    global != nil || local != nil
  }

  func start() {
    guard !isWatching else {
      return
    }
    rule = ComputerTakeoverRule()
    global = NSEvent.addGlobalMonitorForEvents(matching: Self.watched) { [weak self] event in
      MainActor.assumeIsolated { self?.consider(event) }
    }
    local = NSEvent.addLocalMonitorForEvents(matching: Self.watched) { [weak self] event in
      MainActor.assumeIsolated { self?.consider(event) }
      return event
    }
  }

  func stop() {
    for monitor in [global, local].compactMap({ $0 }) {
      NSEvent.removeMonitor(monitor)
    }
    global = nil
    local = nil
  }

  /// The person is being asked something on a card: the mouse is how they
  /// answer.
  func hold() {
    rule.hold()
  }

  func release() {
    rule.release(at: .now)
  }

  /// Right after Continuar.
  func quiet() {
    rule.quiet(from: .now)
  }

  private func consider(_ event: NSEvent) {
    guard let input = Self.input(of: event) else {
      return
    }
    let userData = event.cgEvent?.getIntegerValueField(.eventSourceUserData) ?? 0
    if rule.isTakeover(input, eventUserData: userData, at: .now) {
      onTakeover()
    }
  }

  private static func input(of event: NSEvent) -> ComputerTakeoverRule.Input? {
    switch event.type {
    case .mouseMoved, .leftMouseDragged, .rightMouseDragged, .otherMouseDragged:
      .pointerMoved(dx: Double(event.deltaX), dy: Double(event.deltaY))
    case .leftMouseDown, .rightMouseDown, .otherMouseDown:
      .button
    case .scrollWheel:
      .scroll
    case .keyDown, .flagsChanged:
      .key
    default:
      nil
    }
  }

  isolated deinit {
    stop()
  }
}
