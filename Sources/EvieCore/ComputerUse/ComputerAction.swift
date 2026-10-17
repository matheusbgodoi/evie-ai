import CoreGraphics
import Foundation

/// One thing the computer-use loop may do on the Mac, as the model asked for
/// it and before any rule has looked at it.
///
/// A value of this type is a request, never permission: it becomes an action
/// only through `EvieAgentModeBroker.authorize`, which turns it into a
/// `CapabilityProposal` and, when the policy clears it, a `CapabilityCommit`
/// the executor checks again before it moves anything (ADR 0016).
public enum ComputerAction: Sendable, Equatable {
  case click(Target, button: MouseButton, count: Int)
  case moveMouse(Target)
  case drag(from: Target, to: Target)
  case typeText(String)
  case pressKeys(KeyChord)
  /// Lines to scroll: positive `dy` moves down the page, positive `dx` right.
  case scroll(Target, dx: Int, dy: Int)
  case wait(seconds: Int)
  case writeClipboard(String)
  case readClipboard
  case paste
  case openApp(name: String, url: URL?)

  /// Where on the observed screen an action lands.
  ///
  /// Both forms name the observation they were read from, because an element
  /// number or a grid point means something only on the screen the model was
  /// shown; on a later one it points at whatever has moved there since.
  public enum Target: Sendable, Equatable {
    /// An entry of that observation's accessibility list.
    case element(observationID: String, index: Int)
    /// A point on that observation's 0–1000 grid (`ScreenGeometry`).
    case normalized(x: Int, y: Int, observationID: String)

    public var observationID: String {
      switch self {
      case .element(let observationID, _), .normalized(_, _, let observationID):
        observationID
      }
    }
  }

  /// Every screen position the action uses, in order.
  public var targets: [Target] {
    switch self {
    case .click(let target, _, _), .moveMouse(let target), .scroll(let target, _, _):
      [target]
    case .drag(let from, let to):
      [from, to]
    case .typeText, .pressKeys, .wait, .writeClipboard, .readClipboard, .paste, .openApp:
      []
    }
  }

  /// Whether the action posts input into the app in front, so the rules about
  /// that app and the screen it shows apply.
  public var actsOnScreen: Bool {
    switch self {
    case .click, .moveMouse, .drag, .typeText, .pressKeys, .scroll, .paste:
      true
    case .wait, .writeClipboard, .readClipboard, .openApp:
      false
    }
  }

  /// Whether the action sends keystrokes, which secure input must stop.
  public var usesKeyboard: Bool {
    switch self {
    case .typeText, .pressKeys, .paste:
      true
    default:
      false
    }
  }

  /// The capability this action is proposed under.
  public var capabilityIdentifier: String {
    "evie.computer.\(kindName)"
  }

  var kindName: String {
    switch self {
    case .click: "click"
    case .moveMouse: "move_mouse"
    case .drag: "drag"
    case .typeText: "type_text"
    case .pressKeys: "press_keys"
    case .scroll: "scroll"
    case .wait: "wait"
    case .writeClipboard: "write_clipboard"
    case .readClipboard: "read_clipboard"
    case .paste: "paste"
    case .openApp: "open_app"
    }
  }
}

extension ComputerAction: CustomStringConvertible, CustomDebugStringConvertible {
  /// The kind of action only: typed text and clipboard text can be anything
  /// the person has on screen, and descriptions end up in logs.
  public var description: String {
    "ComputerAction(\(kindName), <redacted>)"
  }

  public var debugDescription: String {
    description
  }
}

public enum MouseButton: String, Sendable, Equatable, CaseIterable {
  case left
  case right
  case middle
}

/// A modifier key, in the order macOS writes them in menus: ⌃⌥⇧⌘.
public enum KeyModifier: Int, Sendable, Hashable, CaseIterable, Comparable {
  case control
  case option
  case shift
  case command

  public static func < (lhs: KeyModifier, rhs: KeyModifier) -> Bool {
    lhs.rawValue < rhs.rawValue
  }

