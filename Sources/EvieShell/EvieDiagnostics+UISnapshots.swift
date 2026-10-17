import AppKit
import EvieCore
import ScreenCaptureKit
import SwiftUI

/// `--ui-snapshots <pasta>` renders synthetic fixtures in temporary visible
/// windows and captures ONLY each owned window through ScreenCaptureKit.
/// Native Liquid Glass lives in the compositor and cannot be verified with
/// cacheDisplay, which can produce a PNG containing only its backdrop.
/// Requires the app's existing screen-capture permission; it never requests
/// that grant or captures the desktop/personal windows. Fixtures use temporary
/// stores, except the update pane's ordinary GitHub release lookup.
extension EvieDiagnostics {
  private static func makeSnapshotResearchResolver() -> EvieBrainResolver {
    EvieBrainResolver(
      configuration: .builtIn, environment: [:], factory: .live,
      readiness: ModelReadinessCache(probe: ModelClientFactory.live.makeReadinessProbe()),
      localBrain: EvieLocalBrainLauncher())
  }

  private static func makeSnapshotResearchHost(guide: PermissionGuideViewModel) -> ComputerUseHost {
    ComputerUseHost(
      presence: ScreenPresence(), focus: FocusCoordinator(),
      screenPermission: ScreenPermission(guide: guide),
      accessibility: AccessibilityPermission(guide: guide), preferences: { EviePreferences() })
  }

  static func uiSnapshots(directory path: String) async {
    guard CGPreflightScreenCaptureAccess() else {
      print("capturas inválidas: a Evie não tem permissão de Gravação da Tela; nada foi capturado")
      return
    }
    let directory = URL(fileURLWithPath: path, isDirectory: true)
    let scratch = FileManager.default.temporaryDirectory
      .appendingPathComponent("evie-ui-snapshots-\(UUID().uuidString)", isDirectory: true)
    do {
      try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
      try FileManager.default.createDirectory(at: scratch, withIntermediateDirectories: true)
    } catch {
      print("não consegui criar \(directory.path): \(error.localizedDescription)")
      return
    }
    defer { try? FileManager.default.removeItem(at: scratch) }
    NSApp.setActivationPolicy(.accessory)

    let fixtures = UISnapshotFixtures(scratch: scratch)
    for dark in [false, true] {
      let suffix = dark ? "dark" : "light"
      await render(
        BrainControlsView(model: fixtures.brainControls), size: CGSize(width: 330, height: 610),
        dark: dark, titled: false,
        to: directory.appendingPathComponent("brain-controls-\(suffix).png"))
      let research = ResearchModeController(
        brainResolver: makeSnapshotResearchResolver(),
        look: EvieScreenLook(
          capturer: ScreenCaptureService(), indicator: ScreenPresence(),
          permission: ScreenPermission(guide: fixtures.permissions)),
        host: makeSnapshotResearchHost(guide: fixtures.permissions))
      await render(
        ResearchModeView(controller: research), size: CGSize(width: 580, height: 600),
        dark: dark, titled: true,
        to: directory.appendingPathComponent("research-\(suffix).png"))
      research.shutdown()
      await render(
        fixtures.inputBars, size: CGSize(width: 640, height: 470), dark: dark,
        to: directory.appendingPathComponent("overlay-chip-\(suffix).png"))
      await render(
        fixtures.answerCard, size: CGSize(width: 640, height: 300), dark: dark,
        to: directory.appendingPathComponent("answer-card-\(suffix).png"))
      for section in [EvieSettingsSection.screenAndAgent, .general, .filesAndFolders] {
        await render(
          fixtures.settings(on: section), size: CGSize(width: 860, height: 640), dark: dark,
          titled: true,
          to: directory.appendingPathComponent("settings-\(section.rawValue)-\(suffix).png"))
      }
      // The floating sidebar is drawn by the window server, so it does not
      // survive an offscreen capture; its list is drawn alone as well.
      await render(
        HStack(spacing: 0) {
          SettingsSidebar(selection: .constant(.screenAndAgent))
            .frame(width: 220)
          Divider()
          Color(nsColor: .windowBackgroundColor)
        },
        size: CGSize(width: 440, height: 520), dark: dark,
        to: directory.appendingPathComponent("settings-sidebar-\(suffix).png"))
      await render(
        fixtures.settings(on: .screenAndAgent),
        size: SettingsSplitView<EmptyView>.minimumSize, dark: dark, titled: true,
        to: directory.appendingPathComponent("settings-minimum-\(suffix).png"))
    }
  }

