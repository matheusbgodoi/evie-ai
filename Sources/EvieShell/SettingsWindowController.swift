import AppKit
import SwiftUI

@MainActor
final class SettingsWindowController: NSWindowController, NSWindowDelegate {
  private let preferencesViewModel: EviePreferencesViewModel

  init(
    modelViewModel: ModelSettingsViewModel,
    preferencesViewModel: EviePreferencesViewModel,
    rootsViewModel: EvieRootsViewModel,
    voiceLibraryViewModel: EvieVoiceLibraryViewModel,
    preferencesPath: String,
    configurationPath: String
  ) {
    let window = NSWindow(
      contentRect: NSRect(x: 0, y: 0, width: 660, height: 580),
      styleMask: [.titled, .closable, .miniaturizable, .resizable],
      backing: .buffered,
      defer: false
    )
    window.title = "Configurações da Evie"
    window.center()
    window.isReleasedWhenClosed = false
    self.preferencesViewModel = preferencesViewModel
    window.contentViewController = NSHostingController(
      rootView: SettingsView(
        modelViewModel: modelViewModel,
        preferencesViewModel: preferencesViewModel,
        rootsViewModel: rootsViewModel,
        voiceLibraryViewModel: voiceLibraryViewModel,
        preferencesPath: preferencesPath,
        configurationPath: configurationPath
      )
    )
    super.init(window: window)
    window.delegate = self
  }

  @available(*, unavailable)
  required init?(coder: NSCoder) {
    fatalError("init(coder:) has not been implemented")
  }

  /// The shortcut recorder installs a global key monitor while it is capturing.
  /// Closing the window must take it back down.
  func windowWillClose(_ notification: Notification) {
    preferencesViewModel.cancelRecording()
  }

  func present() {
    NSApp.activate(ignoringOtherApps: true)
    showWindow(nil)
    window?.makeKeyAndOrderFront(nil)
  }
}
