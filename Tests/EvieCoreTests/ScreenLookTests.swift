import CoreGraphics
import Foundation
import Testing

@testable import EvieCore

/// Records every call in order, so a test can say what happened before what.
@MainActor
private final class Journal {
  var entries: [String] = []
}

@MainActor
private final class StubCapturer: ScreenCapturing {
  let journal: Journal
  var pointerDisplay: CGDirectDisplayID? = 1
  var windowDisplay: CGDirectDisplayID = 2
  var failure: (any Error)?
  private(set) var plans: [ScreenCapturePlan] = []

  init(journal: Journal) {
    self.journal = journal
  }

  func displayUnderPointer() -> CGDirectDisplayID? {
    pointerDisplay
  }

  func display(showing target: ScreenCapturePlan.Target) async throws -> CGDirectDisplayID {
    switch target {
    case .display(let id): id
    case .frontWindow, .region: windowDisplay
    }
  }

  func capture(_ plan: ScreenCapturePlan) async throws -> CapturedScreen {
    journal.entries.append("capture")
    plans.append(plan)
    if let failure {
      throw failure
    }
    return CapturedScreen(
      image: EvieImagePart(
        mimeType: "image/jpeg",
        data: Data([0xFF, 0xD8]),
        pixelSize: CGSize(width: 1_024, height: 665),
        origin: .screenshot
      ),
      displayID: 1,
      frameInGlobalCG: CGRect(x: 0, y: 0, width: 1_512, height: 982),
      imageSize: CGSize(width: 1_024, height: 665),
      observationID: "obs-1",
      capturedAt: Date(timeIntervalSince1970: 0)
    )
  }
}

@MainActor
private final class StubIndicator: ScreenSeeingIndicator {
  let journal: Journal
  /// Whether the glow manages to be composited on the display it is shown on.
  var composites = true
  private var shownOn: CGDirectDisplayID?

  init(journal: Journal) {
    self.journal = journal
  }

  func showSeeing(on display: CGDirectDisplayID) async {
    journal.entries.append("show \(display)")
    shownOn = composites ? display : nil
  }

  func mayCapture(display: CGDirectDisplayID) -> Bool {
    shownOn == display
  }

  func endSeeing(succeeded: Bool) {
    journal.entries.append(succeeded ? "hide ok" : "hide failed")
    shownOn = nil
  }
}

@MainActor
private final class StubPermission: ScreenCapturePermission {
  let journal: Journal
  var isGranted: Bool
  var wasRequested: Bool
  /// What the system prompt answers.
  var grantsWhenAsked = false

  init(journal: Journal, granted: Bool, requested: Bool = false) {
    self.journal = journal
    isGranted = granted
    wasRequested = requested
  }

  func request() -> Bool {
    journal.entries.append("request")
    wasRequested = true
    isGranted = grantsWhenAsked
    return isGranted
  }
}

@MainActor
@Suite("Screen look")
struct ScreenLookTests {
  private let journal = Journal()

  private func look(
    _ request: EvieScreenLook.Request = .screenUnderPointer,
    capturer: StubCapturer? = nil,
    indicator: StubIndicator? = nil,
    permission: StubPermission? = nil
  ) async throws -> CapturedScreen {
    try await EvieScreenLook(
      capturer: capturer ?? StubCapturer(journal: journal),
      indicator: indicator ?? StubIndicator(journal: journal),
      permission: permission ?? StubPermission(journal: journal, granted: true)
    ).look(request, maxLongEdge: 1_024)
  }

  @Test("the glow is on the captured display before the capture, and ends after it")
  func indicatorBracketsTheCapture() async throws {
    let screen = try await look()

    #expect(journal.entries == ["show 1", "capture", "hide ok"])
    #expect(screen.observationID == "obs-1")
  }

  @Test("the display under the pointer is the one captured, at the edge asked for")
  func capturesThePointerDisplay() async throws {
    let capturer = StubCapturer(journal: journal)
    capturer.pointerDisplay = 7

    _ = try await look(capturer: capturer)

    #expect(capturer.plans == [ScreenCapturePlan(target: .display(7), maxLongEdge: 1_024)])
    #expect(journal.entries.first == "show 7")
  }

  @Test("a window is captured with the glow on the display that holds it")
  func windowRequestShowsItsDisplay() async throws {
    let capturer = StubCapturer(journal: journal)
    capturer.windowDisplay = 3

    _ = try await look(.frontWindow, capturer: capturer)

    #expect(capturer.plans.map(\.target) == [.frontWindow])
    #expect(journal.entries == ["show 3", "capture", "hide ok"])
  }

