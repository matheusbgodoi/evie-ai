import Foundation

/// Performs a change the user approved, and nothing else.
///
/// Every rule here exists because the operating system will not enforce it.
/// TCC gates *reading*: once a path is reachable, moving or unlinking a file is
/// ordinary POSIX with no prompt, no audit, and no undo. Containment at this
/// point is entirely Evie's own work, which is why this is more paranoid than
/// the reader.
///
/// Four rules, and each one is a refusal rather than a warning:
///
/// - **The Trash, never `unlink`.** A deletion Evie performs must be one the user
///   can walk back without her.
/// - **The file must still be the file.** Inode, device, size and modification
///   time are re-checked at the instant of the change. An approval is for the
///   file the user was shown, not for whatever now answers to that name.
/// - **A move may not overwrite.** `renamex_np(RENAME_EXCL)` fails rather than
///   silently replacing something. `rename(2)` on its own destroys the
///   destination, which is a data-loss bug with no error message.
/// - **Both ends stay inside one authorised folder**, opened through the same
///   kernel containment the reader uses.
public struct EvieFileWriter: Sendable {
  public init() {}

  public enum WriteError: Error, Equatable, Sendable {
    case expired
    case fileChanged
    case notFound(String)
    case denied(String)
    case escapesRoot(String)
    case destinationExists(String)
    case crossVolume
    case failed(String)
  }

  /// What actually happened, for the record the user sees afterwards.
  public struct Receipt: Hashable, Sendable {
    public var change: EvieFileChange
    public var performedAt: Date
    /// Where the file ended up, when that is somewhere findable. A trashed file
    /// is in the Trash and the user knows where that is.
    public var resultingPath: String?

    public init(change: EvieFileChange, performedAt: Date = Date(), resultingPath: String? = nil) {
      self.change = change
      self.performedAt = performedAt
      self.resultingPath = resultingPath
    }
  }

  /// Reads the file's identity, for recording on a proposal and for checking at
  /// the moment of the change.
  public func precondition(
    of change: EvieFileChange,
    in root: EvieFileRoot
  ) throws -> EvieFileChange.Precondition {
    let url = try resolve(change.path, in: root)
    let attributes: [FileAttributeKey: Any]
    do {
      attributes = try FileManager.default.attributesOfItem(atPath: url.path)
    } catch {
      throw WriteError.notFound(change.path)
    }
    guard
      let inode = (attributes[.systemFileNumber] as? NSNumber)?.uint64Value,
      let device = (attributes[.systemNumber] as? NSNumber)?.int32Value,
      let size = (attributes[.size] as? NSNumber)?.intValue,
      let modified = attributes[.modificationDate] as? Date
    else {
      throw WriteError.notFound(change.path)
    }
    return EvieFileChange.Precondition(
      inode: inode,
      device: device,
      byteSize: size,
      modifiedAt: modified
    )
  }

  /// Carries out an approved change.
  ///
  /// Refuses an approval that has expired or that no longer describes the file,
  /// because the user approved a sentence about a specific file at a specific
  /// moment and neither of those is guaranteed to still hold.
  public func perform(
    _ change: EvieFileChange,
    in root: EvieFileRoot,
    now: Date = Date()
  ) throws -> Receipt {
    guard !change.hasExpired(at: now) else {
      throw WriteError.expired
    }
    if let recorded = change.precondition {
      let current = try precondition(of: change, in: root)
      guard recorded.matches(current) else {
        throw WriteError.fileChanged
      }
    }

    let source = try resolve(change.path, in: root)
    switch change.kind {
    case .trash:
      var trashed: NSURL?
      do {
        try FileManager.default.trashItem(at: source, resultingItemURL: &trashed)
      } catch {
        throw WriteError.failed(error.localizedDescription)
      }
      return Receipt(
        change: change,
        performedAt: now,
        resultingPath: (trashed as URL?)?.lastPathComponent
      )

    case .rename, .move:
      guard let destinationPath = change.destination else {
        throw WriteError.failed("faltou o destino")
      }
      let destination = try resolve(destinationPath, in: root, mustExist: false)
      guard !FileManager.default.fileExists(atPath: destination.path) else {
        throw WriteError.destinationExists(destinationPath)
      }
      // The parent has to exist; creating one silently would be a change the
      // user did not approve.
      let parent = destination.deletingLastPathComponent()
      guard FileManager.default.fileExists(atPath: parent.path) else {
        throw WriteError.notFound(
          (destinationPath as NSString).deletingLastPathComponent
        )
      }

      try Self.moveWithoutOverwriting(from: source, to: destination)
      return Receipt(change: change, performedAt: now, resultingPath: destinationPath)
    }
  }

