import AppKit
import EvieCore
import ScreenCaptureKit

/// Takes Evie's screenshots with ScreenCaptureKit.
///
/// Every capture leaves Evie's own windows out — the overlay, the presence
/// glow and pill, any settings window — through the content filter, not
/// through `NSWindow.sharingType`, which a window can lose and a new panel can
/// forget to set.
///
/// The filter names her windows (`SCContentFilter(display:excludingWindows:)`),
/// found by process id in a window list read right before each capture —
/// after the glow's panels were created for it. Excluding her *application*
/// instead was measured leaving them in: on 2026-10-16 (macOS 27.2) a bare
/// `swift build` binary is listed under its responsible app (Terminal) and
/// `excludingApplications:` with that entry still captured 8 of the marker's
/// 9 magenta pixels, while `excludingWindows:` captured none
/// (`evie-shell --presence-excluded`).
///
/// The picture never touches disk: the `CGImage` ScreenCaptureKit returns is
/// downscaled and encoded to JPEG in memory (`ScreenshotEncoding`), and only
/// the resulting `EvieImagePart` leaves this type.
@MainActor
final class ScreenCaptureService: ScreenCapturing {
  enum CaptureError: LocalizedError {
    case displayNotShareable(CGDirectDisplayID)
    case noFrontWindow

    var errorDescription: String? {
      switch self {
      case .displayNotShareable:
        "essa tela não está disponível para captura."
      case .noFrontWindow:
        "não há uma janela de outro app na frente."
      }
    }
  }

  // MARK: - ScreenCapturing

  func displayUnderPointer() -> CGDirectDisplayID? {
    guard let pointer = CGEvent(source: nil)?.location else {
      return nil
    }
    return Self.currentLayout()?.display(containingGlobalCG: pointer)?.id
  }

  func display(showing target: ScreenCapturePlan.Target) async throws -> CGDirectDisplayID {
    let frame: CGRect
    switch target {
    case .display(let id):
      return id
    case .frontWindow:
      frame = try await frontWindow().frame
    case .region(let rect):
      frame = rect
    }
    let centre = CGPoint(x: frame.midX, y: frame.midY)
    guard let display = Self.currentLayout()?.display(containingGlobalCG: centre) else {
      throw EvieScreenLookError.noDisplay
    }
    return display.id
  }

  func capture(_ plan: ScreenCapturePlan) async throws -> CapturedScreen {
    let filter: SCContentFilter
    let displayID: CGDirectDisplayID
    let frame: CGRect
    let configuration = SCStreamConfiguration()
    configuration.showsCursor = true

    switch plan.target {
    case .display(let id):
      filter = try await filterLeavingEvieOut(of: id)
      displayID = id
      frame = CGDisplayBounds(id)

    case .frontWindow:
      let window = try await frontWindow()
      filter = SCContentFilter(desktopIndependentWindow: window)
      frame = window.frame
      guard
        let holder = Self.currentLayout()?.display(
          containingGlobalCG: CGPoint(x: frame.midX, y: frame.midY))
      else {
        throw EvieScreenLookError.noDisplay
      }
      displayID = holder.id

    case .region(let rect):
      guard let holder = Self.currentLayout()?.display(
        containingGlobalCG: CGPoint(x: rect.midX, y: rect.midY))
      else {
        throw EvieScreenLookError.noDisplay
      }
      filter = try await filterLeavingEvieOut(of: holder.id)
      // `sourceRect` is in the display's own points, top-left origin.
      let bounds = CGDisplayBounds(holder.id)
      frame = rect.intersection(bounds)
      configuration.sourceRect = frame.offsetBy(dx: -bounds.minX, dy: -bounds.minY)
      displayID = holder.id
    }

    // One pixel per point: what a non-Retina display of the same size would
    // show. The encoder then cuts it to the plan's edge.
    configuration.width = max(1, Int(frame.width.rounded()))
    configuration.height = max(1, Int(frame.height.rounded()))

    let image: CGImage
    do {
      image = try await SCScreenshotManager.captureImage(
        contentFilter: filter,
        configuration: configuration
      )
    } catch {
      throw EvieScreenLookError.captureFailed(error.localizedDescription)
    }
    let part = try ScreenshotEncoding.imagePart(
      from: image,
      maxLongEdge: plan.maxLongEdge,
      quality: plan.jpegQuality,
      origin: .screenshot
    )
    return CapturedScreen(
      image: part,
      displayID: displayID,
      frameInGlobalCG: frame,
      imageSize: part.pixelSize,
      observationID: UUID().uuidString,
      capturedAt: Date()
    )
  }

