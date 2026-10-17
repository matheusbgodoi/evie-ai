import AppKit
import EvieCore
import SwiftUI

/// `--ui-snapshots <pasta>`: draws the brain chip, an answer card and the
/// settings window offscreen, in light and dark, and writes each as a PNG.
///
/// It exists so a change to these views can be looked at without launching
/// the app or touching anyone's screen. Nothing is put on screen: every view
/// is drawn into a window that is never ordered in. Every model is built
/// from scratch over files in a temporary folder — no preference, folder
/// grant, key or permission of the person running it is read or written —
/// except the update pane, which may ask GitHub for the latest release as it
/// does when Settings opens. Translucent materials are drawn without what is
/// behind them, so the glass reads flatter than it does on a desktop.
extension EvieDiagnostics {
  static func uiSnapshots(directory path: String) async {
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
    NSApp.setActivationPolicy(.prohibited)

    let fixtures = UISnapshotFixtures(scratch: scratch)
    for dark in [false, true] {
      let suffix = dark ? "dark" : "light"
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

  /// Draws `view` at `size` into a window that is never shown, after letting
  /// SwiftUI settle for a moment, and writes it as a PNG.
  private static func render(
    _ view: some View, size: CGSize, dark: Bool, titled: Bool = false, to url: URL
  ) async {
    let window = NSWindow(
      contentRect: CGRect(origin: CGPoint(x: -20_000, y: -20_000), size: size),
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
    let target = window.contentView?.superview ?? hosting.view
    // A window that is never ordered in gets no display cycles of its own,
    // and the split view sizes its columns over several: run a few by hand.
    for _ in 0..<8 {
      window.layoutIfNeeded()
      window.displayIfNeeded()
      try? await Task.sleep(for: .milliseconds(120))
    }
    guard let bitmap = target.bitmapImageRepForCachingDisplay(in: target.bounds) else {
      print("sem imagem: \(url.lastPathComponent)")
      return
    }
    target.cacheDisplay(in: target.bounds, to: bitmap)
    do {
      try bitmap.representation(using: .png, properties: [:])?.write(to: url)
      print(url.path)
    } catch {
      print("não consegui gravar \(url.lastPathComponent): \(error.localizedDescription)")
    }
    window.close()
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
