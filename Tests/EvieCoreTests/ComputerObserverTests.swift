import CoreGraphics
import Foundation
import Testing

@testable import EvieCore

@Suite("Computer observer")
@MainActor
struct ComputerObserverTests {
  /// Two displays side by side; Notas has its window on the right one, and
  /// the pointer is on the left one.
  @MainActor
  final class Rig {
    var journal: [String] = []
    let left = CGRect(x: 0, y: 0, width: 1_512, height: 982)
    let right = CGRect(x: 1_512, y: 0, width: 1_920, height: 1_080)
    let notes = ComputerAppIdentity(bundleID: "com.apple.Notes", name: "Notas", processID: 42)
    lazy var capturer = Capturer(rig: self)
    lazy var locator = Locator(rig: self)
    lazy var accessibility = Reader(rig: self)
    lazy var indicator = Indicator(rig: self)
    lazy var permission = Permission(rig: self)

    func observer() -> ComputerObserver {
      ComputerObserver(
        capturer: capturer, locator: locator, accessibility: accessibility, indicator: indicator,
        screenPermission: permission, now: { Date(timeIntervalSince1970: 1) })
    }
  }

  static func request(
    _ target: ComputerToolRequest.LookTarget = .screen,
    image: Bool = true
  ) -> ComputerObservationRequest {
    ComputerObservationRequest(target: target, withImage: image, step: 3, maxLongEdge: 1_024)
  }

  @Test("the glow comes first, then the capture, then the list")
  func order() async throws {
    let rig = Rig()

    let observation = try await rig.observer().observe(Self.request())

    #expect(rig.journal == ["show 2 step 3", "capture display 2", "snapshot 42"])
    #expect(observation.id == "obs-1")
    #expect(observation.image != nil)
    #expect(observation.frontApp == rig.notes)
    #expect(observation.elements.map(\.title) == ["Nova nota"])
    #expect(observation.evieWindowFrames == [CGRect(x: 10, y: 10, width: 300, height: 200)])
  }

  @Test("the observation carries the window server's list, for the policy")
  func carriesTheWindowList() async throws {
    let rig = Rig()

    let observation = try await rig.observer().observe(Self.request(image: false))

    #expect(observation.windows == rig.locator.windowList)
    #expect(rig.locator.windowsRead == 1)
  }

