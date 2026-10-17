import CoreGraphics
import Foundation

/// One observation the computer-use loop asks for.
public struct ComputerObservationRequest: Sendable, Equatable {
  /// The display that holds the front window, or that window alone.
  public var target: ComputerToolRequest.LookTarget
  /// Whether this observation carries a picture. Without one it is the
  /// accessibility list only: no capture is taken.
  public var withImage: Bool
  /// The step shown on the pill ("passo 3/25").
  public var step: Int
  /// The picture's longer edge, for the brain that reads it
  /// (`ScreenCapturePlan.longEdge(for:)`).
  public var maxLongEdge: Int

  public init(
    target: ComputerToolRequest.LookTarget,
    withImage: Bool,
    step: Int,
    maxLongEdge: Int
  ) {
    self.target = target
    self.withImage = withImage
    self.step = step
    self.maxLongEdge = maxLongEdge
  }
}

/// The observing half of computer use: what the loop needs to see the screen.
/// `EvieComputerActing` adds the acting half (S5c).
public protocol EvieComputerObserving: Sendable {
  func observe(_ request: ComputerObservationRequest) async throws -> ComputerObservation
  /// What holds at this moment, read just before an action is judged.
  func liveState() async -> ComputerLiveState
  /// Takes the observing glow down when the session is over.
  func endObserving(succeeded: Bool) async
}

/// The "Evie está olhando" glow between agent steps, as observation needs it.
@MainActor
public protocol ComputerObservingIndicator: AnyObject {
  /// Whether the session is paused because the person took over. Nothing is
  /// observed then, and taking the glow down would be a stop.
  var isPaused: Bool { get }
  /// Returns once the observing glow is on `display`, or failed to get there.
  func showObserving(on display: CGDirectDisplayID, step: Int) async
  func mayCapture(display: CGDirectDisplayID) -> Bool
  func endObserving(succeeded: Bool)
}

/// Where things are on the screen right now, as the window server says.
@MainActor
public protocol ComputerScreenLocating: AnyObject {
  /// `NSWorkspace.frontmostApplication`.
  func frontApp() -> ComputerAppIdentity?
  func displayUnderPointer() -> CGDirectDisplayID?
  /// The display's bounds in global Core Graphics points.
  func displayFrame(_ display: CGDirectDisplayID) -> CGRect?
  func display(containing point: CGPoint) -> CGDirectDisplayID?
  /// The frontmost normal window of that process, in global points.
  func frontWindowFrame(ofProcess processID: Int32) -> CGRect?
  /// Every window of Evie's on screen that a click can land on, in global
  /// points.
  func evieWindowFrames() -> [CGRect]
  /// The process owning the frontmost window under `point` (Evie's own
  /// windows passed over), or `nil` when no window is there.
  func windowOwner(at point: CGPoint) -> Int32?
  /// Every visible window on screen, front to back, Evie's own passed over,
  /// with the app that owns it (`ComputerObservation.windows`).
  func windows() -> [ComputerWindowSummary]
  /// `IsSecureEventInputEnabled()`.
  func secureInputEnabled() -> Bool
}

/// The front app's accessibility tree, read off the main thread.
public protocol AccessibilityReading: Sendable {
  /// `AXIsProcessTrusted()`: whether Evie may read other apps' elements.
  var isTrusted: Bool { get }
  /// The process's focused window, listed against `frame`.
  func snapshot(
    ofProcess processID: Int32,
    within frame: ScreenGeometry.ObservedFrame
  ) async -> AccessibilitySnapshot
  /// Whether the process's focused element is a password field.
  func focusedElementIsSecure(ofProcess processID: Int32) async -> Bool
}

public enum ComputerObservationError: Error, Equatable, Sendable {
  /// Evie is not trusted for Accessibility, so she cannot tell a password
  /// field from any other and does not observe at all.
  case accessibilityNeeded
  /// No application is in front.
  case noFrontApp
  /// The front app has no window on any display.
  case noWindow
}

extension ComputerObservationError: LocalizedError {
  public var errorDescription: String? {
    switch self {
    case .accessibilityNeeded:
      "A Evie precisa da permissão de Acessibilidade para olhar e controlar o Mac."
    case .noFrontApp:
      "Não há nenhum app na frente para olhar."
    case .noWindow:
      "O app da frente não tem uma janela na tela."
    }
  }
}

/// One observation for the computer-use loop, in the order the indicator
/// promises: the observing glow on the display about to be read, then the
/// capture when the step needs pixels, then the accessibility list, with a
/// new observation id. No glow, no observation — the list is the screen's
/// content as much as the picture is, so it is never read unannounced either.
///
/// The model's coordinates are mapped back through the frame recorded here.
/// For a step without a picture it is the frame a capture would have used,
/// with the image size the capture would have had, so a pixel answer about
/// the last picture still lands where it meant.
@MainActor
public final class ComputerObserver: EvieComputerObserving {
  private let capturer: any ScreenCapturing
  private let locator: any ComputerScreenLocating
  private let accessibility: any AccessibilityReading
  private let indicator: any ComputerObservingIndicator
  private let screenPermission: any ScreenCapturePermission
  private let now: () -> Date
  private var count = 0

