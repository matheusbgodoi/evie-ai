import AppKit
import ApplicationServices
import EvieCore

/// Reads the front app's accessibility tree for an observation.
///
/// The walk and every rule about what is listed are EvieCore's
/// (`AccessibilitySnapshotBuilder`); this supplies the elements. It runs on a
/// task of its own, off the main thread, because each read is a message to
/// another process and an app that is busy answers late: every element gets a
/// 0.5 s messaging timeout, the walk gives an app up after three reads in a
/// row go unanswered, and the whole walk stops after `walkBudget`.
///
/// Electron apps build their accessibility tree only for assistive
/// technology they know about, so `AXManualAccessibility` is set on their
/// application element first, as Electron documents. Chrome's similar toggle,
/// `AXEnhancedUserInterface`, is not set: it is undocumented and changes how
/// its windows move and resize. A page without accessibility lists nothing,
/// and the model works from the picture.
struct AccessibilitySnapshotter: AccessibilityReading {
  /// Per message to the observed app. Without one a hung app holds each read
  /// for the system default of six seconds.
  static let messagingTimeout: Float = 0.5
  /// The whole walk. A window of ordinary size is read in tens of
  /// milliseconds; this bounds the pathological ones.
  static let walkBudget: Duration = .seconds(2)

  var isTrusted: Bool {
    AXIsProcessTrusted()
  }

  func snapshot(
    ofProcess processID: Int32,
    within frame: ScreenGeometry.ObservedFrame
  ) async -> AccessibilitySnapshot {
    let electron = Self.isElectron(processID)
    return await Task.detached(priority: .userInitiated) {
      Self.read(processID: processID, frame: frame, electron: electron)
    }.value
  }

  func focusedElementIsSecure(ofProcess processID: Int32) async -> Bool {
    await Task.detached(priority: .userInitiated) {
      let app = Self.application(processID)
      guard let focused = AXTree.element(app, "AXFocusedUIElement") else {
        return false
      }
      return AXTree().read(focused)?.isSecure ?? false
    }.value
  }

  private static func read(
    processID: Int32,
    frame: ScreenGeometry.ObservedFrame,
    electron: Bool
  ) -> AccessibilitySnapshot {
    let app = application(processID)
    if electron {
      AXUIElementSetAttributeValue(app, "AXManualAccessibility" as CFString, kCFBooleanTrue)
    }
    guard
      let window = AXTree.element(app, "AXFocusedWindow") ?? AXTree.element(app, "AXMainWindow")
    else {
      return AccessibilitySnapshot(endedEarly: true)
    }
    let deadline = ContinuousClock.now + walkBudget
    return AccessibilitySnapshotBuilder.snapshot(
      from: window,
      reader: AXTree(),
      frame: frame,
      windowTitle: AXTree.string(window, "AXTitle"),
      isPastDeadline: { ContinuousClock.now >= deadline }
    )
  }

  private static func application(_ processID: Int32) -> AXUIElement {
    let app = AXUIElementCreateApplication(processID)
    AXUIElementSetMessagingTimeout(app, messagingTimeout)
    return app
  }

  /// An app built on Electron ships its framework inside the bundle.
  static func isElectron(_ processID: Int32) -> Bool {
    guard let bundle = NSRunningApplication(processIdentifier: processID)?.bundleURL else {
      return false
    }
    let framework = bundle.appendingPathComponent(
      "Contents/Frameworks/Electron Framework.framework")
    return FileManager.default.fileExists(atPath: framework.path)
  }
}

/// One app's elements, read through the Accessibility API.
///
/// Attribute names are written as their string values rather than the
/// `kAX…` constants, which keeps them in one list the batch read below asks
/// for in a single message per element.
struct AXTree: AccessibilityTreeReading {
  private static let attributes = [
    "AXRole", "AXSubrole", "AXTitle", "AXDescription", "AXPlaceholderValue", "AXValue",
    "AXPosition", "AXSize", "AXEnabled", "AXFocused",
  ]

  func read(_ element: AXUIElement) -> AccessibilityNode? {
    AXUIElementSetMessagingTimeout(element, AccessibilitySnapshotter.messagingTimeout)
    var answer: CFArray?
    let status = AXUIElementCopyMultipleAttributeValues(
      element, Self.attributes as CFArray, AXCopyMultipleAttributeOptions(rawValue: 0), &answer)
    guard status == .success, let values = answer as? [AnyObject],
      values.count == Self.attributes.count
    else {
      return nil
    }
    let origin = Self.point(values[6])
    let size = Self.size(values[7])
    return AccessibilityNode(
      role: values[0] as? String,
      subrole: values[1] as? String,
      title: values[2] as? String,
      detail: values[3] as? String,
      placeholder: values[4] as? String,
      value: values[5] as? String,
      frame: origin.flatMap { origin in size.map { CGRect(origin: origin, size: $0) } },
      isEnabled: Self.bool(values[8]) ?? true,
      isFocused: Self.bool(values[9]) ?? false
    )
  }

  func children(of element: AXUIElement, limit: Int) -> [AXUIElement] {
    var answer: CFArray?
    guard
      AXUIElementCopyAttributeValues(element, "AXChildren" as CFString, 0, limit, &answer)
        == .success,
      let children = answer as? [AXUIElement]
    else {
      return []
    }
    return children
  }

  static func element(_ parent: AXUIElement, _ attribute: String) -> AXUIElement? {
    var value: CFTypeRef?
    guard AXUIElementCopyAttributeValue(parent, attribute as CFString, &value) == .success,
      let value, CFGetTypeID(value) == AXUIElementGetTypeID()
    else {
      return nil
    }
    return unsafeDowncast(value, to: AXUIElement.self)
  }

  static func string(_ element: AXUIElement, _ attribute: String) -> String? {
    var value: CFTypeRef?
    guard AXUIElementCopyAttributeValue(element, attribute as CFString, &value) == .success else {
      return nil
    }
    return value as? String
  }

  /// A missing attribute comes back in the batch as an `AXValue` holding an
  /// error, which none of these accept.
  private static func axValue(_ value: AnyObject, _ type: AXValueType) -> AXValue? {
    guard CFGetTypeID(value) == AXValueGetTypeID() else {
      return nil
    }
    let axValue = unsafeDowncast(value, to: AXValue.self)
    return AXValueGetType(axValue) == type ? axValue : nil
  }

  private static func point(_ value: AnyObject) -> CGPoint? {
    guard let axValue = axValue(value, .cgPoint) else {
      return nil
    }
    var point = CGPoint.zero
    return AXValueGetValue(axValue, .cgPoint, &point) ? point : nil
  }

  private static func size(_ value: AnyObject) -> CGSize? {
    guard let axValue = axValue(value, .cgSize) else {
      return nil
    }
    var size = CGSize.zero
    return AXValueGetValue(axValue, .cgSize, &size) ? size : nil
  }

  private static func bool(_ value: AnyObject) -> Bool? {
    guard CFGetTypeID(value) == CFBooleanGetTypeID() else {
      return nil
    }
    return CFBooleanGetValue(unsafeDowncast(value, to: CFBoolean.self))
  }
}
