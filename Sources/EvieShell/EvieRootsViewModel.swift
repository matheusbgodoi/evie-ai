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

    guard panel.runModal() == .OK, let url = panel.url else {
      return
    }
    add(url)
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
  static var obsidianVaultURLs: [URL] {
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
        let entries = try? FileManager.default.contentsOfDirectory(
          at: container,
          includingPropertiesForKeys: [.isDirectoryKey],
          options: [.skipsHiddenFiles]
        )
      else {
        continue
      }
      for entry in entries {
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
