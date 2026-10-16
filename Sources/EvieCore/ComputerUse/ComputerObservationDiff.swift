import CoreGraphics
import Foundation

/// What changed between two observations of the same session, read from the
/// accessibility lists alone.
///
/// It serves two purposes. The model reads it, in the observation after an
/// action, as "what my action did". And the loop reads `needsPixels` to decide
/// whether that observation needs a new picture: on the PC a picture costs
/// about 26 s of CPU projector (measured for S4, `docs/VISION.md`), so after an
/// action that changed a little the model gets the new list and this line,
/// and a new picture only when the screen changed meaningfully or it asks for
/// one with `look_screen`.
///
/// Elements are matched by role and title, as a multiset: the numbers are new
/// in every observation and the boxes move with any scroll, so neither can
/// say whether a button is the same button.
public struct ComputerObservationDiff: Sendable, Equatable {
  /// The share of the two lists, together, that is new or gone at which the
  /// screen is taken to have changed meaningfully. An estimate, not a
  /// measurement: a third keeps a typed character or a toggled checkbox
  /// text-only and sends a picture for a new pane, dialog or page. The S5d
  /// evals are where it gets tuned.
  public static let meaningfulChangeShare = 1.0 / 3.0
  /// Elements named in the line per kind of change; the rest are counted.
  public static let namedPerKind = 5
  static let maximumNameCharacters = 40

  public let previousID: String
  public let appChanged: Bool
  public let windowChanged: Bool
  public let frameMoved: Bool
  /// From the new observation, with its numbers.
  public let added: [AXElementSummary]
  /// From the old observation.
  public let removed: [AXElementSummary]
  public let focusChanged: Bool
  /// The new observation's focused element, if any.
  public let focused: AXElementSummary?
  private let listSizes: Int

  public init(from previous: ComputerObservation, to current: ComputerObservation) {
    previousID = previous.id
    appChanged =
      previous.frontApp.processID != current.frontApp.processID
      || previous.frontApp.bundleID != current.frontApp.bundleID
    windowChanged = previous.windowTitle != current.windowTitle
    frameMoved = previous.frame.hasMoved(comparedTo: current.frame.frameInGlobalCG)

    var unmatched = Dictionary(grouping: previous.elements, by: Self.key)
    var added: [AXElementSummary] = []
    for element in current.elements {
      let key = Self.key(element)
      if var same = unmatched[key], !same.isEmpty {
        same.removeFirst()
        unmatched[key] = same
      } else {
        added.append(element)
      }
    }
    let leftOver = Set(unmatched.values.flatMap { $0.map(\.index) })
    self.added = added
    removed = previous.elements.filter { leftOver.contains($0.index) }

    focused = current.focusedElement
    focusChanged = previous.focusedElement.map(Self.key) != current.focusedElement.map(Self.key)
    listSizes = previous.elements.count + current.elements.count
  }

  /// Nothing the lists or the frame can show changed.
  public var isEmpty: Bool {
    !appChanged && !windowChanged && !frameMoved && added.isEmpty && removed.isEmpty
      && !focusChanged
  }

  /// Whether the observation after an action should carry a new picture.
  ///
  /// Always for another app or window, a moved frame, or a screen that lists
  /// nothing — an app without accessibility, a canvas, a web page with bare
  /// divs — where the picture is the only account of what happened. Otherwise
  /// when a third or more of the lists changed.
  public var needsPixels: Bool {
    if appChanged || windowChanged || frameMoved || listSizes == 0 {
      return true
    }
    let changed = Double(added.count + removed.count)
    return changed / Double(listSizes) >= Self.meaningfulChangeShare
  }

  /// One line for the model, inside the observation's fence: every title in
  /// it is screen text and is cleaned like the rest.
  public var line: String {
    var parts: [String] = []
    if appChanged {
      parts.append("outro app na frente")
    }
    if windowChanged {
      parts.append("outra janela")
    }
    if frameMoved {
      parts.append("a área observada mudou de lugar ou de tamanho")
    }
    if !added.isEmpty {
      let noun = added.count == 1 ? "novo" : "novos"
      parts.append("\(added.count) \(noun): " + Self.names(added, numbered: true))
    }
    if !removed.isEmpty {
      let verb = removed.count == 1 ? "saiu" : "saíram"
      parts.append("\(removed.count) \(verb): " + Self.names(removed, numbered: false))
    }
    if focusChanged {
      parts.append(focused.map { "foco agora em [\($0.index)]" } ?? "sem foco")
    }
    let body = parts.isEmpty ? "nenhuma na lista de elementos" : parts.joined(separator: "; ")
    return "mudanças desde \(previousID): \(body)"
  }

  private static func names(_ elements: [AXElementSummary], numbered: Bool) -> String {
    var names = elements.prefix(namedPerKind).map { element in
      let title = ComputerScreenText.sanitized(element.title, limit: maximumNameCharacters)
      let shown = title.isEmpty ? ComputerScreenText.sanitized(element.role, limit: 30) : "“\(title)”"
      return numbered ? "[\(element.index)] \(shown)" : shown
    }
    if elements.count > namedPerKind {
      names.append("…")
    }
    return names.joined(separator: ", ")
  }

  private static func key(_ element: AXElementSummary) -> String {
    element.role + "\u{1F}" + element.title
  }
}
