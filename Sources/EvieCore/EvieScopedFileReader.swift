import Darwin
import Foundation

/// One entry in a folder Evie was allowed to look at.
public struct EvieDirectoryEntry: Codable, Hashable, Sendable {
  public var name: String
  public var isDirectory: Bool
  public var byteSize: Int?
  public var modifiedAt: Date?

  public init(name: String, isDirectory: Bool, byteSize: Int? = nil, modifiedAt: Date? = nil) {
    self.name = name
    self.isDirectory = isDirectory
    self.byteSize = byteSize
    self.modifiedAt = modifiedAt
  }
}

public struct EvieDirectoryListing: Codable, Hashable, Sendable {
  public var relativePath: String
  public var entries: [EvieDirectoryEntry]
  /// True when the folder holds more entries than this page returned.
  public var hasMore: Bool
  /// How many entries were withheld because they are on the denylist.
  public var withheldCount: Int

  public init(
    relativePath: String,
    entries: [EvieDirectoryEntry],
    hasMore: Bool,
    withheldCount: Int
  ) {
    self.relativePath = relativePath
    self.entries = entries
    self.hasMore = hasMore
    self.withheldCount = withheldCount
  }
}

public struct EvieFileExcerpt: Codable, Hashable, Sendable {
  public var relativePath: String
  public var text: String
  public var byteSize: Int
  public var isTruncated: Bool

  public init(relativePath: String, text: String, byteSize: Int, isTruncated: Bool) {
    self.relativePath = relativePath
    self.text = text
    self.byteSize = byteSize
    self.isTruncated = isTruncated
  }
}

/// Reads inside a folder the user granted, and nowhere else.
///
/// Containment is enforced by the kernel rather than by inspecting path strings.
/// String checks lose to symlinks, to `..`, and to a file being replaced between
/// the check and the open. A descriptor for the root plus `O_RESOLVE_BENEATH`
/// and `O_NOFOLLOW_ANY` makes the escape impossible rather than unlikely:
/// verified on this Mac, a symlink pointing at `/etc/hosts` fails with `ELOOP`,
/// and both `../../etc/hosts` and `/etc/hosts` fail with `ECAPMODE`.
public struct EvieScopedFileReader: Sendable {
  /// Most text a single read returns. Anything longer is truncated and says so.
  public static let maximumReadBytes = 512 * 1_024
  /// Entries per listing page.
  public static let pageSize = 128
  /// How much of a file is inspected before deciding it is not text.
  private static let binarySniffBytes = 8_192

  public var maximumReadBytes: Int
  public var pageSize: Int

  public init(
    maximumReadBytes: Int = EvieScopedFileReader.maximumReadBytes,
    pageSize: Int = EvieScopedFileReader.pageSize
  ) {
    self.maximumReadBytes = maximumReadBytes
    self.pageSize = pageSize
  }

  public enum ReaderError: Error, Equatable, Sendable {
    case invalidPath(String)
    case escapesRoot(String)
    case notFound(String)
    case denied(String)
    case notReadable(String)
    case notADirectory(String)
    case isADirectory(String)
    case notText(String)
    case rootUnavailable(String)
  }

  /// Names that stay unreadable even inside a folder the user granted.
  ///
  /// Granting a folder is not consent to hand over the credentials that happen to
  /// live in it. The list is applied to every path component, not just the last.
  /// A folder named `Library` is refused because of what the user's own
  /// `~/Library` contains: Mail's message store, Messages' chat database, Safari
  /// history, browser cookies, and the OAuth tokens every application leaves in
  /// Application Support. None of that is the user's documents, all of it is far
  /// more sensitive than the folder someone meant to share, and granting a home
  /// folder wholesale would otherwise hand over the lot. The cost is that a
  /// project folder that happens to contain a directory called `Library` is
  /// unreadable — a small failure, in the safe direction.
  public static let deniedNames: Set<String> = [
    ".ssh", ".gnupg", ".aws", ".azure", ".kube", ".docker", ".netrc", ".npmrc",
    ".pypirc", ".git-credentials", ".gitconfig", ".env", ".envrc",
    "Library", "Keychains", "Cookies", "Cookies.binarycookies", "login.keychain-db",
    "id_rsa", "id_dsa", "id_ecdsa", "id_ed25519", "authorized_keys", "known_hosts",
    "credentials", "secrets", "shadow", "master.key",
  ]

