import CoreGraphics
import Foundation

/// What one accessibility element said about itself, in Evie's own types.
///
/// The shell reads these from `AXUIElement`s; the walk and every rule about
/// what is listed live here, so they are tested without an app.
public struct AccessibilityNode: Sendable, Equatable {
  /// `AXRole`, such as "AXButton".
  public var role: String?
  /// `AXSubrole`, such as "AXSecureTextField".
  public var subrole: String?
  /// `AXTitle`.
  public var title: String?
  /// `AXDescription`.
  public var detail: String?
  /// `AXPlaceholderValue`.
  public var placeholder: String?
  /// `AXValue`, only when it is text.
  public var value: String?
  /// `AXPosition` and `AXSize`: global Core Graphics points, top-left origin.
  public var frame: CGRect?
  /// `AXEnabled`; an element that does not say is taken as enabled.
  public var isEnabled: Bool
  /// `AXFocused`.
  public var isFocused: Bool

  public init(
    role: String? = nil,
    subrole: String? = nil,
    title: String? = nil,
    detail: String? = nil,
    placeholder: String? = nil,
    value: String? = nil,
    frame: CGRect? = nil,
    isEnabled: Bool = true,
    isFocused: Bool = false
  ) {
    self.role = role
    self.subrole = subrole
    self.title = title
    self.detail = detail
    self.placeholder = placeholder
    self.value = value
    self.frame = frame
    self.isEnabled = isEnabled
    self.isFocused = isFocused
  }

  /// A password field, however the app spells it.
  public var isSecure: Bool {
    role == AccessibilitySnapshotBuilder.secureRole || subrole == AccessibilitySnapshotBuilder.secureRole
  }
}

/// A tree of accessibility elements: the app's real one in the shell, one in
/// memory in the tests.
public protocol AccessibilityTreeReading {
  associatedtype Element
  /// The element's attributes, or `nil` when it did not answer in time.
  func read(_ element: Element) -> AccessibilityNode?
  /// At most `limit` of its children, in the app's order.
  func children(of element: Element, limit: Int) -> [Element]
}

/// How far one snapshot may go. Every limit is a reason to stop with what was
/// found, never an error: a partial list still helps the model, and the
/// picture shows the rest.
public struct AccessibilitySnapshotLimits: Sendable, Equatable {
  /// Deeper than this is a web page's nesting of divs, not a control a person
  /// reaches; real windows here bottom out well above it.
  public var maximumDepth: Int
  /// The most the model is shown: `ObservationFormatter.maximumElements`.
  public var maximumElements: Int
  /// Elements read in all, listed or not, so a window with a million table
  /// cells costs a bounded walk.
  public var maximumVisited: Int
  /// Children taken from one element; a long list beyond this is mostly
  /// scrolled out of view anyway.
  public var maximumChildren: Int
  /// Elements in a row that did not answer before the walk gives the app up:
  /// each costs the 0.5 s messaging timeout, so a hung app is left after
  /// about 1.5 s instead of after one timeout per element.
  public var maximumUnansweredReads: Int

  public static let standard = AccessibilitySnapshotLimits(
    maximumDepth: 25,
    maximumElements: ObservationFormatter.maximumElements,
    maximumVisited: 4_000,
    maximumChildren: 500,
    maximumUnansweredReads: 3
  )
}

/// The interactive elements of one window, as an observation lists them.
public struct AccessibilitySnapshot: Sendable, Equatable {
  public var windowTitle: String?
  public var elements: [AXElementSummary]
  public var focusedElementIndex: Int?
  /// How many elements were read, listed or not.
  public var visitedNodes: Int
  /// Whether a limit, the time budget or an unresponsive app cut the walk
  /// short, so there may be more on screen than is listed.
  public var endedEarly: Bool

  public init(
    windowTitle: String? = nil,
    elements: [AXElementSummary] = [],
    focusedElementIndex: Int? = nil,
    visitedNodes: Int = 0,
    endedEarly: Bool = false
  ) {
    self.windowTitle = windowTitle
    self.elements = elements
    self.focusedElementIndex = focusedElementIndex
    self.visitedNodes = visitedNodes
    self.endedEarly = endedEarly
  }
}