  public init(
    capturer: any ScreenCapturing,
    locator: any ComputerScreenLocating,
    accessibility: any AccessibilityReading,
    indicator: any ComputerObservingIndicator,
    screenPermission: any ScreenCapturePermission,
    now: @escaping () -> Date = Date.init
  ) {
    self.capturer = capturer
    self.locator = locator
    self.accessibility = accessibility
    self.indicator = indicator
    self.screenPermission = screenPermission
    self.now = now
  }

  /// Never prompts: the session's start (S5d) asks for the permissions, so
  /// a prompt cannot appear in the middle of a session or at launch.
  public func observe(_ request: ComputerObservationRequest) async throws -> ComputerObservation {
    guard !indicator.isPaused else {
      throw EvieScreenLookError.presencePaused
    }
    guard accessibility.isTrusted else {
      throw ComputerObservationError.accessibilityNeeded
    }
    if request.withImage, !screenPermission.isGranted {
      throw EvieScreenLookError.permissionNeeded
    }
    guard let app = locator.frontApp() else {
      throw ComputerObservationError.noFrontApp
    }
    let windowFrame = locator.frontWindowFrame(ofProcess: app.processID)
    let (display, region) = try place(of: request.target, window: windowFrame)

    await indicator.showObserving(on: display, step: request.step)
    try Task.checkCancellation()
    guard indicator.mayCapture(display: display) else {
      throw EvieScreenLookError.indicatorNotShown
    }

    let frame: ScreenGeometry.ObservedFrame
    var image: EvieImagePart?
    if request.withImage {
      let plan = ScreenCapturePlan(
        target: request.target == .frontWindow ? .region(region) : .display(display),
        maxLongEdge: request.maxLongEdge
      )
      let captured = try await capturer.capture(plan)
      frame = captured.observedFrame
      image = captured.image
    } else {
      frame = ScreenGeometry.ObservedFrame(
        frameInGlobalCG: region,
        imageSize: ScreenGeometry.downscaledSize(region.size, maxLongEdge: request.maxLongEdge)
      )
    }

    // Evie's own windows are never listed: the capture leaves them out, and
    // the policy refuses her in front.
    let snapshot =
      app.bundleID == ComputerActionPolicy.evieBundleID
      ? AccessibilitySnapshot()
      : await accessibility.snapshot(ofProcess: app.processID, within: frame)
    try Task.checkCancellation()

    count += 1
    return ComputerObservation(
      id: "obs-\(count)",
      capturedAt: now(),
      displayID: display,
      frame: frame,
      frontApp: app,
      windowTitle: snapshot.windowTitle,
      elements: snapshot.elements,
      focusedElementIndex: snapshot.focusedElementIndex,
      evieWindowFrames: locator.evieWindowFrames(),
      windowFrame: windowFrame,
      windows: locator.windows(),
      image: image
    )
  }

  public func liveState() async -> ComputerLiveState {
    let app = locator.frontApp()
    let secureInput = locator.secureInputEnabled()
    let focusedSecure =
      if let app {
        await accessibility.focusedElementIsSecure(ofProcess: app.processID)
      } else {
        false
      }
    return ComputerLiveState(
      frontApp: app,
      secureInputEnabled: secureInput,
      focusedFieldIsSecure: focusedSecure
    )
  }

  public func endObserving(succeeded: Bool) async {
    indicator.endObserving(succeeded: succeeded)
  }

  /// The display to glow on and the region observed, in global points.
  ///
  /// The screen is the display holding the front app's window — the list is
  /// that window's, so a display without it would list nothing — or, with no
  /// window, the one under the pointer. A window is cut to its display, as
  /// the capture cuts it.
  private func place(
    of target: ComputerToolRequest.LookTarget,
    window: CGRect?
  ) throws -> (CGDirectDisplayID, CGRect) {
    let holder = window.flatMap { locator.display(containing: CGPoint(x: $0.midX, y: $0.midY)) }
    switch target {
    case .screen:
      guard let display = holder ?? locator.displayUnderPointer(),
        let bounds = locator.displayFrame(display)
      else {
        throw EvieScreenLookError.noDisplay
      }
      return (display, bounds)
    case .frontWindow:
      guard let window, let holder, let bounds = locator.displayFrame(holder) else {
        throw ComputerObservationError.noWindow
      }
      let visible = window.intersection(bounds)
      guard !visible.isNull, !visible.isEmpty else {
        throw ComputerObservationError.noWindow
      }
      return (holder, visible)
    }
  }
}
