import CoreGraphics
import Foundation

/// What to capture and how small to make it.
public struct ScreenCapturePlan: Sendable, Equatable {
  public enum Target: Sendable, Equatable {
    /// One whole display, Evie's own windows left out.
    case display(CGDirectDisplayID)
    /// The frontmost window of another application, on its own.
    case frontWindow
    /// Part of the screen, in global Core Graphics points (S5).
    case region(CGRect)
  }

  public let target: Target
  public let maxLongEdge: Int
  public let jpegQuality: Double

  public init(
    target: Target,
    maxLongEdge: Int = ScreenCapturePlan.longEdge(for: .thisMac),
    jpegQuality: Double = ScreenshotEncoding.jpegQuality
  ) {
    self.target = target
    self.maxLongEdge = maxLongEdge
    self.jpegQuality = jpegQuality
  }

  /// The longer edge a capture is cut to for the brain expected to read it.
  ///
  /// Chosen by measurement (M5 24 GB, macOS 27.2, 2026-10-16; one synthetic
  /// 3024×1964 screen with text at 11–18 pt, `docs/VISION.md`):
  /// - **PC, 1024.** qwen-daily read every 14 pt line exactly at 1024 and at
  ///   1280, and misread a 14 pt name at 768. Its image projector runs on the
  ///   PC's CPU, so the edge is the latency: first token at 11.5 s (768),
  ///   26.0 and 26.2 s (1024), 56.6 s (1280).
  /// - **Mac, 1280.** LensVLM answers in 3–6 s at 1280, so the larger edge
  ///   costs about a second; at 1024 one of two runs misread a 14 pt date.
  public static func longEdge(for location: ModelLocation) -> Int {
    switch location {
    case .yourPC: 1_024
    case .thisMac: 1_280
    }
  }
}

/// One capture, in memory only.
public struct CapturedScreen: Sendable {
  public let image: EvieImagePart
  public let displayID: CGDirectDisplayID
  /// What was captured, in global Core Graphics points: the display's bounds,
  /// or the window's frame.
  public let frameInGlobalCG: CGRect
  /// The size of `image` in pixels, which is what a model's coordinates are
  /// relative to.
  public let imageSize: CGSize
  /// Names this capture, so an action can be refused when it refers to an
  /// older one (S5).
  public let observationID: String
  public let capturedAt: Date

  public init(
    image: EvieImagePart,
    displayID: CGDirectDisplayID,
    frameInGlobalCG: CGRect,
    imageSize: CGSize,
    observationID: String,
    capturedAt: Date
  ) {
    self.image = image
    self.displayID = displayID
    self.frameInGlobalCG = frameInGlobalCG
    self.imageSize = imageSize
    self.observationID = observationID
    self.capturedAt = capturedAt
  }

  /// The frame a model's answer about this capture is mapped back through.
  public var observedFrame: ScreenGeometry.ObservedFrame {
    ScreenGeometry.ObservedFrame(frameInGlobalCG: frameInGlobalCG, imageSize: imageSize)
  }
}

/// Takes screenshots. The shell's is ScreenCaptureKit with Evie's own
/// application excluded; tests use a stub.
@MainActor
public protocol ScreenCapturing: AnyObject {
  /// The display the pointer is on, or `nil` when it is on none.
  func displayUnderPointer() -> CGDirectDisplayID?
  /// The display a capture of `target` shows — for a window, the one that
  /// holds most of it — so the indicator can go there first.
  func display(showing target: ScreenCapturePlan.Target) async throws -> CGDirectDisplayID
  func capture(_ plan: ScreenCapturePlan) async throws -> CapturedScreen
}

/// The "Evie está vendo sua tela" glow, as capture needs it.
@MainActor
public protocol ScreenSeeingIndicator: AnyObject {
  /// Whether an agent session is paused because the person took over. The
  /// glow cannot be shown then, and taking it down is a stop.
  var isPaused: Bool { get }
  /// Returns once the glow is on screen, or has failed to get there.
  func showSeeing(on display: CGDirectDisplayID) async
  /// Whether the glow is composited on `display` now.
  func mayCapture(display: CGDirectDisplayID) -> Bool
  /// Takes the glow down (after its minimum time on screen).
  func endSeeing(succeeded: Bool)
}

/// The Screen Recording permission.
@MainActor
public protocol ScreenCapturePermission: AnyObject {
  /// Whether this process may capture now, without prompting.
  var isGranted: Bool { get }
  /// Whether Evie has already shown the macOS prompt once.
  var wasRequested: Bool { get }
  /// Shows the macOS prompt, records that it was shown, and says whether
  /// capture is allowed afterwards.
  func request() -> Bool
}

/// What to do about the Screen Recording permission before a capture.
///
/// macOS shows its prompt once. After that `CGRequestScreenCaptureAccess`
/// returns at once and shows nothing, so asking a second time would be a
/// question nobody sees; the switch in System Settings is the only way left.
public enum ScreenCaptureAccess: Sendable, Equatable {
  case granted
  case mayAsk
  case openSettings

  public init(isGranted: Bool, wasRequested: Bool) {
    if isGranted {
      self = .granted
    } else {
      self = wasRequested ? .openSettings : .mayAsk
    }
  }
}

