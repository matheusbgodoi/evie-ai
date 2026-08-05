import Foundation

/// A folder the user granted Evie, and the only kind of place she may look.
///
/// The identifier is short and opaque on purpose: it is what the model sees and
/// what it passes back. A model that never handles a path cannot construct one it
/// was not given, and cannot repeat one into an answer.
public struct EvieFileRoot: Identifiable, Codable, Hashable, Sendable {
  public let id: String
  public var displayName: String
  /// Shown to the user, never sent to the model.
  public var path: String
  public var grantedAt: Date
  /// Survives the folder being renamed or moved. Absent for a root recorded
  /// before bookmarking, which then resolves by path alone.
  public var bookmark: Data?

  public init(
    id: String = EvieFileRoot.makeIdentifier(),
    displayName: String,
    path: String,
    grantedAt: Date = Date(),
    bookmark: Data? = nil
  ) {
    self.id = id
    self.displayName = displayName
    self.path = path
    self.grantedAt = grantedAt
    self.bookmark = bookmark
  }

  /// Short enough for a model to repeat without mangling, long enough not to
  /// collide.
  public static func makeIdentifier() -> String {
    String(UUID().uuidString.replacingOccurrences(of: "-", with: "").prefix(8)).lowercased()
  }

  public var url: URL {
    URL(fileURLWithPath: path, isDirectory: true)
  }
}

/// Where the granted folders are recorded.
///
/// The same shape as the other local stores: versioned, atomic, `0700`/`0600`,
/// and a damaged file resolves to nothing granted rather than to everything.
public struct EvieRootRegistry: Sendable {
  public static let supportedSchemaVersion = 1
  /// A ceiling so a runaway grant loop cannot produce a file that is slow to
  /// read on every launch.
  public static let maximumRoots = 32

  public let fileURL: URL

  public init(fileURL: URL = EvieRootRegistry.defaultFileURL) {
    self.fileURL = fileURL
  }

  public static var defaultFileURL: URL {
    EvieConfigurationLoader.defaultFileURL
      .deletingLastPathComponent()
      .appendingPathComponent("roots.json", isDirectory: false)
  }

  public enum RegistryError: Error, Equatable, Sendable {
    case tooManyRoots
    case duplicatePath(String)
    case notFound(String)
  }

  /// Every granted root, newest first. A file that cannot be read or understood
  /// yields an empty list: failing closed here means Evie can see nothing, which
  /// is the safe direction.
  public func load() -> [EvieFileRoot] {
    guard FileManager.default.fileExists(atPath: fileURL.path),
      let data = try? Data(contentsOf: fileURL, options: [.mappedIfSafe])
    else {
      return []
    }

    let decoder = JSONDecoder()
    decoder.keyDecodingStrategy = .convertFromSnakeCase
    decoder.dateDecodingStrategy = .iso8601
    guard let document = try? decoder.decode(RegistryDocument.self, from: data),
      document.schemaVersion == Self.supportedSchemaVersion
    else {
      return []
    }
    return document.roots.sorted { $0.grantedAt > $1.grantedAt }
  }

  public func save(_ roots: [EvieFileRoot]) throws {
    guard roots.count <= Self.maximumRoots else {
      throw RegistryError.tooManyRoots
    }

    let directoryURL = fileURL.deletingLastPathComponent()
    try FileManager.default.createDirectory(
      at: directoryURL,
      withIntermediateDirectories: true,
      attributes: [.posixPermissions: 0o700]
    )
    try FileManager.default.setAttributes(
      [.posixPermissions: 0o700],
      ofItemAtPath: directoryURL.path
    )

    let encoder = JSONEncoder()
    encoder.keyEncodingStrategy = .convertToSnakeCase
    encoder.dateEncodingStrategy = .iso8601
    encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
    var data = try encoder.encode(
      RegistryDocument(schemaVersion: Self.supportedSchemaVersion, roots: roots)
    )
    data.append(0x0A)
    try data.write(to: fileURL, options: .atomic)
    try FileManager.default.setAttributes(
      [.posixPermissions: 0o600],
      ofItemAtPath: fileURL.path
    )
  }

  /// Records a new grant.
  ///
  /// Granting a folder that already contains a granted one replaces it: keeping
  /// both would mean the same file reachable through two identifiers, and a
  /// revocation that silently left it readable.
  @discardableResult
  public func grant(
    _ root: EvieFileRoot,
    to existing: [EvieFileRoot]
  ) throws -> [EvieFileRoot] {
    let canonical = Self.canonicalPath(root.path)
    guard !existing.contains(where: { Self.canonicalPath($0.path) == canonical }) else {
      throw RegistryError.duplicatePath(root.displayName)
    }

    var updated = existing.filter { !Self.canonicalPath($0.path).hasPrefix(canonical) }
    // A folder already inside a granted one adds nothing and confuses revoking.
    guard !updated.contains(where: { canonical.hasPrefix(Self.canonicalPath($0.path)) }) else {
      throw RegistryError.duplicatePath(root.displayName)
    }
    updated.append(root)
    guard updated.count <= Self.maximumRoots else {
      throw RegistryError.tooManyRoots
    }
    return updated.sorted { $0.grantedAt > $1.grantedAt }
  }

  public func revoke(id: String, from existing: [EvieFileRoot]) throws -> [EvieFileRoot] {
    guard existing.contains(where: { $0.id == id }) else {
      throw RegistryError.notFound(id)
    }
    return existing.filter { $0.id != id }
  }

  /// A trailing slash and a symlinked parent are the two ways the same folder
  /// gets recorded twice.
  static func canonicalPath(_ path: String) -> String {
    let resolved = URL(fileURLWithPath: path).resolvingSymlinksInPath().path
    return resolved.hasSuffix("/") ? String(resolved.dropLast()) : resolved
  }
}

extension EvieRootRegistry {
  fileprivate struct RegistryDocument: Codable {
    let schemaVersion: Int
    let roots: [EvieFileRoot]
  }
}

extension EvieRootRegistry.RegistryError: LocalizedError {
  public var errorDescription: String? {
    switch self {
    case .tooManyRoots:
      "Você já autorizou o máximo de \(EvieRootRegistry.maximumRoots) pastas."
    case .duplicatePath(let name):
      "\(name) já está autorizada, ou está dentro de uma pasta que já está."
    case .notFound(let id):
      "Não encontrei a autorização \(id)."
    }
  }
}