/// Walks an accessibility tree breadth first and keeps what a person could
/// act on and see.
///
/// Breadth first, so a cut list keeps a window's toolbars and top-level
/// controls rather than the inside of its first table. Kept: elements of an
/// interactive role, enabled, with some part inside the observed frame. Their
/// boxes are on that frame's 0–1000 grid (`ObservedFrame.normalizedBox`):
/// accessibility positions are already global Core Graphics points, so the
/// frame the model's answers are mapped through is the one the boxes come
/// from. A subtree whose own frame lies wholly outside is not walked — that
/// is a list scrolled away, often the bulk of a window.
public enum AccessibilitySnapshotBuilder {
  public static let secureRole = "AXSecureTextField"

  /// The roles a click, a keystroke or a scroll is aimed at. Static text and
  /// images are left out: the picture shows them, and listing every label
  /// would spend the 150 on words instead of controls.
  public static let interactiveRoles: Set<String> = [
    "AXButton", "AXMenuButton", "AXPopUpButton", "AXCheckBox", "AXRadioButton",
    "AXTextField", "AXTextArea", secureRole, "AXComboBox", "AXLink", "AXCell",
    "AXMenuItem", "AXMenuBarItem", "AXSlider", "AXDisclosureTriangle", "AXIncrementor",
  ]

  public static func snapshot<Reader: AccessibilityTreeReading>(
    from root: Reader.Element,
    reader: Reader,
    frame: ScreenGeometry.ObservedFrame,
    windowTitle: String? = nil,
    limits: AccessibilitySnapshotLimits = .standard,
    isPastDeadline: () -> Bool = { false }
  ) -> AccessibilitySnapshot {
    var snapshot = AccessibilitySnapshot(windowTitle: windowTitle)
    var queue: [(element: Reader.Element, depth: Int)] = [(root, 0)]
    var head = 0
    var unanswered = 0

    while head < queue.count {
      guard snapshot.elements.count < limits.maximumElements,
        snapshot.visitedNodes < limits.maximumVisited,
        unanswered < limits.maximumUnansweredReads,
        !isPastDeadline()
      else {
        snapshot.endedEarly = true
        break
      }
      let (element, depth) = queue[head]
      head += 1
      snapshot.visitedNodes += 1

      guard let node = reader.read(element) else {
        unanswered += 1
        continue
      }
      unanswered = 0

      if let box = listedBox(of: node, in: frame) {
        let index = snapshot.elements.count
        snapshot.elements.append(
          AXElementSummary(
            index: index,
            role: node.isSecure ? secureRole : node.role ?? "",
            title: label(of: node),
            box0to1000: box,
            isSecure: node.isSecure
          ))
        if node.isFocused {
          snapshot.focusedElementIndex = index
        }
      }

      if let nodeFrame = node.frame, !nodeFrame.isEmpty,
        !nodeFrame.intersects(frame.frameInGlobalCG)
      {
        continue
      }
      guard depth < limits.maximumDepth else {
        if !reader.children(of: element, limit: 1).isEmpty {
          snapshot.endedEarly = true
        }
        continue
      }
      for child in reader.children(of: element, limit: limits.maximumChildren) {
        queue.append((child, depth + 1))
      }
    }
    return snapshot
  }

  /// Where an element's box goes on the grid, or `nil` when it is not listed.
  static func listedBox(
    of node: AccessibilityNode,
    in frame: ScreenGeometry.ObservedFrame
  ) -> CGRect? {
    guard let role = node.role, interactiveRoles.contains(role) || node.isSecure,
      node.isEnabled,
      let global = node.frame, global.width > 0, global.height > 0
    else {
      return nil
    }
    return frame.normalizedBox(forGlobalCG: global)
  }

  /// Whether `node` is the element an observation listed as `element`: the
  /// same role (a password field by its subrole too) and the same label. The
  /// executor asks this of whatever lies under an element's centre when it
  /// acts, so a list that moved under it presses nothing.
  public static func describes(_ node: AccessibilityNode, as element: AXElementSummary) -> Bool {
    let role = node.isSecure ? secureRole : node.role ?? ""
    return role == element.role && label(of: node) == element.title
  }

  /// What the element is called: its title, else its description, else its
  /// placeholder, else its text value. A password field's value is never a
  /// label — it is the password.
  static func label(of node: AccessibilityNode) -> String {
    var candidates = [node.title, node.detail, node.placeholder]
    if !node.isSecure {
      candidates.append(node.value)
    }
    for candidate in candidates {
      if let text = candidate?.trimmingCharacters(in: .whitespacesAndNewlines), !text.isEmpty {
        return text
      }
    }
    return ""
  }
}
