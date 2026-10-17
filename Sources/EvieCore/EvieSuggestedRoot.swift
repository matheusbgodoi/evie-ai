import Foundation

/// The well-known folders Evie may offer to read, and the only places she ever
/// names on her own.
///
/// The list is fixed in code. A suggestion is never a path the model produced:
/// the model can say `mesa`, and the most that word can do is put a card on the
/// screen asking whether the Desktop may be read. Nothing is granted until a
/// person presses the button, and macOS then asks its own question once for the
/// folder (Desktop, Documents and Downloads are protected by TCC).
///
/// The aliases also work as a `root_id` once the folder is reachable, either
/// granted on its own or inside a granted home folder, so "salva na minha mesa"
/// does not depend on the model remembering an eight-character identifier.
public enum EvieSuggestedRoot: String, CaseIterable, Codable, Hashable, Sendable {
  case desktop = "mesa"
  case documents = "documentos"
  case downloads = "downloads"
  case obsidian = "obsidian"

  /// What the model passes as `root_id`.
  public var alias: String { rawValue }

  /// The name shown on cards and given to the root when it is granted.
  public var displayName: String {
    switch self {
    case .desktop: "Mesa"
    case .documents: "Documentos"
    case .downloads: "Downloads"
    case .obsidian: "Obsidian"
    }
  }

  /// Where the folder lives, relative to the home folder.
  public var pathInHome: String {
    switch self {
    case .desktop: "Desktop"
    case .documents: "Documents"
    case .downloads: "Downloads"
    case .obsidian: "Library/Mobile Documents/iCloud~md~obsidian/Documents/Obsidian Vault"
    }
  }

  public func url(home: URL) -> URL {
    home.appendingPathComponent(pathInHome, isDirectory: true)
  }

  /// Whether the folder exists under this home. A suggestion for a folder that
  /// is not there is a button that can only fail.
  public func exists(home: URL) -> Bool {
    var isDirectory: ObjCBool = false
    return FileManager.default.fileExists(atPath: url(home: home).path, isDirectory: &isDirectory)
      && isDirectory.boolValue
  }

  /// "sua Mesa", "seus Documentos": the folder as its owner would say it.
  public var possessive: String {
    switch self {
    case .desktop: "sua Mesa"
    case .documents: "seus Documentos"
    case .downloads: "seus Downloads"
    case .obsidian: "seu cofre do Obsidian"
    }
  }

  /// The card's question.
  public var grantTitle: String {
    "Permitir que a Evie leia \(possessive)"
  }

  /// What the card says before the button, including the one surprise: macOS
  /// asks again, once, in its own window.
  public var grantExplanation: String {
    let system =
      self == .obsidian
      ? "O macOS pode perguntar uma vez se a Evie pode acessar o iCloud Drive; é só permitir."
      : "O macOS vai perguntar uma vez se a Evie pode acessar \(possessive); é só permitir."
    return """
      Ela passa a ler o que estiver em \(displayName) quando você pedir. Mudar \
      ou criar arquivo continua passando por um cartão seu. \(system) Dá para \
      tirar a permissão quando quiser, em Configurações.
      """
  }

  /// Reads an alias the model wrote, forgiving the spellings it uses.
  public init?(alias: String) {
    let folded = EvieChangeIntent.fold(alias)
    switch folded {
    case "mesa", "desktop", "area de trabalho", "a mesa", "minha mesa": self = .desktop
    case "documentos", "documents", "meus documentos": self = .documents
    case "downloads", "download", "transferencias": self = .downloads
    case "obsidian", "cofre", "vault", "obsidian vault": self = .obsidian
    default: return nil
    }
  }

