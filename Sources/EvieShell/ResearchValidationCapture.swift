import AppKit
import EvieCore
import ScreenCaptureKit

/// Captures only the fixture window by PID and bundle. Even if focus changes
/// during an await, no personal app pixels can enter the diagnostic model call.
@MainActor
final class ResearchValidationCapture: ScreenCapturing {
  private let processID: Int32
  private let locator = ComputerScreenLocator()

  init(processID: Int32) { self.processID = processID }

  func displayUnderPointer() -> CGDirectDisplayID? { locator.displayUnderPointer() }

  func display(showing target: ScreenCapturePlan.Target) async throws -> CGDirectDisplayID {
    let window = try await fixtureWindow()
    return try display(for: window.frame)
  }

  func capture(_ plan: ScreenCapturePlan) async throws -> CapturedScreen {
    let window = try await fixtureWindow()
    let config = SCStreamConfiguration()
    config.width = max(1, Int(window.frame.width))
    config.height = max(1, Int(window.frame.height))
    config.showsCursor = false
    let image = try await SCScreenshotManager.captureImage(
      contentFilter: SCContentFilter(desktopIndependentWindow: window), configuration: config)
    let part = try ScreenshotEncoding.imagePart(
      from: image, maxLongEdge: plan.maxLongEdge, quality: plan.jpegQuality, origin: .screenshot)
    return CapturedScreen(
      image: part, displayID: try display(for: window.frame), frameInGlobalCG: window.frame,
      imageSize: part.pixelSize, observationID: UUID().uuidString, capturedAt: Date())
  }

  private func fixtureWindow() async throws -> SCWindow {
    guard NSWorkspace.shared.frontmostApplication?.processIdentifier == processID else {
      throw ResearchValidation.Failure.stopped("A fixture perdeu o foco antes da captura.")
    }
    let content = try await SCShareableContent.excludingDesktopWindows(
      false, onScreenWindowsOnly: true)
    guard
      let window = content.windows.first(where: {
        $0.owningApplication?.processID == processID
          && $0.owningApplication?.bundleIdentifier == ResearchValidation.bundleID
          && $0.windowLayer == 0 && ($0.title?.hasPrefix("Evie Research Fixture") == true)
      })
    else {
      throw ResearchValidation.Failure.stopped("Janela sintética não encontrada; nada capturado.")
    }
    return window
  }

  private func display(for frame: CGRect) throws -> CGDirectDisplayID {
    guard let display = locator.display(containing: CGPoint(x: frame.midX, y: frame.midY)) else {
      throw EvieScreenLookError.noDisplay
    }
    return display
  }
}