  /// Extensions that are refused wherever they appear.
  public static let deniedExtensions: Set<String> = [
    "pem", "key", "p12", "pfx", "jks", "keystore", "keychain", "kdbx", "asc", "gpg",
  ]

  public static func isDenied(_ name: String) -> Bool {
    if deniedNames.contains(name) {
      return true
    }
    // `.env.local`, `.env.production`, and friends.
    if name.hasPrefix(".env") {
      return true
    }
    let extensionName = (name as NSString).pathExtension.lowercased()
    return !extensionName.isEmpty && deniedExtensions.contains(extensionName)
  }

  // MARK: - Listing

  public func list(
    root: URL,
    relativePath: String = "",
    offset: Int = 0
  ) throws -> EvieDirectoryListing {
    let components = try Self.components(of: relativePath)
    let rootDescriptor = try Self.openRoot(root)
    defer { close(rootDescriptor) }

    let descriptor = try Self.openContained(
      rootDescriptor: rootDescriptor,
      components: components,
      relativePath: relativePath,
      flags: O_RDONLY | O_DIRECTORY
    )

    // `fdopendir` takes ownership of the descriptor; closing it here would be a
    // double close.
    guard let directory = fdopendir(descriptor) else {
      close(descriptor)
      throw ReaderError.notADirectory(relativePath)
    }
    defer { closedir(directory) }

    var names: [String] = []
    var withheld = 0
    while let entry = readdir(directory) {
      let name = withUnsafeBytes(of: entry.pointee.d_name) { buffer in
        String(cString: buffer.baseAddress!.assumingMemoryBound(to: CChar.self))
      }
      guard name != ".", name != ".." else {
        continue
      }
      if Self.isDenied(name) {
        withheld += 1
        continue
      }
      names.append(name)
    }
    names.sort { $0.localizedStandardCompare($1) == .orderedAscending }

    let page = names.dropFirst(max(offset, 0)).prefix(pageSize)
    let entries = page.map { name in
      Self.describe(name: name, in: dirfd(directory))
    }

    return EvieDirectoryListing(
      relativePath: relativePath,
      entries: entries,
      hasMore: names.count > max(offset, 0) + entries.count,
      withheldCount: withheld
    )
  }

  // MARK: - Reading

  public func read(root: URL, relativePath: String) throws -> EvieFileExcerpt {
    let components = try Self.components(of: relativePath)
    guard !components.isEmpty else {
      throw ReaderError.isADirectory(relativePath)
    }
    let rootDescriptor = try Self.openRoot(root)
    defer { close(rootDescriptor) }

    let descriptor = try Self.openContained(
      rootDescriptor: rootDescriptor,
      components: components,
      relativePath: relativePath,
      flags: O_RDONLY
    )
    defer { close(descriptor) }

    // `fstat` on the descriptor, never `stat` on the path: what was checked has
    // to be what was opened.
    var status = stat()
    guard fstat(descriptor, &status) == 0 else {
      throw ReaderError.notReadable(relativePath)
    }
    guard (status.st_mode & S_IFMT) != S_IFDIR else {
      throw ReaderError.isADirectory(relativePath)
    }
    guard (status.st_mode & S_IFMT) == S_IFREG else {
      throw ReaderError.notReadable(relativePath)
    }

    let byteSize = Int(status.st_size)
    let limit = min(byteSize, maximumReadBytes)
    var buffer = [UInt8](repeating: 0, count: max(limit, 1))
    var total = 0
    while total < limit {
      let read = buffer.withUnsafeMutableBytes { raw -> Int in
        Darwin.read(descriptor, raw.baseAddress!.advanced(by: total), limit - total)
      }
      if read <= 0 {
        break
      }
      total += read
    }
    let data = Data(buffer.prefix(total))

    if Self.looksBinary(data) {
      throw ReaderError.notText(relativePath)
    }
    guard let text = String(data: data, encoding: .utf8) else {
      throw ReaderError.notText(relativePath)
    }

    return EvieFileExcerpt(
      relativePath: relativePath,
      text: text,
      byteSize: byteSize,
      isTruncated: byteSize > total
    )
  }
}

