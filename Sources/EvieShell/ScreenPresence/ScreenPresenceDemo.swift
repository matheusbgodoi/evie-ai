import AppKit
import EvieCore

/// `evie-shell --presence-demo`: plays every state of the screen indicator on
/// the main display, in the order an agent session would reach them, so the
/// indicator can be reviewed without a model, a capture or a single synthetic
/// event.
///
/// It captures nothing and posts nothing. It never starts the coordinator,
/// so it asks for no microphone, speech or screen-recording permission. It
/// leaves Esc alone unless `--with-esc` is given — the demo is usually run on
/// a Mac someone is using — so the esc keycap shows only then. Parar ends the
/// demo the way it ends a session, and so does Esc when it is taken.
///
/// Each state holds for `hold` seconds (2 by default), and each step prints a
/// line, so a script can take a screenshot at the right moment.
@MainActor
enum ScreenPresenceDemo {
  static func run(hold: Double, reducedMotion: Bool, takesEscape: Bool) async {
    PresenceMotion.forcesReducedMotion = reducedMotion
    NSApp.setActivationPolicy(.accessory)
    let presence = ScreenPresence(usesEscapeKey: takesEscape)
    presence.brainLocation = "no PC"
    presence.stepBudget = 25
    var stopped = false
    presence.onStop = {
      stopped = true
      say("parado pelo usuário")
    }

    let display = CGMainDisplayID()
    guard let screen = ScreenPresence.screen(for: display) else {
      say("nenhuma tela principal encontrada")
      return
    }
    let size = screen.frame.size
    // Stand-ins for what an agent would look at: a toolbar button near the
    // top right, a send button lower down, and a text field.
    let toolbarButton = CGRect(x: size.width * 0.68, y: size.height * 0.16, width: 96, height: 28)
    let document = CGRect(x: size.width * 0.18, y: size.height * 0.28, width: size.width * 0.34, height: size.height * 0.36)
    let sendButton = CGRect(x: size.width * 0.62, y: size.height * 0.62, width: 88, height: 30)
    let field = CGRect(x: size.width * 0.22, y: size.height * 0.74, width: size.width * 0.36, height: 30)
    func rect(_ r: CGRect) -> ScreenPresence.ScreenRect { .init(displayID: display, rect: r) }
    func pause(_ seconds: Double) async { try? await Task.sleep(for: .seconds(seconds)) }

    say("seeing")
    await presence.show(.seeing(displays: [display]))
    say("seeing composited, mayCapture=\(presence.mayCapture(display: display))")
    await pause(0.3)
    say("seeing sweep")
    await pause(hold)
    presence.hide(outcome: .success)
    await pause(1.2)

    say("observing")
    await presence.show(.observing(displays: [display], step: 1))
    presence.lookAt(rect(document))
    await pause(hold)
    if stopped { return await finish() }
    say("observing lookAt")
    presence.lookAt(rect(toolbarButton))
    await pause(0.18)
    // Redirected mid-flight, from wherever the reticle is.
    say("observing redirect")
    presence.lookAt(rect(sendButton))
    await pause(hold)
    if stopped { return await finish() }

    say("acting")
    await presence.show(.acting(display))
    presence.lookAt(rect(sendButton))
    let target = ScreenPresence.ScreenPoint(displayID: display, x: sendButton.midX, y: sendButton.midY)
    let clearance = await presence.willClick(target, label: "Enviar")
    say("willClick → \(clearance)")
    if clearance == .proceed {
      say("didClick")
      presence.didClick(at: target)
    }
    await pause(hold)
    if stopped { return await finish() }

    say("typing")
    presence.typing(field: rect(field), app: "Notas")
    await pause(hold)
    if stopped { return await finish() }
    say("clipboard")
    presence.clipboardNotice()
    await pause(hold)
    if stopped { return await finish() }

    say("paused")
    await presence.show(.paused(reason: ""))
    await pause(hold)
    if stopped { return await finish() }

    // Stands in for the user pressing Continuar.
    say("resumed")
    presence.resume()
    await pause(hold)
    if stopped { return await finish() }

    say("success")
    presence.hide(outcome: .success)
    await pause(1.6)

    say("stop")
    await presence.show(.observing(displays: [display], step: 4))
    await pause(hold / 2)
    presence.stop()
    await finish()
  }

  /// Waits out the last exit, then reports how many windows are still on
  /// screen: the indicator's promise for idle is zero.
  private static func finish() async {
    try? await Task.sleep(for: .seconds(1.6))
    let visible = NSApp.windows.filter(\.isVisible).count
    say("fim, janelas visíveis: \(visible)")
  }

  private static func say(_ line: String) {
    print("presence-demo: \(line)")
    fflush(stdout)
  }
}
