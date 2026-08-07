import EvieCore
import SwiftUI

@main
struct EvieShellApp: App {
  @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate

  var body: some Scene {
    Settings {
      EmptyView()
    }
  }
}

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
  private var coordinator: AppCoordinator?
  private var terminationTask: Task<Void, Never>?
  private var terminationPrepared = false

  func applicationDidFinishLaunching(_ notification: Notification) {
    // Every diagnostic runs before anything is put on screen, because most of
    // them measure something a window would disturb — and because the ones that
    // print are meant to be read from a terminal, not from behind an overlay.
    // What each flag is and what it does lives in EvieDiagnosticRegistry.
    if let match = EvieDiagnosticRegistry.match(CommandLine.arguments), let run = match.diagnostic.run {
      run(match.arguments, self)
      return
    }

    let coordinator = AppCoordinator()
    self.coordinator = coordinator
    coordinator.start()
  }

  /// Takes ownership of a coordinator a diagnostic built for itself.
  ///
  /// `--presentation-check` drives the real overlay, which means the real
  /// coordinator has to stay alive for the length of the check and be torn down
  /// on termination exactly as a normal launch would tear it down.
  func retain(_ coordinator: AppCoordinator) {
    self.coordinator = coordinator
  }

  func applicationWillTerminate(_ notification: Notification) {
    coordinator?.stop()
    coordinator = nil
  }

  func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
    if terminationPrepared || coordinator == nil {
      return .terminateNow
    }
    guard terminationTask == nil, let coordinator else {
      return .terminateLater
    }

    terminationTask = Task { @MainActor [weak self] in
      await coordinator.prepareForTermination()
      guard let self else { return }
      terminationPrepared = true
      terminationTask = nil
      sender.reply(toApplicationShouldTerminate: true)
    }
    return .terminateLater
  }

  func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
    false
  }
}
