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
    // Diagnostics that must not require launching a window. `--print-persona`
    // exists so the exact hidden instructions Evie receives can be reviewed
    // without reading them out of a running conversation.
    if CommandLine.arguments.contains("--print-persona") {
      print(EviePersona.evie.systemPrompt(capabilities: .textOnly))
      NSApp.terminate(nil)
      return
    }

    let coordinator = AppCoordinator()
    self.coordinator = coordinator
    coordinator.start()
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