  /// Displays synthetic content long enough for native materials to composite,
  /// then captures only that exact owned window. No offscreen bitmap fallback
  /// is accepted as evidence of native-glass rendering.
  private static func render(
    _ view: some View, size: CGSize, dark: Bool, titled: Bool = false, to url: URL
  ) async {
    let window = NSWindow(
      contentRect: CGRect(origin: CGPoint(x: 100, y: 100), size: size),
      styleMask: titled ? [.titled, .closable, .resizable, .fullSizeContentView] : [.borderless],
      backing: .buffered,
      defer: false
    )
    window.isReleasedWhenClosed = false
    window.appearance = NSAppearance(named: dark ? .darkAqua : .aqua)
    let hosting = NSHostingController(rootView: AnyView(view))
    // As in `SettingsWindowController`: the window keeps the size it is given.
    hosting.sizingOptions = [.minSize]
    if titled {
      window.toolbarStyle = .unified
      hosting.sceneBridgingOptions = [.title, .toolbars]
    }
    window.contentViewController = hosting
    window.setContentSize(size)
    window.center()
    // Behind-window AppKit vibrancy must sample synthetic pixels too. A solid
    // owned backdrop keeps any personal desktop/app out of the material input.
    let backdrop = NSWindow(
      contentRect: window.frame.insetBy(dx: -32, dy: -32), styleMask: [.borderless],
      backing: .buffered, defer: false)
    backdrop.isReleasedWhenClosed = false
    backdrop.backgroundColor =
      dark
      ? NSColor(srgbRed: 0.14, green: 0.12, blue: 0.20, alpha: 1)
      : NSColor(srgbRed: 0.86, green: 0.89, blue: 0.95, alpha: 1)
    backdrop.orderFrontRegardless()
    window.order(.above, relativeTo: backdrop.windowNumber)
    defer {
      window.close()
      backdrop.close()
    }
    // The split view and compositor settle over multiple display cycles.
    for _ in 0..<8 {
      window.layoutIfNeeded()
      window.displayIfNeeded()
      try? await Task.sleep(for: .milliseconds(120))
    }
    do {
      let content = try await SCShareableContent.excludingDesktopWindows(
        false, onScreenWindowsOnly: true)
      guard
        let owned = content.windows.first(where: {
          $0.windowID == CGWindowID(window.windowNumber)
            && $0.owningApplication?.processID == ProcessInfo.processInfo.processIdentifier
        })
      else {
        print("sem janela própria; captura inválida: \(url.lastPathComponent)")
        return
      }
      let scale = window.backingScaleFactor
      let configuration = SCStreamConfiguration()
      configuration.width = max(1, Int(owned.frame.width * scale))
      configuration.height = max(1, Int(owned.frame.height * scale))
      configuration.showsCursor = false
      let image = try await SCScreenshotManager.captureImage(
        contentFilter: SCContentFilter(desktopIndependentWindow: owned),
        configuration: configuration)
      guard let png = NSBitmapImageRep(cgImage: image).representation(using: .png, properties: [:])
      else {
        print("sem PNG; captura inválida: \(url.lastPathComponent)")
        return
      }
      try png.write(to: url, options: .atomic)
      print(url.path)
    } catch {
      print("captura inválida \(url.lastPathComponent): \(error.localizedDescription)")
    }
  }
}

/// The models the snapshots draw, over files in `scratch`.
@MainActor
private struct UISnapshotFixtures {
  let preferences: EviePreferencesViewModel
  let permissions: PermissionGuideViewModel
  let roots: EvieRootsViewModel
  let updater = EvieUpdater()

  init(scratch: URL) {
    preferences = EviePreferencesViewModel(
      preferences: EviePreferences(computerUseEnabled: true),
      store: EviePreferencesStore(fileURL: scratch.appendingPathComponent("preferences.json")),
      onChange: { _ in }
    )
    permissions = PermissionGuideViewModel(
      items: [
        FixedPermissionRow(.permission(.microphone, status: .granted, alreadyRequested: true)),
        FixedPermissionRow(.permission(.screenRecording, status: .granted, alreadyRequested: true)),
        FixedPermissionRow(.permission(.accessibility, status: .granted, alreadyRequested: true)),
        FixedPermissionRow(.permission(.postEvents, status: .notGranted, alreadyRequested: false)),
      ],
      store: PermissionGuideStore(fileURL: scratch.appendingPathComponent("guide.json")),
      isBundled: true
    )
    roots = EvieRootsViewModel(
      registry: EvieRootRegistry(fileURL: scratch.appendingPathComponent("roots.json")))
  }

  private static let pc = EvieModelProfileSet.builtIn.preferredProfile
  private static let mac = EvieModelProfileSet.builtIn.profile(id: EvieModelProfile.macProfileID)!