  @Test("when the glow cannot be shown there is no capture")
  func noIndicatorNoCapture() async {
    let indicator = StubIndicator(journal: journal)
    indicator.composites = false

    await #expect(throws: EvieScreenLookError.indicatorNotShown) {
      _ = try await look(indicator: indicator)
    }
    #expect(!journal.entries.contains("capture"))
    #expect(journal.entries.last == "hide failed")
  }

  @Test("a failed capture still takes the glow down")
  func failedCaptureEndsTheGlow() async {
    let capturer = StubCapturer(journal: journal)
    capturer.failure = EvieScreenLookError.captureFailed("SCK")

    await #expect(throws: EvieScreenLookError.captureFailed("SCK")) {
      _ = try await look(capturer: capturer)
    }
    #expect(journal.entries == ["show 1", "capture", "hide failed"])
  }

  @Test("with no display under the pointer nothing is shown or captured")
  func noDisplay() async {
    let capturer = StubCapturer(journal: journal)
    capturer.pointerDisplay = nil

    await #expect(throws: EvieScreenLookError.noDisplay) {
      _ = try await look(capturer: capturer)
    }
    #expect(journal.entries.isEmpty)
  }

  @Test("the permission is asked for once, then the capture goes ahead if granted")
  func asksOnceAndProceeds() async throws {
    let permission = StubPermission(journal: journal, granted: false)
    permission.grantsWhenAsked = true

    _ = try await look(permission: permission)

    #expect(journal.entries == ["request", "show 1", "capture", "hide ok"])
  }

  @Test("a refused prompt ends in the settings card, with nothing shown or captured")
  func refusedPromptNeedsSettings() async {
    let permission = StubPermission(journal: journal, granted: false)

    await #expect(throws: EvieScreenLookError.permissionNeeded) {
      _ = try await look(permission: permission)
    }
    #expect(journal.entries == ["request"])
  }

  @Test("once asked, the prompt is never shown again: the card is")
  func neverAsksTwice() async {
    let permission = StubPermission(journal: journal, granted: false, requested: true)

    await #expect(throws: EvieScreenLookError.permissionNeeded) {
      _ = try await look(permission: permission)
    }
    #expect(journal.entries.isEmpty)
  }

  @Test("the access decision follows the grant and whether it was asked for")
  func accessDecision() {
    #expect(ScreenCaptureAccess(isGranted: true, wasRequested: false) == .granted)
    #expect(ScreenCaptureAccess(isGranted: true, wasRequested: true) == .granted)
    #expect(ScreenCaptureAccess(isGranted: false, wasRequested: false) == .mayAsk)
    #expect(ScreenCaptureAccess(isGranted: false, wasRequested: true) == .openSettings)
  }

  @Test("a capture is cut to the PC's measured edge and the Mac's")
  func longEdgeFollowsTheBrain() {
    #expect(ScreenCapturePlan.longEdge(for: .yourPC) == 1_024)
    #expect(ScreenCapturePlan.longEdge(for: .thisMac) == 1_280)
  }

  @Test("the wait for a look names the brain and its measured time")
  func analysingCopy() {
    #expect(EvieScreenLookCopy.analysing(on: .yourPC) == "Analisando a tela no PC… (~26 s)")
    #expect(EvieScreenLookCopy.analysing(on: .thisMac) == "Analisando a tela no Mac… (~5 s)")
  }

  @Test("the permission card points at the right pane and says to reopen Evie")
  func permissionCardCopy() {
    #expect(EvieScreenLookCopy.permissionSummary.contains("Gravação de Tela e Áudio do Sistema"))
    #expect(EvieScreenLookCopy.permissionSummary.contains("reabra a Evie depois de permitir"))
    #expect(EvieScreenLookCopy.permissionDetail.contains("uma vez por mês"))
    #expect(EvieScreenLookCopy.openSettingsTitle == "Abrir Ajustes")
  }

  @Test("the captured frame maps the model's answers back to the screen")
  func capturedFrameIsTheObservedFrame() async throws {
    let screen = try await look()

    let frame = screen.observedFrame
    #expect(frame.frameInGlobalCG == CGRect(x: 0, y: 0, width: 1_512, height: 982))
    #expect(frame.imageSize == CGSize(width: 1_024, height: 665))
  }
}
