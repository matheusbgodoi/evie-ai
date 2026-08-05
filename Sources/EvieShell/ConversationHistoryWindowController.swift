import AppKit
import SwiftUI

@MainActor
final class ConversationHistoryWindowController: NSWindowController {
  private let historyViewModel: ConversationHistoryViewModel

  init(viewModel: ConversationHistoryViewModel) {
    historyViewModel = viewModel
    let window = NSWindow(
      contentRect: NSRect(x: 0, y: 0, width: 860, height: 620),
      styleMask: [.titled, .closable, .miniaturizable, .resizable],
      backing: .buffered,
      defer: false
    )
    window.title = "Histórico da Evie"
    window.center()
    window.isReleasedWhenClosed = false
    window.contentViewController = NSHostingController(
      rootView: ConversationHistoryView(viewModel: viewModel)
    )
    super.init(window: window)
  }

  @available(*, unavailable)
  required init?(coder: NSCoder) {
    fatalError("init(coder:) has not been implemented")
  }

  func present() {
    historyViewModel.refresh()
    NSApp.activate(ignoringOtherApps: true)
    showWindow(nil)
    window?.makeKeyAndOrderFront(nil)
  }
}