  var symbol: String {
    switch self {
    case .control: "⌃"
    case .option: "⌥"
    case .shift: "⇧"
    case .command: "⌘"
    }
  }

  static let spellings: [String: KeyModifier] = [
    "cmd": .command, "command": .command, "⌘": .command, "super": .command, "meta": .command,
    "win": .command,
    "ctrl": .control, "control": .control, "⌃": .control,
    "opt": .option, "option": .option, "alt": .option, "⌥": .option,
    "shift": .shift, "⇧": .shift,
  ]
}

/// A key and the modifiers held with it, in one canonical spelling.
///
/// The model writes chords the way its training data did — "Return",
/// "ctrl+c", "super+space" — so every common spelling is accepted and turned
/// into one form, because the rules that ask before ⌘Q or refuse ⌘⌫ compare
/// that form. Anything else is refused rather than guessed.
public struct KeyChord: Sendable, Hashable {
  public let modifiers: Set<KeyModifier>
  /// A named key ("return", "escape", "delete", "forwarddelete", "tab",
  /// "space", the arrows, "home", "end", "pageup", "pagedown", "f1"…"f20") or
  /// one printable ASCII character, lowercased.
  public let key: String

  public init?(key: String, modifiers: Set<KeyModifier> = []) {
    guard let canonical = Self.canonicalKey(key) else {
      return nil
    }
    self.key = canonical
    self.modifiers = modifiers
  }

  /// Reads "cmd+shift+t", "Return", "ctrl + alt + Delete", "cmd++".
  public init?(parsing text: String) {
    var parts = text.split(separator: "+", omittingEmptySubsequences: false).map {
      $0.trimmingCharacters(in: .whitespaces)
    }
    // "cmd++" splits into ["cmd", "", ""]: the last key is the plus itself.
    if parts.count >= 3, parts[parts.count - 1].isEmpty, parts[parts.count - 2].isEmpty {
      parts.removeLast(2)
      parts.append("+")
    }
    guard let last = parts.last, !last.isEmpty else {
      return nil
    }
    var modifiers: Set<KeyModifier> = []
    for part in parts.dropLast() {
      guard let modifier = KeyModifier.spellings[part.lowercased()],
        modifiers.insert(modifier).inserted
      else {
        return nil
      }
    }
    guard KeyModifier.spellings[last.lowercased()] == nil else {
      return nil
    }
    self.init(key: last, modifiers: modifiers)
  }

  public var isReturn: Bool {
    key == "return"
  }

  /// Space held with any modifier: ⌘Espaço opens Spotlight, and the person
  /// may have bound ⌥Espaço, ⌃Espaço or a hyper key to Raycast, Alfred or
  /// another launcher Evie cannot know of. A bare Space is a keystroke.
  public var mayOpenLauncher: Bool {
    key == "space" && !modifiers.isEmpty
  }

  /// The chord as macOS shows it: "⌘Q", "⇧⌘⌫", "⌘Espaço".
  public var symbol: String {
    modifiers.sorted().map(\.symbol).joined() + (Self.keySymbols[key] ?? key.uppercased())
  }

  private static func canonicalKey(_ text: String) -> String? {
    let lowered = text.lowercased()
    if let named = namedKeys[lowered] {
      return named
    }
    if lowered.count == 1, let scalar = lowered.unicodeScalars.first,
      (0x21...0x7E).contains(scalar.value)
    {
      return lowered
    }
    if lowered.hasPrefix("f"), let number = Int(lowered.dropFirst()), (1...20).contains(number) {
      return "f\(number)"
    }
    return nil
  }

