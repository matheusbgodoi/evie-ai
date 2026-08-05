import AppKit
import SwiftUI

@MainActor
final class SettingsWindowController: NSWindowController {
  init(viewModel: ModelSettingsViewModel) {
    let window = NSWindow(
      contentRect: NSRect(x: 0, y: 0, width: 660, height: 580),
      styleMask: [.titled, .closable, .miniaturizable, .resizable],
      backing: .buffered,
      defer: false
    )
    window.title = "Configurações da Evie"
    window.center()
    window.isReleasedWhenClosed = false
    window.contentViewController = NSHostingController(
      rootView: SettingsView(viewModel: viewModel)
    )
    super.init(window: window)
  }

  @available(*, unavailable)
  required init?(coder: NSCoder) {
    fatalError("init(coder:) has not been implemented")
  }

  func present() {
    NSApp.activate(ignoringOtherApps: true)
    showWindow(nil)
    window?.makeKeyAndOrderFront(nil)
  }
}