  @Test("without a glow the window list is not read either")
  func noGlowNoWindowList() async {
    let rig = Rig()
    rig.indicator.composites = false

    await #expect(throws: EvieScreenLookError.indicatorNotShown) {
      try await rig.observer().observe(Self.request())
    }
    #expect(rig.locator.windowsRead == 0)
  }

  @Test("the screen is the display holding the front window, not the one under the pointer")
  func displayOfTheWindow() async throws {
    let rig = Rig()

    let observation = try await rig.observer().observe(Self.request())

    #expect(observation.displayID == 2)
    #expect(observation.frame.frameInGlobalCG == rig.right)
  }

  @Test("without a glow on screen nothing is captured or read")
  func noGlowNoObservation() async {
    let rig = Rig()
    rig.indicator.composites = false

    await #expect(throws: EvieScreenLookError.indicatorNotShown) {
      try await rig.observer().observe(Self.request())
    }
    #expect(rig.journal == ["show 2 step 3"])
  }

  @Test("a paused session observes nothing and shows nothing")
  func paused() async {
    let rig = Rig()
    rig.indicator.isPaused = true

    await #expect(throws: EvieScreenLookError.presencePaused) {
      try await rig.observer().observe(Self.request())
    }
    #expect(rig.journal.isEmpty)
  }

  @Test("without Accessibility nothing is observed")
  func untrusted() async {
    let rig = Rig()
    rig.accessibility.trusted = false

    await #expect(throws: ComputerObservationError.accessibilityNeeded) {
      try await rig.observer().observe(Self.request(image: false))
    }
    #expect(rig.journal.isEmpty)
  }

  @Test("a picture without Screen Recording is refused, and no prompt is shown")
  func noScreenRecording() async throws {
    let rig = Rig()
    rig.permission.isGranted = false

    await #expect(throws: EvieScreenLookError.permissionNeeded) {
      try await rig.observer().observe(Self.request())
    }
    #expect(rig.journal.isEmpty)

    // The list alone needs no Screen Recording.
    let listed = try await rig.observer().observe(Self.request(image: false))
    #expect(listed.image == nil)
  }

  @Test("a list-only observation captures nothing and keeps the frame a capture would have")
  func listOnly() async throws {
    let rig = Rig()

    let observation = try await rig.observer().observe(Self.request(image: false))

    #expect(rig.journal == ["show 2 step 3", "snapshot 42"])
    #expect(observation.image == nil)
    #expect(observation.frame.frameInGlobalCG == rig.right)
    #expect(observation.frame.imageSize == CGSize(width: 1_024, height: 576))
  }

  @Test("the front window is captured as its region, cut to its display")
  func frontWindow() async throws {
    let rig = Rig()
    rig.locator.window = CGRect(x: 3_000, y: 100, width: 600, height: 400)

    let observation = try await rig.observer().observe(Self.request(.frontWindow))

    let region = CGRect(x: 3_000, y: 100, width: 432, height: 400)
    #expect(rig.capturer.plans.map(\.target) == [.region(region)])
    #expect(observation.frame.frameInGlobalCG == region)
    #expect(rig.accessibility.frames.first?.frameInGlobalCG == region)
  }

  @Test("with Evie in front, her own windows are never listed")
  func evieInFront() async throws {
    let rig = Rig()
    rig.locator.app = ComputerAppIdentity(
      bundleID: ComputerActionPolicy.evieBundleID, name: "Evie", processID: 7)

    let observation = try await rig.observer().observe(Self.request(image: false))

    #expect(observation.elements.isEmpty)
    #expect(!rig.journal.contains { $0.hasPrefix("snapshot") })
  }

  @Test("every observation has a new id")
  func newIDs() async throws {
    let rig = Rig()
    let observer = rig.observer()

    let first = try await observer.observe(Self.request())
    let second = try await observer.observe(Self.request(image: false))

    #expect([first.id, second.id] == ["obs-1", "obs-2"])
  }

  @Test("the live state is read now: the front app, secure input, a password field in focus")
  func liveState() async {
    let rig = Rig()
    rig.locator.secureInput = true
    rig.accessibility.focusedSecure = true

    let live = await rig.observer().liveState()

    #expect(live == ComputerLiveState(frontApp: rig.notes, secureInputEnabled: true, focusedFieldIsSecure: true))
  }

  // MARK: - Stubs

  @MainActor
  final class Capturer: ScreenCapturing {
    unowned let rig: Rig
    private(set) var plans: [ScreenCapturePlan] = []

    init(rig: Rig) {
      self.rig = rig
    }

    func displayUnderPointer() -> CGDirectDisplayID? { 1 }

    func display(showing target: ScreenCapturePlan.Target) async throws -> CGDirectDisplayID { 2 }

    func capture(_ plan: ScreenCapturePlan) async throws -> CapturedScreen {
      plans.append(plan)
      let frame: CGRect
      switch plan.target {
      case .display(let id):
        rig.journal.append("capture display \(id)")
        frame = id == 2 ? rig.right : rig.left
      case .region(let rect):
        rig.journal.append("capture region")
        frame = rect
      case .frontWindow:
        rig.journal.append("capture window")
        frame = rig.right
      }
      let size = ScreenGeometry.downscaledSize(frame.size, maxLongEdge: plan.maxLongEdge)
      return CapturedScreen(
        image: EvieImagePart(mimeType: "image/jpeg", data: Data([1]), pixelSize: size, origin: .screenshot),
        displayID: 2, frameInGlobalCG: frame, imageSize: size, observationID: "x",
        capturedAt: Date(timeIntervalSince1970: 0))
    }
  }

  @MainActor
  final class Locator: ComputerScreenLocating {
    unowned let rig: Rig
    lazy var app: ComputerAppIdentity? = rig.notes
    var window: CGRect? = CGRect(x: 1_700, y: 100, width: 800, height: 600)
    var secureInput = false

    init(rig: Rig) {
      self.rig = rig
    }

    func frontApp() -> ComputerAppIdentity? { app }
    func displayUnderPointer() -> CGDirectDisplayID? { 1 }

    func displayFrame(_ display: CGDirectDisplayID) -> CGRect? {
      display == 2 ? rig.right : rig.left
    }

    func display(containing point: CGPoint) -> CGDirectDisplayID? {
      rig.right.contains(point) ? 2 : rig.left.contains(point) ? 1 : nil
    }

    func frontWindowFrame(ofProcess processID: Int32) -> CGRect? { window }
    func evieWindowFrames() -> [CGRect] { [CGRect(x: 10, y: 10, width: 300, height: 200)] }
    func windowOwner(at point: CGPoint) -> Int32? { app?.processID }
    lazy var windowList: [ComputerWindowSummary] = [
      ComputerWindowSummary(
        owner: ComputerAppIdentity(bundleID: "com.apple.dock", name: "Dock", processID: 7),
        frame: CGRect(x: 0, y: 900, width: 1_512, height: 82), layer: 20),
      ComputerWindowSummary(owner: rig.notes, frame: window ?? .zero, layer: 0),
    ]
    private(set) var windowsRead = 0
    func windows() -> [ComputerWindowSummary] {
      windowsRead += 1
      return windowList
    }
    func secureInputEnabled() -> Bool { secureInput }
  }

  @MainActor
  final class Reader: AccessibilityReading {
    unowned let rig: Rig
    nonisolated(unsafe) var trusted = true
    var focusedSecure = false
    private(set) var frames: [ScreenGeometry.ObservedFrame] = []

    init(rig: Rig) {
      self.rig = rig
    }

    nonisolated var isTrusted: Bool { trusted }

    func snapshot(
      ofProcess processID: Int32,
      within frame: ScreenGeometry.ObservedFrame
    ) async -> AccessibilitySnapshot {
      rig.journal.append("snapshot \(processID)")
      frames.append(frame)
      return AccessibilitySnapshot(
        windowTitle: "Notas",
        elements: [
          AXElementSummary(
            index: 0, role: "AXButton", title: "Nova nota",
            box0to1000: CGRect(x: 10, y: 10, width: 40, height: 20), isSecure: false)
        ])
    }

    func focusedElementIsSecure(ofProcess processID: Int32) async -> Bool { focusedSecure }
  }

  @MainActor
  final class Indicator: ComputerObservingIndicator {
    unowned let rig: Rig
    var composites = true
    var isPaused = false
    private var shownOn: CGDirectDisplayID?

    init(rig: Rig) {
      self.rig = rig
    }

    func showObserving(on display: CGDirectDisplayID, step: Int) async {
      rig.journal.append("show \(display) step \(step)")
      shownOn = composites ? display : nil
    }

    func mayCapture(display: CGDirectDisplayID) -> Bool { shownOn == display }

    func endObserving(succeeded: Bool) {
      rig.journal.append("end \(succeeded)")
    }
  }

  @MainActor
  final class Permission: ScreenCapturePermission {
    unowned let rig: Rig
    var isGranted = true
    var wasRequested = true

    init(rig: Rig) {
      self.rig = rig
    }

    func request() -> Bool {
      rig.journal.append("prompt")
      return false
    }
  }
}