extension EvieScopedFileReader {
  /// Splits and validates a relative path before the kernel ever sees it.
  ///
  /// The kernel would refuse these anyway; refusing them here produces an error
  /// that names what was wrong instead of a bare `ECAPMODE`.
  static func components(of relativePath: String) throws -> [String] {
    guard !relativePath.hasPrefix("/") else {
      throw ReaderError.escapesRoot(relativePath)
    }
    let parts = relativePath.split(separator: "/").map(String.init)
    for part in parts {
      guard part != "..", part != "." else {
        throw ReaderError.escapesRoot(relativePath)
      }
      guard !part.isEmpty, !part.contains("\0") else {
        throw ReaderError.invalidPath(relativePath)
      }
      guard !isDenied(part) else {
        throw ReaderError.denied(part)
      }
    }
    return parts
  }

  static func openRoot(_ root: URL) throws -> Int32 {
    let descriptor = open(root.path, O_RDONLY | O_DIRECTORY | O_CLOEXEC)
    guard descriptor >= 0 else {
      throw ReaderError.rootUnavailable(root.lastPathComponent)
    }
    return descriptor
  }

  /// Walks the path one component at a time, so a symlink anywhere along it is
  /// refused rather than only at the final element.
  static func openContained(
    rootDescriptor: Int32,
    components: [String],
    relativePath: String,
    flags: Int32
  ) throws -> Int32 {
    var current = rootDescriptor
    var owned = false

    for (index, component) in components.enumerated() {
      let isLast = index == components.count - 1
      let componentFlags =
        (isLast ? flags : O_RDONLY | O_DIRECTORY)
        | O_RESOLVE_BENEATH | O_NOFOLLOW_ANY | O_CLOEXEC
      let next = openat(current, component, componentFlags)
      if owned {
        close(current)
      }
      guard next >= 0 else {
        throw mapOpenFailure(errno, relativePath: relativePath)
      }
      current = next
      owned = true
    }

    if !owned {
      // The path was the root itself.
      let duplicate = dup(rootDescriptor)
      guard duplicate >= 0 else {
        throw ReaderError.rootUnavailable(relativePath)
      }
      return duplicate
    }
    return current
  }

  /// `ENOTCAPABLE`, "capabilities insufficient".
  static let notCapableErrorCode: Int32 = 107

  static func mapOpenFailure(_ code: Int32, relativePath: String) -> ReaderError {
    switch code {
    case ENOENT: .notFound(relativePath)
    case ELOOP: .escapesRoot(relativePath)
    // ENOTCAPABLE is what `O_RESOLVE_BENEATH` returns when a resolution would
    // leave the root. Swift does not surface the constant, so it is spelled out.
    case Self.notCapableErrorCode: .escapesRoot(relativePath)
    case EPERM, EACCES: .notReadable(relativePath)
    case ENOTDIR: .notADirectory(relativePath)
    default: .notReadable(relativePath)
    }
  }

  static func describe(name: String, in directoryDescriptor: Int32) -> EvieDirectoryEntry {
    var status = stat()
    let flags = AT_SYMLINK_NOFOLLOW
    guard fstatat(directoryDescriptor, name, &status, flags) == 0 else {
      return EvieDirectoryEntry(name: name, isDirectory: false)
    }
    let isDirectory = (status.st_mode & S_IFMT) == S_IFDIR
    return EvieDirectoryEntry(
      name: name,
      isDirectory: isDirectory,
      byteSize: isDirectory ? nil : Int(status.st_size),
      modifiedAt: Date(timeIntervalSince1970: TimeInterval(status.st_mtimespec.tv_sec))
    )
  }

  /// A NUL byte in the first few kilobytes means this is not text.
  static func looksBinary(_ data: Data) -> Bool {
    data.prefix(binarySniffBytes).contains(0)
  }
}

extension EvieScopedFileReader.ReaderError: LocalizedError {
  public var errorDescription: String? {
    switch self {
    case .invalidPath(let path):
      "O caminho \(path) não é válido."
    case .escapesRoot(let path):
      "\(path) sai da pasta que você autorizou, então não vou abrir."
    case .notFound(let path):
      "Não encontrei \(path)."
    case .denied(let name):
      "\(name) fica fora do alcance mesmo dentro de uma pasta autorizada."
    case .notReadable(let path):
      "Não consigo ler \(path)."
    case .notADirectory(let path):
      "\(path) não é uma pasta."
    case .isADirectory(let path):
      "\(path) é uma pasta, não um arquivo."
    case .notText(let path):
      "\(path) não é texto."
    case .rootUnavailable(let name):
      "A pasta \(name) não está mais acessível."
    }
  }
}
