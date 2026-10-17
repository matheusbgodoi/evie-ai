import AppKit
import EvieCore
import ScreenCaptureKit

/// `evie-shell --presence-excluded`: proves that Evie's own windows are left
/// out of her captures.
///
/// It puts a 4×4 magenta marker in a window of Evie's own, at the presence
/// glow's window level, in the middle of the main display, and captures a
/// 24×24-point square around it twice: once with no exclusion (the control,
/// which must find the marker, or the check proves nothing) and once through
/// `ScreenCaptureService`, the path every look takes, which must not. Only
/// that square is captured, both pictures stay in memory, and nothing is
/// written or sent.
///
/// It never asks for Screen Recording: without the grant it says so and stops,
/// because a diagnostic must not put a consent dialog on someone's screen.
/// `--timing` also times five captures of the whole display under the
/// pointer, and one whole look with the glow, the latency a look adds; those
/// pictures are discarded unread.
@MainActor
enum PresenceExclusionCheck {
  static let markerSide: CGFloat = 4
  static let regionSide: CGFloat = 24

  static func run(timing: Bool) async {
    NSApp.setActivationPolicy(.accessory)
    guard CGPreflightScreenCaptureAccess() else {
      say("sem a permissão de Gravação de tela para este processo; nada foi pedido nem capturado")
      return
    }
    let display = CGMainDisplayID()
    guard let screen = ScreenPresence.screen(for: display),
      let layout = ScreenCaptureService.currentLayout()
    else {
      say("nenhuma tela principal encontrada")
      return
    }

    let marker = NSRect(
      x: screen.frame.midX - markerSide / 2,
      y: screen.frame.midY - markerSide / 2,
      width: markerSide,
      height: markerSide
    )
    let panel = markerPanel(at: marker)
    panel.orderFrontRegardless()
    defer { panel.close() }
    // A few refreshes, so the marker is composited before anything looks.
    try? await Task.sleep(for: .milliseconds(300))

    let region = layout.globalCGRect(fromAppKit: marker)
      .insetBy(dx: -(regionSide - markerSide) / 2, dy: -(regionSide - markerSide) / 2)

    do {
      let control = try await magenta(inUnfilteredCaptureOf: region, display: display)
      say("controle, sem exclusão: \(control) pixels magenta")
      guard control > 0 else {
        say("INCONCLUSIVO: o marcador não apareceu nem sem exclusão")
        return
      }
      let service = ScreenCaptureService()
      let excluded = try await service.capture(
        ScreenCapturePlan(target: .region(region), maxLongEdge: ScreenCapturePlan.longEdge(for: .thisMac))
      )
      let leaked = try ScreenshotEncoding.magentaPixelCount(inJPEG: excluded.image.data)
      say("captura da Evie, com exclusão: \(leaked) pixels magenta")
      say(leaked == 0 ? "PASSOU: as janelas da Evie ficam fora da captura" : "FALHOU: o marcador apareceu")

      if timing {
        await timeDisplayCaptures(service: service)
        await timeLook(service: service)
      }
    } catch {
      say("FALHOU: \(error.localizedDescription)")
    }
  }

  private static func markerPanel(at frame: NSRect) -> NSPanel {
    let panel = NSPanel(
      contentRect: frame,
      styleMask: [.borderless, .nonactivatingPanel],
      backing: .buffered,
      defer: false
    )
    // The presence panels' level and behaviour, so the marker stands in for
    // the glow itself.
    panel.level = .screenSaver
    panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary, .ignoresCycle]
    panel.ignoresMouseEvents = true
    panel.hasShadow = false
    panel.isOpaque = true
    panel.backgroundColor = NSColor(srgbRed: 1, green: 0, blue: 1, alpha: 1)
    return panel
  }

  /// The same square, captured with nothing excluded and encoded the way a
  /// look is, so the two counts compare like with like.
  private static func magenta(inUnfilteredCaptureOf region: CGRect, display id: CGDirectDisplayID) async throws -> Int {
    let content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: true)
    guard let display = content.displays.first(where: { $0.displayID == id }) else {
      throw EvieScreenLookError.noDisplay
    }
    let bounds = CGDisplayBounds(id)
    let configuration = SCStreamConfiguration()
    configuration.sourceRect = region.offsetBy(dx: -bounds.minX, dy: -bounds.minY)
    configuration.width = Int(region.width)
    configuration.height = Int(region.height)
    let image = try await SCScreenshotManager.captureImage(
      contentFilter: SCContentFilter(display: display, excludingWindows: []),
      configuration: configuration
    )
    let part = try ScreenshotEncoding.imagePart(from: image, maxLongEdge: 1_280, origin: .screenshot)
    return try ScreenshotEncoding.magentaPixelCount(inJPEG: part.data)
  }

  /// Five looks at the whole display under the pointer, through the service,
  /// timed from the call to the encoded JPEG. The first pays for listing the
  /// shareable content; the rest reuse it, as a look normally does.
  private static func timeDisplayCaptures(service: ScreenCaptureService) async {
    guard let display = service.displayUnderPointer() else {
      say("tempo: nenhuma tela sob o ponteiro")
      return
    }
    let clock = ContinuousClock()
    for attempt in 1...5 {
      let started = clock.now
      do {
        let screen = try await service.capture(
          ScreenCapturePlan(target: .display(display), maxLongEdge: ScreenCapturePlan.longEdge(for: .yourPC))
        )
        let elapsed = clock.now - started
        say(
          "tempo \(attempt): \(elapsed.formatted(.units(allowed: [.milliseconds], width: .narrow))) "
            + "· \(Int(screen.imageSize.width))×\(Int(screen.imageSize.height)) · \(screen.image.data.count / 1_024) KB"
        )
      } catch {
        say("tempo \(attempt): \(error.localizedDescription)")
      }
    }
  }

  /// One look the way a question takes it: the real glow, composited before
  /// the capture, through `EvieScreenLook`. The permission is only read, never
  /// asked for.
  private static func timeLook(service: ScreenCaptureService) async {
    let presence = ScreenPresence(usesEscapeKey: false)
    let look = EvieScreenLook(
      capturer: service,
      indicator: presence,
      permission: PreflightOnly()
    )
    let clock = ContinuousClock()
    let started = clock.now
    do {
      let screen = try await look.look(.screenUnderPointer, maxLongEdge: ScreenCapturePlan.longEdge(for: .yourPC))
      let elapsed = clock.now - started
      say(
        "olhar completo, com o brilho: \(elapsed.formatted(.units(allowed: [.milliseconds], width: .narrow))) "
          + "· \(Int(screen.imageSize.width))×\(Int(screen.imageSize.height))"
      )
    } catch {
      say("olhar completo: \(error.localizedDescription)")
    }
    // The glow's minimum time on screen, so it is not cut off by the exit.
    try? await Task.sleep(for: .seconds(1))
  }

  /// Reads the grant and never shows the prompt.
  private final class PreflightOnly: ScreenCapturePermission {
    var isGranted: Bool { CGPreflightScreenCaptureAccess() }
    var wasRequested: Bool { true }
    func request() -> Bool { isGranted }
  }

  private static func say(_ line: String) {
    print("presence-excluded: \(line)")
  }
}
