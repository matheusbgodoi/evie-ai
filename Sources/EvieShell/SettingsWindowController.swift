import AppKit
import EvieCore
import SwiftUI

@MainActor
final class SettingsWindowController: NSWindowController, NSWindowDelegate {
  private let preferencesViewModel: EviePreferencesViewModel
  private let navigation = SettingsNavigation()

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
    permissionGuide: PermissionGuideViewModel,
    preferencesPath: String,
    configurationPath: String
  ) {
    // No minimise button: a settings window is a modeless companion to the app,
    // not a document, and macOS draws its minimise button greyed out for exactly
    // that reason. Resizable stays, because the folder, memory and voice lists
    // are genuinely long and a fixed height would clip them. Full-size content
    // with a unified toolbar is System Settings' shape: the sidebar runs up
    // under the traffic lights and the section's name is the window's title.
    let window = NSWindow(
      contentRect: NSRect(origin: .zero, size: Self.defaultContentSize),
      styleMask: [.titled, .closable, .resizable, .fullSizeContentView],
      backing: .buffered,
      defer: false
    )
    window.title = "Configurações da Evie"
    window.toolbarStyle = .unified
    window.isReleasedWhenClosed = false
    self.preferencesViewModel = preferencesViewModel
    let hosting = NSHostingController(
      rootView: SettingsView(
        navigation: navigation,
        modelViewModel: modelViewModel,
        preferencesViewModel: preferencesViewModel,
        rootsViewModel: rootsViewModel,
        voiceLibraryViewModel: voiceLibraryViewModel,
        memoryViewModel: memoryViewModel,
        skillsViewModel: skillsViewModel,
        updater: updater,
        wakeListener: wakeListener,
        schedulesViewModel: schedulesViewModel,
        permissionGuide: permissionGuide,
        preferencesPath: preferencesPath,
        configurationPath: configurationPath
      )
    )
    // The section's `navigationTitle` becomes the window's title, and the
    // split view's toolbar the window's.
    hosting.sceneBridgingOptions = [.title, .toolbars]
    // The window keeps the size it was given or restored to; SwiftUI only
    // sets how small it may get.
    hosting.sizingOptions = [.minSize]
    window.contentViewController = hosting
    window.contentMinSize = SettingsSplitView<EmptyView>.minimumSize
    super.init(window: window)
    window.delegate = self
    // Where the user last dragged this window is where they expect to find it
    // next time. Without an autosave name it re-centres on every open, which is
    // the one thing a settings window should never do to someone who moved it.
    // Set after `super.init` so AppKit restores the saved frame rather than
    // having it overwritten by the contentRect above.
    window.setFrameAutosaveName("EvieSettingsWindow")
    // A frame saved by the tabbed window (660 × 580) is narrower than the
    // sidebar needs: grow it once to the default rather than open it cramped.
    let restored = window.contentRect(forFrameRect: window.frame).size
    let minimum = SettingsSplitView<EmptyView>.minimumSize
    if restored.width < minimum.width || restored.height < minimum.height {
      window.setContentSize(Self.defaultContentSize)
    }
    if window.frame.origin == .zero {
      window.center()
    }
  }

  static let defaultContentSize = CGSize(width: 860, height: 640)

  @available(*, unavailable)
  required init?(coder: NSCoder) {
    fatalError("init(coder:) has not been implemented")
  }

  /// The shortcut recorder installs a global key monitor while it is capturing.
  /// Closing the window must take it back down.
  func windowWillClose(_ notification: Notification) {
    preferencesViewModel.cancelRecording()
  }

  /// Shows the window, on `section` when one is given.
  func present(section: EvieSettingsSection? = nil) {
    if let section {
      navigation.section = section
    }
    NSApp.activate(ignoringOtherApps: true)
    showWindow(nil)
    window?.makeKeyAndOrderFront(nil)
  }
}
