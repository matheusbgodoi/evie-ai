import AppKit
import ApplicationServices
import EvieCore

/// The Accessibility API used to act: pressing a listed element, setting a
/// field's text, reading a field back.
///
/// An element is found again by position, not kept from the observation:
/// whatever lies under its centre now (`AXUIElementCopyElementAtPosition`,
/// which answers for that app's own windows only), one of its ancestors, or
/// — when a container answers the hit test, as a sheet does for its buttons
/// — one of its descendants holding the point, must have the role and label
/// the observation listed (`AccessibilitySnapshotBuilder.describes`). A list
/// that changed under the model's choice therefore presses nothing, rather
/// than whatever moved into that place.
///
/// Every call runs on a task of its own with the snapshotter's 0.5 s
/// messaging timeout, because each is a message to another process.
struct AccessibilityActions: AccessibilityActing {
  /// How far up from the hit element the listed one may be: a button's
  /// label or image is often what lies under its centre.
  static let maximumAncestors = 6
  /// How far down from the hit element, and how many elements in all.
  static let maximumDescendantDepth = 4
  static let maximumDescendantsRead = 300
  static let textRoles: Set<String> = ["AXTextField", "AXTextArea", "AXComboBox"]

  func press(_ element: AXElementSummary, at point: CGPoint, processID: Int32) async
    -> AccessibilityPressResult
  {
    await Task.detached(priority: .userInitiated) {
      guard let found = Self.element(listedAs: element, at: point, processID: processID) else {
        return .notFound
      }
      guard Self.actions(of: found).contains("AXPress") else {
        return .notPressable
      }
      // An error here does not mean nothing happened: a press that opens a
      // modal sheet is often answered only after the timeout.
      return AXUIElementPerformAction(found, "AXPress" as CFString) == .success
        ? .pressed : .unconfirmed
    }.value
  }

  func isStillThere(_ element: AXElementSummary, at point: CGPoint, processID: Int32) async
    -> Bool
  {
    await Task.detached(priority: .userInitiated) {
      Self.element(listedAs: element, at: point, processID: processID) != nil
    }.value
  }

  /// Sets the focused field's text: its whole value when it is empty,
  /// otherwise its selected text, which inserts at the insertion point and
  /// replaces a selection as typing would. Read back afterwards. A value that
  /// did not change at all is `unavailable`, so the keyboard may try; any
  /// other surprise is `mismatch`, so nothing is typed twice.
  ///
  /// Not for Electron apps: their fields are web fields, whose page sees no
  /// value set from outside (the executor already keeps browsers out).
  func insertText(_ text: String, processID: Int32) async -> AccessibilityInsertResult {
    let electron = AccessibilitySnapshotter.isElectron(processID)
    return await Task.detached(priority: .userInitiated) {
      guard !electron, let field = Self.focusedTextField(processID) else {
        return .unavailable
      }
      let before = AXTree.string(field, "AXValue") ?? ""
      let attribute: String
      if before.isEmpty, Self.isSettable(field, "AXValue") {
        attribute = "AXValue"
      } else if Self.isSettable(field, "AXSelectedText") {
        attribute = "AXSelectedText"
      } else {
        return .unavailable
      }
      _ = AXUIElementSetAttributeValue(field, attribute as CFString, text as CFString)
      let after = AXTree.string(field, "AXValue") ?? ""
      if after == before {
        return .unavailable
      }
      let expected = attribute == "AXValue" ? after == text : after.contains(text)
      return expected ? .inserted : .mismatch
    }.value
  }

  func focusedValue(ofProcess processID: Int32) async -> String? {
    await Task.detached(priority: .userInitiated) {
      Self.focusedTextField(processID).flatMap { AXTree.string($0, "AXValue") }
    }.value
  }

  // MARK: - Finding elements

  private static func application(_ processID: Int32) -> AXUIElement {
    let app = AXUIElementCreateApplication(processID)
    AXUIElementSetMessagingTimeout(app, AccessibilitySnapshotter.messagingTimeout)
    return app
  }

  private static func element(
    listedAs listed: AXElementSummary,
    at point: CGPoint,
    processID: Int32
  ) -> AXUIElement? {
    var hit: AXUIElement?
    guard
      AXUIElementCopyElementAtPosition(
        application(processID), Float(point.x), Float(point.y), &hit) == .success,
      let hit
    else {
      return nil
    }
    let tree = AXTree()
    func isListed(_ candidate: AXUIElement) -> Bool {
      tree.read(candidate).map { AccessibilitySnapshotBuilder.describes($0, as: listed) } ?? false
    }

    var ancestor: AXUIElement? = hit
    for _ in 0..<maximumAncestors {
      guard let candidate = ancestor else {
        break
      }
      if isListed(candidate) {
        return candidate
      }
      ancestor = AXTree.element(candidate, "AXParent")
    }

    // A container can answer the hit test for its controls — a sheet does
    // for its buttons (measured on TextEdit's close sheet, 2026-10-16) — so
    // its descendants that hold the point are searched too.
    var queue = [(element: hit, depth: 0)]
    var head = 0
    while head < queue.count, head < maximumDescendantsRead {
      let (element, depth) = queue[head]
      head += 1
      guard depth < maximumDescendantDepth else {
        continue
      }
      for child in tree.children(of: element, limit: 200) {
        guard let node = tree.read(child), let frame = node.frame, frame.contains(point) else {
          continue
        }
        if AccessibilitySnapshotBuilder.describes(node, as: listed) {
          return child
        }
        queue.append((child, depth + 1))
      }
    }
    return nil
  }

  /// The focused element when it is a text field that is not a password
  /// field; a password field's value is never read.
  private static func focusedTextField(_ processID: Int32) -> AXUIElement? {
    guard let focused = AXTree.element(application(processID), "AXFocusedUIElement"),
      let node = AXTree().read(focused), !node.isSecure,
      let role = node.role, textRoles.contains(role)
    else {
      return nil
    }
    return focused
  }

  private static func actions(of element: AXUIElement) -> [String] {
    var names: CFArray?
    guard AXUIElementCopyActionNames(element, &names) == .success else {
      return []
    }
    return names as? [String] ?? []
  }

  private static func isSettable(_ element: AXUIElement, _ attribute: String) -> Bool {
    var settable: DarwinBoolean = false
    return AXUIElementIsAttributeSettable(element, attribute as CFString, &settable) == .success
      && settable.boolValue
  }
}
