import AppKit

/// Exercises only this process's review windows and a private notification
/// center. It invokes the real button action handler directly, not AX/button
/// wiring. The confirm callback increments a counter; it never captures pixels.
@main
@MainActor
struct NativeCaptureConsentValidation {
  private struct Failure: Error, CustomStringConvertible {
    let description: String
  }

  static func main() {
    let app = NSApplication.shared
    app.setActivationPolicy(.accessory)
    let previous = NSWorkspace.shared.frontmostApplication
    Task { @MainActor in
      do {
        try validate()
        previous?.activate()
        print(
          "PASS: own-window capture consent lifecycle; no capture, model, URL launch or OS notification posted."
        )
        app.terminate(nil)
      } catch {
        previous?.activate()
        FileHandle.standardError.write(Data("FAIL: \(error)\n".utf8))
        exit(1)
      }
    }
    app.run()
  }

  private static func require(_ condition: Bool, _ description: String) throws {
    guard condition else { throw Failure(description: description) }
  }

  private static func validate() throws {
    let center = NotificationCenter()
    let controller = NativeCaptureConsentController(notificationCenter: center)
    defer { controller.shutdown() }
    var confirms = 0
    var dismissals: [Bool] = []
    func present() {
      controller.present(
        onConfirm: { confirms += 1 },
        onDismiss: { dismissals.append($0) })
    }

    present()
    try require(confirms == 0 && controller.isPresented, "Present must not authorize capture.")
    controller.confirm()
    try require(
      confirms == 1 && !controller.isPresented, "Confirm must close and invoke exactly once.")
    controller.confirm()
    try require(confirms == 1, "A stale confirmed button must not authorize again.")

    present()
    controller.dismiss()
    controller.confirm()
    try require(confirms == 1 && !controller.isPresented, "Cancel must clear confirmation.")
    try require(dismissals.last == true, "Cancel must report normal dismissal.")

    present()
    try window().performClose(nil)
    controller.confirm()
    try require(
      confirms == 1 && !controller.isPresented, "Closing the window must clear confirmation.")

    present()
    controller.dismiss(resumingListening: false)
    controller.confirm()
    try require(
      confirms == 1 && dismissals.last == false, "Emergency dismissal must revoke without resuming."
    )

    for (name, label) in [
      (NSWorkspace.willSleepNotification, "sleep"),
      (NSWorkspace.sessionDidResignActiveNotification, "session"),
    ] {
      present()
      let before = confirms
      // Deliberately no await/yield between notification delivery and the
      // queued action: invalidation must complete inside the observer callback.
      center.post(name: name, object: nil)
      controller.confirm()
      try require(
        confirms == before && !controller.isPresented,
        "\(label) invalidation admitted a stale confirmation.")
      try require(dismissals.last == false, "\(label) must not resume wake listening.")
    }

    present()
    controller.shutdown()
    controller.confirm()
    try require(confirms == 1 && !controller.isPresented, "Shutdown must clear confirmation.")
    center.post(name: NSWorkspace.willSleepNotification, object: nil)
    try require(confirms == 1, "Shutdown must remove notification callbacks.")
  }

  private static func window() throws -> NSWindow {
    guard
      let window = NSApp.windows.first(where: {
        $0.identifier?.rawValue == "evie-native-capture-consent" && $0.isVisible
      })
    else { throw Failure(description: "The review window is missing.") }
    return window
  }

}
