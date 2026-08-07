import AppKit
import EvieCore
import Foundation

/// The folders Evie is allowed to look in, and the only place they are granted.
///
/// A folder becomes reachable exactly one way: the user picks it in the system's
/// own open panel. Evie cannot propose one, a document cannot ask for one, and
/// nothing in a model's answer can add one — the panel is drawn by macOS, and the
/// only thing that reaches this type is the choice a person made in it.
@MainActor
final class EvieRootsViewModel: ObservableObject {
  @Published private(set) var roots: [EvieFileRoot] = []
  @Published private(set) var feedback: Feedback?
  /// Called whenever the set changes, so Evie's own idea of what she can reach
  /// changes with it rather than at the next launch.
  var onChange: (@MainActor ([EvieFileRoot]) -> Void)?
  /// Reads and writes the two switches that decide whether she may change a file
  /// at all, and whether a change needs a click. They live in preferences rather
  /// than in the registry, but they belong on this screen: they are about the
  /// same folders.
  var canChangeFiles = false
  var autoApprovesChanges = false
  var onPolicyChanged: (@MainActor (_ canChange: Bool, _ autoApprove: Bool) -> Void)?

  func setCanChangeFiles(_ enabled: Bool) {
    canChangeFiles = enabled
    if !enabled {
      autoApprovesChanges = false
    }
    onPolicyChanged?(canChangeFiles, autoApprovesChanges)
    objectWillChange.send()
  }

  func setAutoApprovesChanges(_ enabled: Bool) {
    autoApprovesChanges = enabled
    onPolicyChanged?(canChangeFiles, autoApprovesChanges)
    objectWillChange.send()
  }

  private let registry: EvieRootRegistry

  init(registry: EvieRootRegistry = EvieRootRegistry()) {
    self.registry = registry
    roots = registry.load()
  }

  struct Feedback: Equatable {
    var message: String
    var isError: Bool
  }

  /// Whether a folder is missing right now — an external disk unplugged, or a
  /// folder renamed. Shown so a grant that has stopped working says so rather
  /// than producing puzzling failures mid-answer.
  func isReachable(_ root: EvieFileRoot) -> Bool {
    var isDirectory: ObjCBool = false
    let exists = FileManager.default.fileExists(
      atPath: root.path,
      isDirectory: &isDirectory
    )
    return exists && isDirectory.boolValue
  }

  func displayPath(for root: EvieFileRoot) -> String {
    (root.path as NSString).abbreviatingWithTildeInPath
  }

  /// Asks for a folder, through the system panel.
  ///
  /// Attached to the window that asked, as a sheet, rather than run
  /// application-modal. Evie has no Dock icon — `NSApp.setActivationPolicy`
  /// is `.accessory` — and an app in that mode has no reliable way back to a
  /// window it lost: no Dock tile, no entry in the app switcher, nothing but the
  /// menu-bar item. `runModal()` takes over activation for the whole application
  /// and hands it back to whatever the system thinks is frontmost, which for an
  /// accessory app is regularly not the settings window. It looks exactly like
  /// the window closed.
  ///
  /// As a sheet the panel belongs to the window, cannot outlive it, and gives
  /// focus back to it — which is what should have happened in the first place.
  func grant() {
    let panel = NSOpenPanel()
    panel.canChooseFiles = false
    panel.canChooseDirectories = true
    panel.allowsMultipleSelection = false
    panel.canCreateDirectories = false
    panel.prompt = "Autorizar"
    panel.message = """
      Escolha uma pasta que a Evie pode ler. Ela só enxerga o que estiver dentro \
      das pastas autorizadas, e nunca escreve nem apaga nada.
      """

    // The window the person is looking at. Falls back to running modally only
    // when there is genuinely no window to attach to, which is the diagnostics
    // path rather than anything a person does.
    guard let host = NSApp.keyWindow ?? NSApp.mainWindow else {
      if panel.runModal() == .OK, let url = panel.url {
        add(url)
      }
      return
    }
    panel.beginSheetModal(for: host) { [weak self] response in
      guard response == .OK, let url = panel.url else {
        return
      }
      MainActor.assumeIsolated {
        self?.add(url)
      }
    }
  }

  /// Records a folder the user chose.
  ///
  /// Separated from the panel so the decision can be tested without a window on
  /// screen.
  func add(_ url: URL) {
    let isHome =
      EvieRootRegistry.canonicalPath(url.path)
      == EvieRootRegistry.canonicalPath(Self.homeURL.path)
    let root = EvieFileRoot(
      displayName: isHome ? "Toda a minha pasta pessoal" : url.lastPathComponent,
      path: url.path,
      // Not security-scoped: Evie is not sandboxed, so a plain bookmark is what
      // applies here. It buys resilience to the folder being renamed or moved,
      // and nothing about the permission itself.
      bookmark: try? url.bookmarkData()
    )

    do {
      let updated = try registry.grant(root, to: roots)
      try registry.save(updated)
      roots = updated
      onChange?(updated)
      feedback = Feedback(
        message: "\(root.displayName) autorizada. A Evie já pode ler o que tem lá.",
        isError: false
      )
    } catch {
      feedback = Feedback(
        message: (error as? LocalizedError)?.errorDescription
          ?? "Não consegui registrar essa pasta.",
        isError: true
      )
    }
  }