  // MARK: - What can be captured

  /// What can be captured, read for every look rather than cached: the
  /// exclusion names Evie's windows, and the glow's panels are created for the
  /// look itself. A whole capture, listing included, took 44–49 ms on
  /// 2026-10-16 (M5, macOS 27.2; `evie-shell --presence-excluded --timing`).
  private func content() async throws -> SCShareableContent {
    do {
      return try await SCShareableContent.excludingDesktopWindows(
        false,
        onScreenWindowsOnly: true
      )
    } catch {
      throw EvieScreenLookError.captureFailed(error.localizedDescription)
    }
  }

  /// The whole display minus every window Evie has on screen now. The list is
  /// read fresh: the glow's panels exist only since this look began.
  private func filterLeavingEvieOut(of id: CGDirectDisplayID) async throws -> SCContentFilter {
    let content = try await content()
    guard let display = content.displays.first(where: { $0.displayID == id }) else {
      throw EvieScreenLookError.captureFailed(
        CaptureError.displayNotShareable(id).localizedDescription)
    }
    let pid = ProcessInfo.processInfo.processIdentifier
    return SCContentFilter(
      display: display,
      excludingWindows: content.windows.filter { $0.owningApplication?.processID == pid }
    )
  }

  /// The frontmost normal window that is not Evie's: the first layer-0 window
  /// in the window server's front-to-back order. `SCShareableContent` does not
  /// promise an order, so the window list picks it and ScreenCaptureKit
  /// supplies the window to capture.
  private func frontWindow() async throws -> SCWindow {
    guard let windowID = Self.frontWindowID() else {
      throw EvieScreenLookError.captureFailed(CaptureError.noFrontWindow.localizedDescription)
    }
    if let window = try await content().windows.first(where: {
      $0.windowID == windowID
    }) {
      return window
    }
    throw EvieScreenLookError.captureFailed(CaptureError.noFrontWindow.localizedDescription)
  }

  private static func frontWindowID() -> CGWindowID? {
    let pid = ProcessInfo.processInfo.processIdentifier
    guard
      let windows = CGWindowListCopyWindowInfo(
        [.optionOnScreenOnly, .excludeDesktopElements],
        kCGNullWindowID
      ) as? [[CFString: Any]]
    else {
      return nil
    }
    for window in windows {
      guard (window[kCGWindowLayer] as? Int) == 0,
        let owner = window[kCGWindowOwnerPID] as? pid_t, owner != pid,
        (window[kCGWindowAlpha] as? Double ?? 1) > 0,
        let number = window[kCGWindowNumber] as? CGWindowID
      else {
        continue
      }
      return number
    }
    return nil
  }

  /// The connected displays as `ScreenGeometry` describes them.
  static func currentLayout() -> ScreenGeometry.Layout? {
    var count: UInt32 = 0
    guard CGGetActiveDisplayList(0, nil, &count) == .success, count > 0 else {
      return nil
    }
    var ids = [CGDirectDisplayID](repeating: 0, count: Int(count))
    guard CGGetActiveDisplayList(count, &ids, &count) == .success else {
      return nil
    }
    let displays = ids.prefix(Int(count)).map { id in
      let bounds = CGDisplayBounds(id)
      let pixels = CGDisplayCopyDisplayMode(id).map { CGFloat($0.pixelWidth) } ?? bounds.width
      return ScreenGeometry.Display(
        id: id,
        frameInGlobalCG: bounds,
        backingScale: bounds.width > 0 ? pixels / bounds.width : 1
      )
    }
    return ScreenGeometry.Layout(displays: Array(displays))
  }
}