  /// Moves, and fails rather than replacing anything already there.
  ///
  /// `FileManager.moveItem` and `rename(2)` both destroy the destination without
  /// complaint. `RENAME_EXCL` is the flag that turns that silent data loss into
  /// an error, and it is the only reason this drops to the C API.
  static func moveWithoutOverwriting(from source: URL, to destination: URL) throws {
    let result = source.withUnsafeFileSystemRepresentation { sourcePath in
      destination.withUnsafeFileSystemRepresentation { destinationPath in
        guard let sourcePath, let destinationPath else {
          return Int32(-1)
        }
        return renamex_np(sourcePath, destinationPath, UInt32(RENAME_EXCL))
      }
    }
    guard result != 0 else {
      return
    }
    switch errno {
    case EEXIST:
      throw WriteError.destinationExists(destination.lastPathComponent)
    case EXDEV:
      // Copy-verify-trash is a different capability with different risks, and
      // pretending a move happened when a copy did would be worse than refusing.
      throw WriteError.crossVolume
    case ENOENT:
      throw WriteError.notFound(source.lastPathComponent)
    case EACCES, EPERM:
      throw WriteError.denied(source.lastPathComponent)
    default:
      throw WriteError.failed(String(cString: strerror(errno)))
    }
  }
}

extension EvieFileWriter {
  /// Turns a path the model spoke into a real one, inside the root and nowhere
  /// else.
  ///
  /// The reader proves containment with `O_RESOLVE_BENEATH`; a rename takes paths
  /// rather than descriptors, so containment here is proved by resolving both
  /// ends and checking that what came back still lies beneath the root. Symlinks
  /// are resolved first, so a link pointing outside is caught rather than
  /// followed.
  fileprivate func resolve(
    _ relativePath: String,
    in root: EvieFileRoot,
    mustExist: Bool = true
  ) throws -> URL {
    var trimmed = relativePath.trimmingCharacters(in: .whitespacesAndNewlines)
    while trimmed.hasPrefix("/") || trimmed.hasPrefix("./") {
      trimmed.removeFirst(trimmed.hasPrefix("./") ? 2 : 1)
    }
    guard !trimmed.isEmpty else {
      throw WriteError.escapesRoot(relativePath)
    }

    let components = trimmed.split(separator: "/").map(String.init)
    // A denied name anywhere in the path, exactly as the reader treats it:
    // authorising a folder is not authorising the credentials inside it, and
    // that has to hold for moving as well as for reading.
    for component in components {
      guard component != "..", component != "." else {
        throw WriteError.escapesRoot(relativePath)
      }
      guard !EvieScopedFileReader.isDenied(component) else {
        throw WriteError.denied(component)
      }
    }

    let rootPath = root.url.resolvingSymlinksInPath().path
    let candidate = root.url.appendingPathComponent(trimmed)
    // An existing path is resolved through its symlinks; one that does not exist
    // yet is checked as written, with its parent resolved.
    let resolved =
      FileManager.default.fileExists(atPath: candidate.path)
      ? candidate.resolvingSymlinksInPath().path
      : candidate.deletingLastPathComponent().resolvingSymlinksInPath()
        .appendingPathComponent(candidate.lastPathComponent).path

    guard resolved == rootPath || resolved.hasPrefix(rootPath + "/") else {
      throw WriteError.escapesRoot(relativePath)
    }
    if mustExist, !FileManager.default.fileExists(atPath: resolved) {
      throw WriteError.notFound(relativePath)
    }
    return URL(fileURLWithPath: resolved)
  }
}

extension EvieFileWriter.WriteError: LocalizedError {
  public var errorDescription: String? {
    switch self {
    case .expired:
      "Essa confirmação já venceu. Peça de novo, para eu conferir o arquivo agora."
    case .fileChanged:
      "O arquivo mudou depois que você aprovou, então não mexi nele."
    case .notFound(let path):
      "Não achei \(path)."
    case .denied(let name):
      "\(name) está fora do meu alcance."
    case .escapesRoot(let path):
      "\(path) sai da pasta autorizada."
    case .destinationExists(let path):
      "Já existe algo em \(path). Não sobrescrevi nada."
    case .crossVolume:
      "Isso mudaria de disco, e mover entre discos é outra coisa. Não fiz."
    case .failed(let reason):
      "Não consegui: \(reason)"
    }
  }
}