  private func chip(_ chip: EvieBrainChip, choice: EvieBrainChoice = .automatic) -> BrainChipModel {
    BrainChipModel(
      chip: chip,
      menu: EvieBrainMenu(profiles: .builtIn, choice: choice, pinned: nil, next: chip.profile),
      onChoose: { _ in },
      onTestConnection: {},
      onNewConversation: {},
      onSetAgentMode: { _ in },
      onOpenSettings: { _ in }
    )
  }

  /// The input bar once per state the chip can be in.
  var brainControls: BrainChipModel {
    var model = chip(EvieBrainChip(profile: Self.pc, rung: .ready, isAgentModeOn: true))
    model.onSetReasoning = { _ in }
    model.webEnabled = true
    model.onSetWebSearch = { _ in }
    return model
  }

  var inputBars: some View {
    let states: [EvieBrainChip] = [
      EvieBrainChip(profile: Self.pc, rung: .ready),
      EvieBrainChip(profile: Self.pc, rung: .ready, isAgentModeOn: true),
      EvieBrainChip(profile: Self.mac, rung: .modelCold),
      EvieBrainChip(profile: Self.mac, rung: .modelCold, isWaking: true),
      EvieBrainChip(profile: Self.pc, rung: .unreachable),
      EvieBrainChip(profile: Self.pc),
    ]
    return SnapshotBackdrop {
      VStack(spacing: 14) {
        ForEach(Array(states.enumerated()), id: \.offset) { _, state in
          QuickTextEntryView(
            text: .constant(""),
            onSubmit: {},
            onCancel: {},
            onBrowseForFiles: {},
            brainChip: chip(state)
          )
        }
        CommandCapsule(
          state: .ready,
          primaryText: "Evie está pronta",
          secondaryText: "⌥Espaço para conversar",
          brainChip: chip(EvieBrainChip(profile: Self.pc, rung: .ready))
        )
      }
      .frame(width: 516)
    }
  }

  var answerCard: some View {
    SnapshotBackdrop {
      ArtifactCardView(
        artifact: ArtifactCardModel(
          kind: .answer,
          title: "São 14h32 em São Paulo.",
          question: "Que horas são?",
          summary: "São **14h32** em São Paulo, quinta-feira, 16 de outubro.",
          source: "Usei só o que eu já sabia — pode conter erro",
          brainLabel: Self.pc.answerLabel,
          isExpanded: true,
          actions: [
            ArtifactActionModel(id: "copy", title: "Copiar", systemImage: "doc.on.doc"),
            ArtifactActionModel(id: "speak", title: "Ouvir", systemImage: "speaker.wave.2"),
          ]
        ),
        onToggleExpanded: {},
        onDismiss: {},
        readingHeight: 40
      )
      .frame(width: 516)
    }
  }

  func settings(on section: EvieSettingsSection) -> some View {
    SettingsSplitView(selection: .constant(section)) { shown in
      switch shown {
      case .screenAndAgent:
        ScreenAndAgentSettingsView(
          viewModel: preferences,
          permissionGuide: permissions,
          setEnabled: { _ in },
          environment: [:]
        )
      case .general:
        GeneralSettingsView(
          updater: updater, brain: Self.pc, isAgentModeOn: true, open: { _ in })
      case .filesAndFolders:
        FilesAndFoldersSettingsView(rootsViewModel: roots)
      default:
        Text(shown.title)
      }
    }
  }
}

/// A desktop-like ground for the overlay's pieces, which are drawn on glass.
private struct SnapshotBackdrop<Content: View>: View {
  @ViewBuilder var content: Content
  @Environment(\.colorScheme) private var colorScheme

  var body: some View {
    ZStack {
      LinearGradient(
        colors: colorScheme == .dark
          ? [Color(red: 0.10, green: 0.11, blue: 0.16), Color(red: 0.20, green: 0.14, blue: 0.24)]
          : [Color(red: 0.80, green: 0.86, blue: 0.95), Color(red: 0.95, green: 0.88, blue: 0.86)],
        startPoint: .topLeading,
        endPoint: .bottomTrailing
      )
      content
        .padding(30)
    }
  }
}

/// A guide row that always reads the same.
@MainActor
private struct FixedPermissionRow: PermissionGuideItem {
  let fixed: PermissionGuideRow

  init(_ row: PermissionGuideRow) {
    fixed = row
  }

  func row(given record: PermissionGuideRecord) -> PermissionGuideRow {
    fixed
  }

  func perform(_ action: PermissionGuideRow.Action) async -> EviePermission? {
    nil
  }
}