  /// The well-known folders the person's own message mentions.
  ///
  /// Matched on whole words. "mesa" and "documentos" are ordinary nouns, so
  /// they count only after a word that makes them a place ("na minha mesa",
  /// "salva em Documentos"); "mesa de jantar" is not a folder. A false positive
  /// costs a card that can be closed, never a grant.
  public static func mentioned(in message: String) -> [EvieSuggestedRoot] {
    let words = EvieChangeIntent.fold(message)
      .components(separatedBy: CharacterSet.letters.inverted)
      .filter { !$0.isEmpty }
    var found: [EvieSuggestedRoot] = []
    func note(_ root: EvieSuggestedRoot) {
      if !found.contains(root) {
        found.append(root)
      }
    }

    for (index, word) in words.enumerated() {
      let previous = index > 0 ? words[index - 1] : ""
      let next = index + 1 < words.count ? words[index + 1] : ""
      switch word {
      case "desktop", "downloads", "transferencias", "obsidian":
        note(word == "desktop" ? .desktop : word == "obsidian" ? .obsidian : .downloads)
      case "mesa" where placeWords.contains(previous) && next != "de":
        note(.desktop)
      case "trabalho" where previous == "de" && index >= 2 && words[index - 2] == "area":
        note(.desktop)
      case "documentos" where placeWords.contains(previous):
        note(.documents)
      default:
        break
      }
    }
    return found
  }

  /// Words that turn "mesa" or "documentos" into a place.
  static let placeWords: Set<String> = [
    "minha", "meu", "meus", "minhas", "sua", "seus", "na", "no", "nos", "nas", "da", "do",
    "dos", "em", "pasta", "a", "para", "pra",
  ]

  /// Where this folder is reachable through what has already been granted:
  /// the root itself, or a narrowed view of a granted folder that contains it.
  ///
  /// A narrowed view is produced only when the folder, with every symlink
  /// resolved, still lies inside the granted one and the path between them
  /// holds no denied name — so the alias can never reach further than the
  /// granted folder could. The Obsidian vault lives under `Library`, which a
  /// granted home folder never exposes, so it is reachable only when granted on
  /// its own.
  public func location(in roots: [EvieFileRoot], home: URL) -> EvieFileRoot? {
    let target = EvieRootRegistry.canonicalPath(url(home: home).path)
    if let exact = roots.first(where: { EvieRootRegistry.canonicalPath($0.path) == target }) {
      return exact
    }
    for root in roots {
      let rootPath = EvieRootRegistry.canonicalPath(root.path)
      guard EvieRootRegistry.contains(rootPath, target), target != rootPath else {
        continue
      }
      let inside = String(target.dropFirst(rootPath.count + 1))
      guard !inside.split(separator: "/").map(String.init).contains(where: EvieScopedFileReader.isDenied)
      else {
        continue
      }
      return EvieFileRoot(
        id: alias,
        displayName: displayName,
        path: target,
        grantedAt: root.grantedAt
      )
    }
    return nil
  }

  /// What a `root_id` names: a granted folder, a well-known folder that has not
  /// been granted yet, or nothing.
  public enum Lookup: Hashable, Sendable {
    case granted(EvieFileRoot)
    case notGranted(EvieSuggestedRoot)
    case unknown
  }

  /// Resolves a `root_id`: an identifier from `list_roots` first, then an alias.
  ///
  /// Without a `home`, aliases are not understood at all — the schedule runner
  /// and the tests that predate suggestions see exactly the identifiers they
  /// were given and nothing else.
  public static func lookup(
    _ identifier: String,
    in roots: [EvieFileRoot],
    home: URL?
  ) -> Lookup {
    let trimmed = identifier.trimmingCharacters(in: .whitespacesAndNewlines)
    if let root = roots.first(where: { $0.id == trimmed }) {
      return .granted(root)
    }
    guard let home, let suggestion = EvieSuggestedRoot(alias: trimmed) else {
      return .unknown
    }
    if let location = suggestion.location(in: roots, home: home) {
      return .granted(location)
    }
    return suggestion.exists(home: home) ? .notGranted(suggestion) : .unknown
  }

  /// The well-known folders that exist here and cannot be reached yet.
  public static func ungranted(in roots: [EvieFileRoot], home: URL) -> [EvieSuggestedRoot] {
    allCases.filter { $0.exists(home: home) && $0.location(in: roots, home: home) == nil }
  }
}
