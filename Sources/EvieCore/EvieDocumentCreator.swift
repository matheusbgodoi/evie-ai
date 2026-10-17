import Foundation

/// Writes a document the person approved, as a new file, and nothing else.
///
/// The rules mirror `EvieFileWriter`'s, and like those each one is a refusal:
///
/// - **Never an existing file.** The file is opened with `O_CREAT | O_EXCL`, so
///   the kernel refuses a name that is taken rather than this code checking
///   first and racing. A taken name moves on to "nome (2).ext", "nome (3).ext".
/// - **Inside the granted folder.** Every directory along the way is opened
///   with `O_RESOLVE_BENEATH | O_NOFOLLOW_ANY` from a descriptor for the root,
///   exactly as the reader opens it, so a symlinked subfolder or a `..` cannot
///   carry the file anywhere else.
/// - **No denied name.** A subfolder called `.ssh` is refused here as it is in
///   the reader.
/// - **Expired is expired.** A card is good for fifteen minutes.
///
/// A missing subfolder is created, because the card showed it as part of where
/// the file lands. Nothing else is created, and nothing is ever removed except
/// the half-written file of a write that failed.
public struct EvieDocumentCreator: Sendable {
  /// How many "(n)" names are tried before giving up.
  public static let maximumNameAttempts = 99

  public init() {}

  public enum CreateError: Error, Equatable, Sendable {
    case expired
    case escapesRoot(String)
    case denied(String)
    case rootUnavailable(String)
    case namesExhausted(String)
    case renderFailed
    case failed(String)
  }

  /// What was written, for the record the person sees afterwards.
  public struct Receipt: Hashable, Sendable {
    public var proposal: EvieDocumentProposal
    /// Relative to the root the file was written in.
    public var relativePath: String
    public var fileName: String
    /// Where it is, for opening it afterwards. Never shown to the model.
    public var url: URL
    public var byteSize: Int
    public var createdAt: Date
  }

  public func create(
    _ proposal: EvieDocumentProposal,
    in root: EvieFileRoot,
    now: Date = Date()
  ) throws -> Receipt {
    guard !proposal.hasExpired(at: now) else {
      throw CreateError.expired
    }
    let data: Data
    do {
      data = try EvieDocumentRenderer.render(proposal)
    } catch {
      throw CreateError.renderFailed
    }
    guard case .success(let subfolder) = EvieDocumentTool.normalisedSubfolder(proposal.subfolder)
    else {
      throw CreateError.escapesRoot(proposal.subfolder)
    }

    let rootDescriptor = open(root.url.path, O_RDONLY | O_DIRECTORY | O_CLOEXEC)
    guard rootDescriptor >= 0 else {
      throw CreateError.rootUnavailable(root.displayName)
    }
    defer { close(rootDescriptor) }

    let components = subfolder.split(separator: "/").map(String.init)
    let directory = try openDirectory(components, beneath: rootDescriptor)
    defer { close(directory) }

    for attempt in 1...Self.maximumNameAttempts {
      let name = proposal.fileName(attempt: attempt)
      guard !EvieScopedFileReader.isDenied(name) else {
        throw CreateError.denied(name)
      }
      let descriptor = openat(
        directory,
        name,
        O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW | O_CLOEXEC,
        mode_t(0o644)
      )
      if descriptor < 0 {
        if errno == EEXIST {
          continue
        }
        throw Self.failure(errno, path: name)
      }
      defer { close(descriptor) }

      guard Self.writeAll(data, to: descriptor) else {
        let reason = String(cString: strerror(errno))
        // The only file this ever removes: the one it just created and could
        // not finish. A half-written document is worse than none.
        unlinkat(directory, name, 0)
        throw CreateError.failed(reason)
      }
      let relativePath = (components + [name]).joined(separator: "/")
      return Receipt(
        proposal: proposal,
        relativePath: relativePath,
        fileName: name,
        url: root.url.appendingPathComponent(relativePath),
        byteSize: data.count,
        createdAt: now
      )
    }
    throw CreateError.namesExhausted(proposal.fileName())
  }

  /// Opens — creating where missing — each subfolder in turn, beneath the root.
  private func openDirectory(_ components: [String], beneath root: Int32) throws -> Int32 {
    var current = dup(root)
    guard current >= 0 else {
      throw CreateError.failed(String(cString: strerror(errno)))
    }
    let flags = O_RDONLY | O_DIRECTORY | O_RESOLVE_BENEATH | O_NOFOLLOW_ANY | O_CLOEXEC
    for component in components {
      var next = openat(current, component, flags)
      if next < 0, errno == ENOENT {
        // Racing another creator of the same folder is harmless: EEXIST means
        // it is there now, and the open below proves it is a real directory.
        if mkdirat(current, component, mode_t(0o755)) != 0, errno != EEXIST {
          let code = errno
          close(current)
          throw Self.failure(code, path: component)
        }
        next = openat(current, component, flags)
      }
      let code = errno
      close(current)
      guard next >= 0 else {
        throw Self.failure(code, path: component)
      }
      current = next
    }
    return current
  }

  private static func writeAll(_ data: Data, to descriptor: Int32) -> Bool {
    data.withUnsafeBytes { raw -> Bool in
      guard var pointer = raw.baseAddress else {
        return true
      }
      var remaining = raw.count
      while remaining > 0 {
        let written = write(descriptor, pointer, remaining)
        if written < 0, errno == EINTR {
          continue
        }
        guard written > 0 else {
          return false
        }
        pointer = pointer.advanced(by: written)
        remaining -= written
      }
      return true
    }
  }

  private static func failure(_ code: Int32, path: String) -> CreateError {
    switch code {
    case ELOOP, EvieScopedFileReader.notCapableErrorCode, ENOTDIR:
      .escapesRoot(path)
    case EACCES, EPERM:
      .denied(path)
    default:
      .failed(String(cString: strerror(code)))
    }
  }
}

extension EvieDocumentCreator.CreateError: LocalizedError {
  public var errorDescription: String? {
    switch self {
    case .expired:
      "Esse cartão venceu. Peça de novo e eu preparo o documento outra vez."
    case .escapesRoot(let path):
      "\(path) sairia da pasta autorizada, então não salvei."
    case .denied(let name):
      "Não tenho permissão de gravar em \(name)."
    case .rootUnavailable(let name):
      "A pasta \(name) não está acessível agora."
    case .namesExhausted(let name):
      "Já existem cópias demais de \(name). Escolha outro nome."
    case .renderFailed:
      "Não consegui montar o documento nesse formato."
    case .failed(let reason):
      "Não consegui salvar: \(reason)"
    }
  }
}
