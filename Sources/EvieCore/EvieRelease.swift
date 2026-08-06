import Foundation

/// A version number, compared the way versions actually order.
///
/// Not a string comparison, which is the bug this exists to prevent: "1.10.0"
/// sorts *below* "1.9.0" as text, so an update would be offered backwards and
/// then never again. Components are compared as numbers, and a pre-release sorts
/// below the release it precedes — "1.2.0-beta.1" is older than "1.2.0", which is
/// the one rule people get wrong when they write this by hand.
public struct EvieVersion: Comparable, Hashable, Sendable, CustomStringConvertible {
  public var components: [Int]
  /// The components with trailing zeros removed, which is the form equality and
  /// hashing use.
  ///
  /// Without it the synthesised `==` compares the arrays as stored, so "1.2" and
  /// "1.2.0" are unequal while `<` says neither is smaller — a type that is
  /// `Comparable` and disagrees with itself. Kept separate from `components` so
  /// the version still prints the way it was written.
  var normalized: [Int] {
    var trimmed = components
    while trimmed.count > 1, trimmed.last == 0 {
      trimmed.removeLast()
    }
    return trimmed
  }

  public static func == (left: Self, right: Self) -> Bool {
    left.normalized == right.normalized && left.prerelease == right.prerelease
  }

  public func hash(into hasher: inout Hasher) {
    hasher.combine(normalized)
    hasher.combine(prerelease)
  }

  /// Everything after the first `-`. Empty means a final release.
  public var prerelease: String

  public var description: String {
    let core = components.map(String.init).joined(separator: ".")
    return prerelease.isEmpty ? core : "\(core)-\(prerelease)"
  }

  /// Reads `v1.2.0`, `1.2`, `1.2.0-beta.1`. Returns nil for anything that has no
  /// leading number at all, so a tag like `nightly` is refused rather than
  /// treated as version zero and offered as an update to everybody.
  public init?(_ text: String) {
    var body = text.trimmingCharacters(in: .whitespacesAndNewlines)
    if body.lowercased().hasPrefix("v") {
      body.removeFirst()
    }
    // Build metadata carries no ordering, by definition, so it is discarded
    // rather than compared.
    if let plus = body.firstIndex(of: "+") {
      body = String(body[body.startIndex..<plus])
    }
    let prerelease: String
    if let dash = body.firstIndex(of: "-") {
      prerelease = String(body[body.index(after: dash)...])
      body = String(body[body.startIndex..<dash])
    } else {
      prerelease = ""
    }

    let parts = body.split(separator: ".", omittingEmptySubsequences: false)
    guard !parts.isEmpty else {
      return nil
    }
    var components: [Int] = []
    for part in parts {
      guard let number = Int(part), number >= 0 else {
        return nil
      }
      components.append(number)
    }
    self.components = components
    self.prerelease = prerelease
  }

  public static func < (left: Self, right: Self) -> Bool {
    // Padded rather than compared by count, so "1.2" and "1.2.0" are equal
    // instead of one being mysteriously older than the other.
    let width = max(left.components.count, right.components.count)
    for index in 0..<width {
      let a = index < left.components.count ? left.components[index] : 0
      let b = index < right.components.count ? right.components[index] : 0
      if a != b {
        return a < b
      }
    }
    switch (left.prerelease.isEmpty, right.prerelease.isEmpty) {
    case (true, true):
      return false
    // A release outranks its own pre-releases.
    case (true, false):
      return false
    case (false, true):
      return true
    case (false, false):
      return left.prerelease.compare(right.prerelease, options: .numeric) == .orderedAscending
    }
  }
}

/// A published release and the file it offers.
public struct EvieRelease: Equatable, Sendable {
  public var version: EvieVersion
  public var tag: String
  public var title: String
  public var notes: String
  public var downloadURL: URL
  public var downloadBytes: Int
  public var isPrerelease: Bool

  public init(
    version: EvieVersion,
    tag: String,
    title: String,
    notes: String,
    downloadURL: URL,
    downloadBytes: Int,
    isPrerelease: Bool
  ) {
    self.version = version
    self.tag = tag
    self.title = title
    self.notes = notes
    self.downloadURL = downloadURL
    self.downloadBytes = downloadBytes
    self.isPrerelease = isPrerelease
  }
}

