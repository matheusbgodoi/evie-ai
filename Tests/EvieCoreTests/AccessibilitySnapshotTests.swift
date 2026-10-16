import CoreGraphics
import Foundation
import Testing

@testable import EvieCore

@Suite("Accessibility snapshot")
struct AccessibilitySnapshotTests {
  /// A 1000×500-point window at (100, 50), sent as a 1000×500 image: one grid
  /// step is one point across and half a point down.
  static let frame = ScreenGeometry.ObservedFrame(
    frameInGlobalCG: CGRect(x: 100, y: 50, width: 1_000, height: 500),
    imageSize: CGSize(width: 1_000, height: 500)
  )

  @Test("an element is the one listed only with the same role and label")
  func describesListedElement() {
    let listed = AXElementSummary(
      index: 4, role: "AXButton", title: "Apagar", box0to1000: .zero, isSecure: false)

    #expect(AccessibilitySnapshotBuilder.describes(
      AccessibilityNode(role: "AXButton", title: "Apagar"), as: listed))
    #expect(AccessibilitySnapshotBuilder.describes(
      AccessibilityNode(role: "AXButton", detail: "Apagar"), as: listed))
    #expect(!AccessibilitySnapshotBuilder.describes(
      AccessibilityNode(role: "AXButton", title: "Salvar"), as: listed))
    #expect(!AccessibilitySnapshotBuilder.describes(
      AccessibilityNode(role: "AXSheet", detail: "Apagar"), as: listed))

    let password = AXElementSummary(
      index: 0, role: "AXSecureTextField", title: "Senha", box0to1000: .zero, isSecure: true)
    #expect(AccessibilitySnapshotBuilder.describes(
      AccessibilityNode(role: "AXTextField", subrole: "AXSecureTextField", title: "Senha"),
      as: password))
  }

  @Test("lists the interactive elements breadth first, numbered in that order")
  func breadthFirstOrder() {
    let tree = TestTree()
    let window = tree.add(role: "AXWindow", frame: Self.frame.frameInGlobalCG)
    let toolbar = tree.add(role: "AXToolbar", parent: window, frame: rect(100, 50, 1_000, 40))
    let content = tree.add(role: "AXGroup", parent: window, frame: rect(100, 90, 1_000, 460))
    tree.add(role: "AXButton", title: "Nova nota", parent: toolbar, frame: rect(110, 55, 80, 30))
    tree.add(role: "AXTextArea", title: "Corpo", parent: content, frame: rect(120, 100, 900, 400))
    tree.add(role: "AXStaticText", title: "só texto", parent: content, frame: rect(120, 90, 50, 10))
    tree.add(role: "AXButton", title: "Compartilhar", parent: toolbar, frame: rect(1_000, 55, 80, 30))

    let snapshot = AccessibilitySnapshotBuilder.snapshot(from: window, reader: tree, frame: Self.frame)

    #expect(snapshot.elements.map(\.title) == ["Nova nota", "Compartilhar", "Corpo"])
    #expect(snapshot.elements.map(\.index) == [0, 1, 2])
    #expect(!snapshot.endedEarly)
  }

  @Test("boxes are on the grid of the observed frame, not of the screen")
  func boxesRelativeToFrame() throws {
    let tree = TestTree()
    let window = tree.add(role: "AXWindow", frame: Self.frame.frameInGlobalCG)
    // Global (600, 300) is (500, 250) inside the window: grid (500, 500).
    tree.add(role: "AXButton", title: "Salvar", parent: window, frame: rect(600, 300, 100, 50))

    let snapshot = AccessibilitySnapshotBuilder.snapshot(from: window, reader: tree, frame: Self.frame)

    let save = try #require(snapshot.elements.first)
    #expect(save.box0to1000 == CGRect(x: 500, y: 500, width: 100, height: 100))
  }

  @Test("an element outside the observed frame is dropped, one cut by its edge is clipped")
  func dropsAndClipsAtTheEdge() throws {
    let tree = TestTree()
    let window = tree.add(role: "AXWindow", frame: Self.frame.frameInGlobalCG)
    tree.add(role: "AXButton", title: "Fora", parent: window, frame: rect(1_200, 300, 50, 20))
    tree.add(role: "AXButton", title: "Metade", parent: window, frame: rect(1_050, 100, 100, 20))

    let snapshot = AccessibilitySnapshotBuilder.snapshot(from: window, reader: tree, frame: Self.frame)

    let half = try #require(snapshot.elements.first)
    #expect(snapshot.elements.count == 1)
    #expect(half.title == "Metade")
    #expect(half.box0to1000.maxX == 1_000)
  }

  @Test("a subtree scrolled out of the frame is not walked")
  func skipsSubtreesOutsideTheFrame() {
    let tree = TestTree()
    let window = tree.add(role: "AXWindow", frame: Self.frame.frameInGlobalCG)
    let offscreen = tree.add(role: "AXGroup", parent: window, frame: rect(100, 2_000, 1_000, 500))
    for row in 0..<50 {
      tree.add(
        role: "AXButton", title: "linha \(row)", parent: offscreen,
        frame: rect(100, 2_000 + CGFloat(row) * 10, 100, 10))
    }

    let snapshot = AccessibilitySnapshotBuilder.snapshot(from: window, reader: tree, frame: Self.frame)

    #expect(snapshot.elements.isEmpty)
    #expect(snapshot.visitedNodes == 2)
  }

  @Test("a password field is flagged and its value never becomes its label")
  func flagsSecureFields() throws {
    let tree = TestTree()
    let window = tree.add(role: "AXWindow", frame: Self.frame.frameInGlobalCG)
    tree.add(
      role: "AXTextField", subrole: "AXSecureTextField", value: "hunter2", parent: window,
      frame: rect(200, 200, 200, 24))
    tree.add(
      role: "AXTextField", placeholder: "Usuário", value: "matheus", parent: window,
      frame: rect(200, 150, 200, 24))

    let snapshot = AccessibilitySnapshotBuilder.snapshot(from: window, reader: tree, frame: Self.frame)

    let password = try #require(snapshot.elements.first { $0.isSecure })
    #expect(password.role == "AXSecureTextField")
    #expect(password.title.isEmpty)
    #expect(!snapshot.elements.map(\.title).contains("hunter2"))
    #expect(snapshot.elements.contains { $0.title == "Usuário" && !$0.isSecure })
  }

  @Test("the label is the title, then the description, the placeholder, the value")
  func labelOrder() {
    let tree = TestTree()
    let window = tree.add(role: "AXWindow", frame: Self.frame.frameInGlobalCG)
    tree.add(
      role: "AXButton", title: "Título", detail: "descrição", parent: window,
      frame: rect(110, 60, 10, 10))
    tree.add(role: "AXButton", detail: "Fechar", parent: window, frame: rect(130, 60, 10, 10))
    tree.add(role: "AXPopUpButton", value: "Arial", parent: window, frame: rect(150, 60, 10, 10))
    tree.add(role: "AXButton", parent: window, frame: rect(170, 60, 10, 10))

    let snapshot = AccessibilitySnapshotBuilder.snapshot(from: window, reader: tree, frame: Self.frame)

    #expect(snapshot.elements.map(\.title) == ["Título", "Fechar", "Arial", ""])
  }

  @Test("a disabled control is left out")
  func dropsDisabled() {
    let tree = TestTree()
    let window = tree.add(role: "AXWindow", frame: Self.frame.frameInGlobalCG)
    tree.add(role: "AXButton", title: "Desfazer", enabled: false, parent: window, frame: rect(110, 60, 30, 20))
    tree.add(role: "AXButton", title: "Refazer", parent: window, frame: rect(150, 60, 30, 20))

    let snapshot = AccessibilitySnapshotBuilder.snapshot(from: window, reader: tree, frame: Self.frame)

    #expect(snapshot.elements.map(\.title) == ["Refazer"])
  }

  @Test("the focused element is named by its number")
  func focusedElement() {
    let tree = TestTree()
    let window = tree.add(role: "AXWindow", frame: Self.frame.frameInGlobalCG)
    tree.add(role: "AXButton", title: "OK", parent: window, frame: rect(110, 60, 30, 20))
    tree.add(role: "AXTextField", title: "Assunto", focused: true, parent: window, frame: rect(150, 60, 300, 20))

    let snapshot = AccessibilitySnapshotBuilder.snapshot(from: window, reader: tree, frame: Self.frame)

    #expect(snapshot.focusedElementIndex == 1)
  }

  @Test("stops at 150 elements and says the list was cut")
  func elementCap() {
    let tree = TestTree()
    let window = tree.add(role: "AXWindow", frame: Self.frame.frameInGlobalCG)
    for index in 0..<200 {
      tree.add(
        role: "AXButton", title: "b\(index)", parent: window,
        frame: rect(100 + CGFloat(index % 50) * 20, 60 + CGFloat(index / 50) * 20, 10, 10))
    }

    let snapshot = AccessibilitySnapshotBuilder.snapshot(from: window, reader: tree, frame: Self.frame)

    #expect(snapshot.elements.count == AccessibilitySnapshotLimits.standard.maximumElements)
    #expect(AccessibilitySnapshotLimits.standard.maximumElements == 150)
    #expect(snapshot.endedEarly)
  }

  @Test("goes no deeper than 25 levels")
  func depthCap() {
    let tree = TestTree()
    let window = tree.add(role: "AXWindow", frame: Self.frame.frameInGlobalCG)
    var parent = window
    for _ in 0..<30 {
      parent = tree.add(role: "AXGroup", parent: parent, frame: Self.frame.frameInGlobalCG)
    }
    tree.add(role: "AXButton", title: "fundo", parent: parent, frame: rect(110, 60, 30, 20))

    let snapshot = AccessibilitySnapshotBuilder.snapshot(from: window, reader: tree, frame: Self.frame)

    #expect(AccessibilitySnapshotLimits.standard.maximumDepth == 25)
    #expect(snapshot.elements.isEmpty)
    #expect(snapshot.endedEarly)
  }

  @Test("an app that stops answering ends the walk instead of stalling it")
  func unresponsiveApp() {
    let tree = TestTree()
    let window = tree.add(role: "AXWindow", frame: Self.frame.frameInGlobalCG)
    tree.add(role: "AXButton", title: "antes", parent: window, frame: rect(110, 60, 30, 20))
    for _ in 0..<20 {
      tree.add(role: "AXButton", title: "mudo", parent: window, frame: rect(150, 60, 30, 20))
    }
    tree.silent = { $0.title == "mudo" }

    let snapshot = AccessibilitySnapshotBuilder.snapshot(from: window, reader: tree, frame: Self.frame)

    #expect(snapshot.elements.map(\.title) == ["antes"])
    #expect(snapshot.endedEarly)
    #expect(tree.reads <= 2 + AccessibilitySnapshotLimits.standard.maximumUnansweredReads)
  }

  @Test("a spent time budget ends the walk with what was found")
  func timeBudget() {
    let tree = TestTree()
    let window = tree.add(role: "AXWindow", frame: Self.frame.frameInGlobalCG)
    tree.add(role: "AXButton", title: "um", parent: window, frame: rect(110, 60, 30, 20))
    tree.add(role: "AXButton", title: "dois", parent: window, frame: rect(150, 60, 30, 20))
    var checks = 0

    let snapshot = AccessibilitySnapshotBuilder.snapshot(
      from: window, reader: tree, frame: Self.frame,
      isPastDeadline: {
        checks += 1
        return checks > 2
      })

    #expect(snapshot.elements.map(\.title) == ["um"])
    #expect(snapshot.endedEarly)
  }

  private func rect(_ x: CGFloat, _ y: CGFloat, _ width: CGFloat, _ height: CGFloat) -> CGRect {
    CGRect(x: x, y: y, width: width, height: height)
  }
}

