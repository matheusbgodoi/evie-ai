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
    memoryViewModel: EvieMemoryViewModel,
    skillsViewModel: EvieSkillsViewModel,
    updater: EvieUpdater,
    wakeListener: EvieWakeListener,
    schedulesViewModel: EvieSchedulesViewModel,
    preferencesPath: String,
    configurationPath: String
  ) {
    // No minimise button: a settings window is a modeless companion to the app,
    // not a document, and macOS draws its minimise button greyed out for exactly
    // that reason. Resizable stays, because the folder, memory and voice lists
    // are genuinely long and a fixed height would clip them.
    let window = NSWindow(
      contentRect: NSRect(x: 0, y: 0, width: 660, height: 580),
      styleMask: [.titled, .closable, .resizable],
      backing: .buffered,
      defer: false
    )
    window.title = "Configurações da Evie"
    window.isReleasedWhenClosed = false
    self.preferencesViewModel = preferencesViewModel
    window.contentViewController = NSHostingController(
      rootView: SettingsView(
        modelViewModel: modelViewModel,
        preferencesViewModel: preferencesViewModel,
        rootsViewModel: rootsViewModel,
        voiceLibraryViewModel: voiceLibraryViewModel,
        memoryViewModel: memoryViewModel,
        skillsViewModel: skillsViewModel,
        updater: updater,
        wakeListener: wakeListener,
        schedulesViewModel: schedulesViewModel,
        preferencesPath: preferencesPath,
        configurationPath: configurationPath
      )
    )
    super.init(window: window)
    window.delegate = self
    // Where the user last dragged this window is where they expect to find it
    // next time. Without an autosave name it re-centres on every open, which is
    // the one thing a settings window should never do to someone who moved it.
    // Set after `super.init` so AppKit restores the saved frame rather than
    // having it overwritten by the contentRect above.
    window.setFrameAutosaveName("EvieSettingsWindow")
    if window.frame.origin == .zero {
      window.center()
    }
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