/// Reads what GitHub's release API returns, and refuses everything else.
///
/// The parsing is strict on purpose. This is the one place where bytes from the
/// network decide what gets executed on the machine, so anything unexpected is
/// a refusal rather than a default: no download address that is not GitHub's own
/// over TLS, no asset that is not a zip, no file larger than a real build.
public enum EvieReleaseFeed {
  /// The hosts GitHub serves release assets from. Pinned because the address
  /// arrives inside the response, and a response is the wrong place to learn
  /// where it is acceptable to download an executable from.
  static let permittedHosts: Set<String> = [
    "github.com",
    "api.github.com",
    "objects.githubusercontent.com",
    "release-assets.githubusercontent.com",
  ]

  /// A ceiling well above a real build and far below anything worth worrying
  /// about. Measured: the current bundle zips to a few megabytes.
  public static let maximumDownloadBytes = 600 * 1024 * 1024

  public static func url(owner: String, repository: String) -> URL {
    URL(string: "https://api.github.com/repos/\(owner)/\(repository)/releases/latest")!
  }

  public enum FeedError: LocalizedError, Equatable {
    case malformed
    case unusableTag(String)
    case noDownloadableAsset
    case untrustedHost(String)
    case tooLarge(Int)

    public var errorDescription: String? {
      switch self {
      case .malformed:
        "O GitHub respondeu de um jeito que eu não reconheço."
      case .unusableTag(let tag):
        "A tag \"\(tag)\" não é um número de versão."
      case .noDownloadableAsset:
        "Essa release não tem um .zip para baixar."
      case .untrustedHost(let host):
        "O download apontava para \(host), que não é um endereço do GitHub."
      case .tooLarge(let bytes):
        "O arquivo tem \(bytes / 1_048_576) MB, acima do limite."
      }
    }
  }

  /// Turns one release object into something installable, or says why not.
  public static func release(from object: [String: Any]) throws -> EvieRelease {
    guard let tag = object["tag_name"] as? String else {
      throw FeedError.malformed
    }
    guard let version = EvieVersion(tag) else {
      throw FeedError.unusableTag(tag)
    }
    guard let assets = object["assets"] as? [[String: Any]] else {
      throw FeedError.malformed
    }

    guard let asset = choose(from: assets) else {
      throw FeedError.noDownloadableAsset
    }
    guard let address = asset["browser_download_url"] as? String,
      let url = URL(string: address)
    else {
      throw FeedError.malformed
    }
    guard url.scheme?.lowercased() == "https", let host = url.host?.lowercased() else {
      throw FeedError.untrustedHost(url.host ?? "endereço sem host")
    }
    guard permittedHosts.contains(host) else {
      throw FeedError.untrustedHost(host)
    }
    let bytes = asset["size"] as? Int ?? 0
    guard bytes <= maximumDownloadBytes else {
      throw FeedError.tooLarge(bytes)
    }

    return EvieRelease(
      version: version,
      tag: tag,
      title: (object["name"] as? String).flatMap { $0.isEmpty ? nil : $0 } ?? tag,
      notes: object["body"] as? String ?? "",
      downloadURL: url,
      downloadBytes: bytes,
      isPrerelease: object["prerelease"] as? Bool ?? false
    )
  }

  /// The one asset worth downloading.
  ///
  /// A zip, and preferably one that names the app — a release often carries
  /// source archives GitHub adds itself, and installing `Source code.zip` would
  /// be a confusing way to fail.
  static func choose(from assets: [[String: Any]]) -> [String: Any]? {
    let zips = assets.filter {
      ($0["name"] as? String)?.lowercased().hasSuffix(".zip") == true
    }
    return zips.first {
      let name = ($0["name"] as? String ?? "").lowercased()
      return name.contains("evie") && !name.contains("source")
    } ?? zips.first { !(($0["name"] as? String ?? "").lowercased().contains("source")) }
  }

  /// Whether a release is worth offering to somebody on `installed`.
  ///
  /// Pre-releases are never offered automatically. Somebody running a stable
  /// build did not ask to test anything.
  public static func isUpgrade(
    _ release: EvieRelease,
    from installed: EvieVersion,
    acceptingPrereleases: Bool = false
  ) -> Bool {
    guard acceptingPrereleases || !release.isPrerelease else {
      return false
    }
    return release.version > installed
  }
}
