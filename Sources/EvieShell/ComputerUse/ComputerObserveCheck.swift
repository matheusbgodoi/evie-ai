import AppKit
import EvieCore

/// `evie-shell --cu-observe [segundos] [--tela]`: one computer-use observation
/// of the front app, printed the way the model would read it.
///
/// It goes through the real observer — the observing glow on the display,
/// then the accessibility list — but never captures pixels: it is given no
/// Screen Recording at all, so a picture could not be taken even by mistake,
/// and it asks for no permission (without Accessibility it says so and
/// stops). It posts no event and leaves Esc alone. The delay gives the person
/// time to bring the app they want to look at to the front.
@MainActor
enum ComputerObserveCheck {
  static func run(delay: Double, wholeScreen: Bool) async {
    let accessibility = AccessibilitySnapshotter()
    guard accessibility.isTrusted else {
      say(
        "Este processo não tem a permissão de Acessibilidade, então não lê os elementos de outros "
          + "apps. Nada foi pedido: ligue-a em Ajustes do Sistema › Privacidade e Segurança › "
          + "Acessibilidade para o app que roda este comando.")
      return
    }
    NSApp.setActivationPolicy(.accessory)
    if delay > 0 {
      say("Lendo o app da frente em \(delay) s…")
      try? await Task.sleep(for: .seconds(delay))
    }

    let presence = ScreenPresence(usesEscapeKey: false)
    let locator = ComputerScreenLocator()
    let observer = ComputerObserver(
      capturer: ScreenCaptureService(),
      locator: locator,
      accessibility: accessibility,
      indicator: presence,
      screenPermission: NoScreenRecording()
    )
    let clock = ContinuousClock()
    let start = clock.now
    do {
      let observation = try await observer.observe(
        ComputerObservationRequest(
          target: wholeScreen ? .screen : .frontWindow,
          withImage: false,
          step: 0,
          maxLongEdge: ScreenCapturePlan.longEdge(for: .yourPC)
        ))
      let observed = clock.now - start

      // The same walk again, alone, for what the observation does not keep.
      let walkStart = clock.now
      let walk = await accessibility.snapshot(
        ofProcess: observation.frontApp.processID, within: observation.frame)
      let walked = clock.now - walkStart

      let app = observation.frontApp
      say("app: \(app.name) (\(app.bundleID ?? "sem bundle"), pid \(app.processID))")
      say("área observada: \(observation.frame.frameInGlobalCG) pontos, tela \(observation.displayID)")
      say(
        "elementos: \(observation.elements.count), lidos \(walk.visitedNodes)"
          + (walk.endedEarly ? ", lista cortada por um limite" : ""))
      say(
        "observação com o brilho: \(milliseconds(observed)) ms; só a leitura: "
          + "\(milliseconds(walked)) ms")
      say("")
      print(ObservationFormatter.format(observation, step: nil, convention: .normalized1000))
      await observer.endObserving(succeeded: true)
    } catch {
      say("Não consegui observar: \(error.localizedDescription)")
      await observer.endObserving(succeeded: false)
    }
    // Lets the glow fade before the process quits.
    try? await Task.sleep(for: .seconds(1.2))
  }

  private static func milliseconds(_ duration: Duration) -> Int {
    Int((Double(duration.components.seconds) * 1_000
      + Double(duration.components.attoseconds) / 1e15).rounded())
  }

  private static func say(_ line: String) {
    print(line)
    fflush(stdout)
  }
}

/// Screen Recording as the command-line checks hold it: never granted, never
/// asked, so they read the accessibility list and never capture pixels.
@MainActor
final class NoScreenRecording: ScreenCapturePermission {
  var isGranted: Bool { false }
  var wasRequested: Bool { true }

  func request() -> Bool {
    false
  }
}