/// An accessibility tree in memory, read the way the shell reads a real one.
final class TestTree: AccessibilityTreeReading {
  private var nodes: [AccessibilityNode] = []
  private var childIDs: [[Int]] = []
  /// Elements that time out, as an app that stopped answering does.
  var silent: (AccessibilityNode) -> Bool = { _ in false }
  private(set) var reads = 0

  @discardableResult
  func add(
    role: String,
    subrole: String? = nil,
    title: String? = nil,
    detail: String? = nil,
    placeholder: String? = nil,
    value: String? = nil,
    enabled: Bool = true,
    focused: Bool = false,
    parent: Int? = nil,
    frame: CGRect
  ) -> Int {
    nodes.append(
      AccessibilityNode(
        role: role, subrole: subrole, title: title, detail: detail, placeholder: placeholder,
        value: value, frame: frame, isEnabled: enabled, isFocused: focused))
    childIDs.append([])
    let id = nodes.count - 1
    if let parent {
      childIDs[parent].append(id)
    }
    return id
  }

  func read(_ element: Int) -> AccessibilityNode? {
    reads += 1
    let node = nodes[element]
    return silent(node) ? nil : node
  }

  func children(of element: Int, limit: Int) -> [Int] {
    Array(childIDs[element].prefix(limit))
  }
}
