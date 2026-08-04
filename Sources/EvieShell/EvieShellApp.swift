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

  func applicationDidFinishLaunching(_ notification: Notification) {
    let coordinator = AppCoordinator()
    self.coordinator = coordinator
    coordinator.start()
  }

  func applicationWillTerminate(_ notification: Notification) {
    coordinator?.stop()
    coordinator = nil
  }

  func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
    false
  }
}