  /// Takes a folder back.
  ///
  /// Immediate and complete: the next thing Evie tries to read there fails, and
  /// nothing about the folder survives in the registry.
  func revoke(_ root: EvieFileRoot) {
    do {
      let updated = try registry.revoke(id: root.id, from: roots)
      try registry.save(updated)
      roots = updated
      onChange?(updated)
      feedback = Feedback(
        message: "\(root.displayName) não está mais ao alcance da Evie.",
        isError: false
      )
    } catch {
      feedback = Feedback(
        message: (error as? LocalizedError)?.errorDescription
          ?? "Não consegui remover essa autorização.",
        isError: true
      )
    }
  }

  /// Re-reads the file, for when it changed underneath.
  func reload() {
    roots = registry.load()
  }

  // MARK: - Obsidian

  /// The vault, if there is one where Obsidian puts it.
  ///
  /// Offered as a button because it is the folder this user most wants Evie to
  /// read and the hardest one to find in an open panel: it lives inside the
  /// iCloud container, several levels below a folder called
  /// `Mobile Documents` that Finder does not show under that name.
  // `nonisolated` so the note index can ask the same question off the main
  // actor. It reads the file system and nothing else — there is no state here
  // for the isolation to protect.
  nonisolated static var obsidianVaultURLs: [URL] {
    let home = FileManager.default.homeDirectoryForCurrentUser
    let containers = [
      home.appendingPathComponent(
        "Library/Mobile Documents/iCloud~md~obsidian/Documents",
        isDirectory: true
      ),
      home.appendingPathComponent("Documents", isDirectory: true),
      home,
    ]

    var found: [URL] = []
    for container in containers {
      guard
        // No `.skipsHiddenFiles`, and this is the second time that option has
        // hidden this exact vault. `~/Library` carries the hidden flag, and the
        // option discards everything beneath a hidden ancestor — so listing
        // `Library/Mobile Documents/iCloud~md~obsidian/Documents`, where the
        // iCloud vault lives, returns nothing at all. Measured: 0 entries with
        // the option, 2 without. `EvieVaultIndex.collect` carries the same
        // comment for the same reason; the fix did not travel from one to the
        // other because nobody looked here.
        //
        // The dotfiles the option was there to skip are skipped below instead,
        // by name, which is what was actually wanted.
        let entries = try? FileManager.default.contentsOfDirectory(
          at: container,
          includingPropertiesForKeys: [.isDirectoryKey],
          options: []
        )
      else {
        continue
      }
      for entry in entries where !entry.lastPathComponent.hasPrefix(".") {
        // A vault is a folder with an `.obsidian` settings directory in it.
        // Checking for that rather than for a name means a vault called anything
        // is found and a folder merely called "Obsidian" is not.
        let marker = entry.appendingPathComponent(".obsidian", isDirectory: true)
        if FileManager.default.fileExists(atPath: marker.path) {
          found.append(entry)
        }
      }
    }
    return found
  }

  var untrackedObsidianVaults: [URL] {
    let granted = Set(roots.map { EvieRootRegistry.canonicalPath($0.path) })
    return Self.obsidianVaultURLs.filter { url in
      !granted.contains(EvieRootRegistry.canonicalPath(url.path))
    }
  }

  // MARK: - The whole home folder

  static var homeURL: URL {
    FileManager.default.homeDirectoryForCurrentUser
  }

  var isHomeGranted: Bool {
    let home = EvieRootRegistry.canonicalPath(Self.homeURL.path)
    return roots.contains { EvieRootRegistry.canonicalPath($0.path) == home }
  }

  /// Grants or revokes the entire home folder in one switch.
  ///
  /// Turning it on replaces every other grant, because the home folder contains
  /// them and two doors to the same file would mean revoking one leaves the other
  /// open. `~/Library` stays unreadable regardless — Mail, Messages, cookies, and
  /// application tokens live there, and none of it is what anyone means by "my
  /// files".
  ///
  /// It does not, and cannot, bypass macOS itself. Desktop, Documents,
  /// Downloads, and iCloud Drive are gated by the system, which will ask once for
  /// each the first time Evie looks. Choosing a folder in the open panel carries
  /// that consent with it; a switch cannot.
  func setHomeGranted(_ isGranted: Bool) {
    guard isGranted else {
      if let existing = roots.first(
        where: {
          EvieRootRegistry.canonicalPath($0.path)
            == EvieRootRegistry.canonicalPath(Self.homeURL.path)
        }
      ) {
        revoke(existing)
      }
      return
    }
    guard !isHomeGranted else {
      return
    }
    add(Self.homeURL)
  }
}