  private static let namedKeys: [String: String] = [
    "return": "return", "enter": "return", "ret": "return", "↩": "return",
    "escape": "escape", "esc": "escape",
    "tab": "tab",
    "space": "space", "spacebar": "space",
    "delete": "delete", "backspace": "delete", "⌫": "delete",
    "forwarddelete": "forwarddelete", "forward_delete": "forwarddelete",
    "up": "up", "arrowup": "up", "up_arrow": "up",
    "down": "down", "arrowdown": "down", "down_arrow": "down",
    "left": "left", "arrowleft": "left", "left_arrow": "left",
    "right": "right", "arrowright": "right", "right_arrow": "right",
    "home": "home", "end": "end",
    "pageup": "pageup", "page_up": "pageup", "pagedown": "pagedown", "page_down": "pagedown",
  ]

  private static let keySymbols: [String: String] = [
    "return": "↩", "escape": "Esc", "tab": "⇥", "space": "Espaço", "delete": "⌫",
    "forwarddelete": "⌦", "up": "↑", "down": "↓", "left": "←", "right": "→",
    "home": "↖", "end": "↘", "pageup": "⇞", "pagedown": "⇟",
  ]
}

/// An application, as the system names it — never as the model does.
public struct ComputerAppIdentity: Sendable, Equatable {
  public let bundleID: String?
  /// `NSRunningApplication.localizedName`.
  public let name: String
  public let processID: Int32

  public init(bundleID: String?, name: String, processID: Int32) {
    self.bundleID = bundleID
    self.name = name
    self.processID = processID
  }
}

/// One accessible element of the front window, as the observation lists it.
public struct AXElementSummary: Sendable, Equatable {
  /// The number the model names it by, valid only in its own observation.
  public let index: Int
  /// `kAXRoleAttribute`, such as "AXButton".
  public let role: String
  /// The title, or the description when there is no title. Written by the
  /// app — on a web page, by the page.
  public let title: String
  /// Its frame on the observation's 0–1000 grid, clipped to what was observed.
  public let box0to1000: CGRect
  /// An `AXSecureTextField`: a password field.
  public let isSecure: Bool

  public init(index: Int, role: String, title: String, box0to1000: CGRect, isSecure: Bool) {
    self.index = index
    self.role = role
    self.title = title
    self.box0to1000 = box0to1000
    self.isSecure = isSecure
  }
}

/// One window on the window server's list, as it reports it: the process
/// that owns it, where it is, and its level (0 for a normal window; higher
/// for panels, the Dock, the menu bar and launchers).
public struct ComputerWindowSummary: Sendable, Equatable {
  public let owner: ComputerAppIdentity
  /// In global Core Graphics points.
  public let frame: CGRect
  /// `kCGWindowLayer`.
  public let layer: Int

  public init(owner: ComputerAppIdentity, frame: CGRect, layer: Int) {
    self.owner = owner
    self.frame = frame
    self.layer = layer
  }
}

/// What the loop saw before an action: the frame the model's coordinates are
/// relative to, the app in front, its accessible elements and Evie's own
/// windows, all read by code.
public struct ComputerObservation: Sendable, Equatable {
  /// Assigned by the observer, new for every observation; the revision every
  /// action proposed from it is bound to.
  public let id: String
  public let capturedAt: Date
  public let displayID: CGDirectDisplayID
  public let frame: ScreenGeometry.ObservedFrame
  public let frontApp: ComputerAppIdentity
  public let windowTitle: String?
  public let elements: [AXElementSummary]
  public let focusedElementIndex: Int?
  /// Evie's windows in global Core Graphics points. They are left out of the
  /// capture, so the model never sees them, but a point it names can still
  /// land on one.
  public let evieWindowFrames: [CGRect]
  /// The front app's window, in global points, where the window server had
  /// it at observation time. The executor reads it again before acting on a
  /// point and refuses when it moved: every box and point of this observation
  /// was measured against it.
  public let windowFrame: CGRect?
  /// Every visible window on screen at observation time, front to back,
  /// Evie's own passed over; `nil` when the list was not read. The point an
  /// action lands on is judged by the app whose window holds it, and an open
  /// launcher is found here by its owner, since its panel floats over an app
  /// that stays in front.
  public let windows: [ComputerWindowSummary]?
  /// The capture, when this step needed pixels; an AX-only observation has none.
  public let image: EvieImagePart?

