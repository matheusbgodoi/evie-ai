import AppKit
import SwiftUI

/// The window the guide opens in on first launch.
///
/// Closing it either way — the button or the title bar — counts as having
/// seen it, so it does not reopen by itself; Settings keeps the same list.
@MainActor
final class PermissionGuideWindowController: NSWindowController, NSWindowDelegate {
  private let viewModel: PermissionGuideViewModel

  init(viewModel: PermissionGuideViewModel, folders: EvieRootsViewModel? = nil) {
    self.viewModel = viewModel
    let window = NSWindow(
      contentRect: NSRect(x: 0, y: 0, width: 560, height: 680),
      styleMask: [.titled, .closable, .resizable],
      backing: .buffered,
      defer: false
    )
    window.title = "Primeiros passos com a Evie"
    window.isReleasedWhenClosed = false
    super.init(window: window)
    window.contentViewController = NSHostingController(
      rootView: PermissionGuideView(viewModel: viewModel, folders: folders) { [weak self] in
        self?.close()
      }
    )
    window.delegate = self
    window.center()
  }

  @available(*, unavailable)
  required init?(coder: NSCoder) {
    fatalError("init(coder:) has not been implemented")
  }

  func windowWillClose(_ notification: Notification) {
    viewModel.markDismissed()
  }

  func present() {
    viewModel.refresh()
    NSApp.activate(ignoringOtherApps: true)
    showWindow(nil)
    window?.makeKeyAndOrderFront(nil)
  }
}