public enum EvieScreenLookError: Error, Equatable, Sendable {
  /// Screen Recording is not allowed; the shell shows the settings card.
  case permissionNeeded
  /// The pointer is on no display, or the front window could not be found.
  case noDisplay
  /// The glow did not reach the screen, so nothing was captured.
  case indicatorNotShown
  /// A session is paused while the person uses the Mac; nothing was shown or
  /// captured.
  case presencePaused
  case captureFailed(String)
}

extension EvieScreenLookError: LocalizedError {
  public var errorDescription: String? {
    switch self {
    case .permissionNeeded:
      "A Evie precisa da permissão de Gravação de tela para olhar a tela."
    case .noDisplay:
      "Não encontrei a tela ou a janela para olhar."
    case .indicatorNotShown:
      "Não consegui mostrar o aviso de que estou olhando a tela, então não olhei."
    case .presencePaused:
      "A Evie está pausada enquanto você usa o Mac. Toque em Continuar ou Parar "
        + "e peça de novo para eu olhar a tela."
    case .captureFailed(let reason):
      "Não consegui capturar a tela: \(reason)"
    }
  }
}

/// One look at the screen, in the order the indicator promises: permission,
/// then the glow on the display about to be captured, then the capture, then
/// the glow comes down. No glow, no capture.
///
/// Not during a pause: the presence refuses to draw while the person holds the
/// Mac, and taking down a glow that never came would end — and cancel — the
/// paused session behind it. So a paused presence refuses the look first,
/// before the permission prompt, the glow or the capture.
@MainActor
public struct EvieScreenLook {
  public enum Request: Sendable, Equatable {
    /// The display under the pointer — what "olha a tela" means.
    case screenUnderPointer
    /// The front window — what "nessa janela" means.
    case frontWindow
  }

  let capturer: any ScreenCapturing
  let indicator: any ScreenSeeingIndicator
  let permission: any ScreenCapturePermission

  public init(
    capturer: any ScreenCapturing,
    indicator: any ScreenSeeingIndicator,
    permission: any ScreenCapturePermission
  ) {
    self.capturer = capturer
    self.indicator = indicator
    self.permission = permission
  }

  public func look(_ request: Request, maxLongEdge: Int) async throws -> CapturedScreen {
    guard !indicator.isPaused else {
      throw EvieScreenLookError.presencePaused
    }
    try ensurePermission()

    let target: ScreenCapturePlan.Target
    let display: CGDirectDisplayID
    switch request {
    case .screenUnderPointer:
      guard let pointer = capturer.displayUnderPointer() else {
        throw EvieScreenLookError.noDisplay
      }
      (target, display) = (.display(pointer), pointer)
    case .frontWindow:
      target = .frontWindow
      display = try await capturer.display(showing: .frontWindow)
    }

    await indicator.showSeeing(on: display)
    do {
      try Task.checkCancellation()
      guard indicator.mayCapture(display: display) else {
        throw EvieScreenLookError.indicatorNotShown
      }
      let screen = try await capturer.capture(
        ScreenCapturePlan(target: target, maxLongEdge: maxLongEdge)
      )
      indicator.endSeeing(succeeded: true)
      return screen
    } catch {
      indicator.endSeeing(succeeded: false)
      throw error
    }
  }

  private func ensurePermission() throws {
    switch ScreenCaptureAccess(
      isGranted: permission.isGranted,
      wasRequested: permission.wasRequested
    ) {
    case .granted:
      return
    case .mayAsk:
      guard permission.request() else {
        throw EvieScreenLookError.permissionNeeded
      }
    case .openSettings:
      throw EvieScreenLookError.permissionNeeded
    }
  }
}

/// What the overlay says around a look at the screen.
public enum EvieScreenLookCopy {
  /// The status line while the brain reads the capture, with the first-token
  /// time measured on 2026-10-16 (M5 24 GB, macOS 27.2): qwen-daily on the PC
  /// 26.0–26.2 s for a 1024-pixel screen, its image projector on the PC's CPU;
  /// LensVLM on this Mac 2.9–5.6 s for a 1280-pixel one.
  public static func analysing(on location: ModelLocation) -> String {
    switch location {
    case .yourPC: "Analisando a tela no PC… (~26 s)"
    case .thisMac: "Analisando a tela no Mac… (~5 s)"
    }
  }

  /// The status line once the capture is held for the next question.
  public static let captured = "Tela capturada. Pergunte o que quiser sobre ela."

  public static let permissionTitle = "A Evie precisa ver sua tela"
  public static let permissionSummary =
    "Para olhar a tela, ligue a Evie em Ajustes do Sistema › Privacidade e Segurança › "
    + "Gravação de Tela e Áudio do Sistema, e reabra a Evie depois de permitir: "
    + "o macOS só aplica essa permissão a quem abre de novo."
  /// macOS asks again from time to time whether an app that captures the
  /// screen may keep doing so. Said here so the question is not mistaken for
  /// something Evie did wrong.
  public static let permissionDetail =
    "De tempos em tempos — cerca de uma vez por mês — o macOS pergunta de novo se a Evie "
    + "pode continuar gravando a tela. É o comportamento normal do sistema; responda "
    + "Permitir para ela continuar olhando quando você pedir."
  public static let openSettingsTitle = "Abrir Ajustes"
}