  public init(
    id: String,
    capturedAt: Date,
    displayID: CGDirectDisplayID,
    frame: ScreenGeometry.ObservedFrame,
    frontApp: ComputerAppIdentity,
    windowTitle: String? = nil,
    elements: [AXElementSummary] = [],
    focusedElementIndex: Int? = nil,
    evieWindowFrames: [CGRect] = [],
    windowFrame: CGRect? = nil,
    windows: [ComputerWindowSummary]? = nil,
    image: EvieImagePart? = nil
  ) {
    self.id = id
    self.capturedAt = capturedAt
    self.displayID = displayID
    self.frame = frame
    self.frontApp = frontApp
    self.windowTitle = windowTitle
    self.elements = elements
    self.focusedElementIndex = focusedElementIndex
    self.evieWindowFrames = evieWindowFrames
    self.windowFrame = windowFrame
    self.windows = windows
    self.image = image
  }

  public func element(index: Int) -> AXElementSummary? {
    elements.first { $0.index == index }
  }

  public var focusedElement: AXElementSummary? {
    focusedElementIndex.flatMap(element(index:))
  }

  /// The frontmost listed window holding `point`, the one a click there
  /// reaches; `nil` when none does or the list was not read.
  public func window(at point: CGPoint) -> ComputerWindowSummary? {
    windows?.first { $0.frame.contains(point) }
  }

  /// The innermost element under a grid point: the smallest box holding it,
  /// since a button sits inside the group that sits inside the window.
  public func element(atGrid point: CGPoint) -> AXElementSummary? {
    elements
      .filter {
        point.x >= $0.box0to1000.minX && point.x <= $0.box0to1000.maxX
          && point.y >= $0.box0to1000.minY && point.y <= $0.box0to1000.maxY
      }
      .min { area($0) < area($1) }
  }

  private func area(_ element: AXElementSummary) -> CGFloat {
    element.box0to1000.width * element.box0to1000.height
  }
}

/// What is true at the moment of acting, read just before the action rather
/// than at observation time: secure input and the app in front can change in
/// between, and an action is checked against now.
public struct ComputerLiveState: Sendable, Equatable {
  /// `NSWorkspace.frontmostApplication`; `nil` when it cannot be read.
  public let frontApp: ComputerAppIdentity?
  /// `IsSecureEventInputEnabled()`: some app holds a password field.
  public let secureInputEnabled: Bool
  /// The focused element is an `AXSecureTextField`.
  public let focusedFieldIsSecure: Bool

  public init(
    frontApp: ComputerAppIdentity?,
    secureInputEnabled: Bool,
    focusedFieldIsSecure: Bool
  ) {
    self.frontApp = frontApp
    self.secureInputEnabled = secureInputEnabled
    self.focusedFieldIsSecure = focusedFieldIsSecure
  }
}

/// What carrying out an action did, as the executor saw it afterwards.
public struct ActionResult: Sendable, Equatable {
  public enum Outcome: Sendable, Equatable {
    /// The executor saw the action take effect (a value read back, an app
    /// in front, the clipboard written).
    case changed
    /// The executor posted the action but cannot tell what it did; the loop
    /// decides from the next observation, as `changed` or `noChange`.
    case carriedOut
    /// The screen looked the same afterwards ("nada mudou").
    case noChange
    case failed
  }

  public let outcome: Outcome
  /// Told to the model as the tool result.
  public let detail: String

  public init(outcome: Outcome, detail: String) {
    self.outcome = outcome
    self.detail = detail
  }
}

/// The Mac side of computer use: observing (`EvieComputerObserving`) and
/// acting.
///
/// `perform` acts only on a commit `EvieAgentModeBroker.validate(_:for:)`
/// still accepts, checked immediately before the first event is posted, so a
/// revoked session, an expired grant or a newer observation stops an action
/// that was already cleared.
public protocol EvieComputerActing: EvieComputerObserving {
  func perform(_ action: ComputerAction, commit: CapabilityCommit) async throws -> ActionResult
}
