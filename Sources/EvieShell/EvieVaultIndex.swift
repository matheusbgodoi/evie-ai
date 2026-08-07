import EvieCore
import Foundation
import NaturalLanguage

/// Turns text into a vector with the model macOS already ships.
///
/// `NLContextualEmbedding` rather than `NLEmbedding.sentenceEmbedding`, and the
/// reason is measured rather than assumed: on this Mac, over five thousand real
/// passages from the user's own vault, the contextual model took 8 ms each while
/// the static sentence embedding took 30 ms. The contextual one is both the
/// better representation and nearly four times faster, which made the choice
/// easy in a way it usually is not.
///
/// `@unchecked Sendable` with a lock rather than `@preconcurrency`: the model is
/// not `Sendable` and the embedding runs on a detached task, so the safety has to
/// be real rather than asserted away. The lock is uncontended in practice —
/// indexing is one pass over the vault — and correctness here is worth more than
/// the nanoseconds.
final class EvieContextualEmbedder: EvieSemanticEmbedder, @unchecked Sendable {
  private let model: NLContextualEmbedding?
  private let lock = NSLock()

  init(language: NLLanguage = .portuguese) {
    guard let model = NLContextualEmbedding(language: language), model.hasAvailableAssets
    else {
      self.model = nil
      return
    }
    try? model.load()
    self.model = model
  }

  var isAvailable: Bool {
    model != nil
  }

  /// One vector for a whole passage, by averaging its token vectors.
  ///
  /// Mean pooling: the standard way to get a sentence vector out of a
  /// token-level model, and the one the distance thresholds elsewhere were
  /// measured against.
  func vector(for text: String) -> [Float]? {
    guard let model else {
      return nil
    }
    lock.lock()
    defer { lock.unlock() }
    guard let result = try? model.embeddingResult(for: text, language: .portuguese) else {
      return nil
    }

    var sum = [Float](repeating: 0, count: model.dimension)
    var count = 0
    result.enumerateTokenVectors(in: text.startIndex..<text.endIndex) { vector, _ in
      for index in 0..<min(sum.count, vector.count) {
        sum[index] += Float(vector[index])
      }
      count += 1
      return true
    }
    guard count > 0 else {
      return nil
    }
    return sum.map { $0 / Float(count) }
  }
}

/// The vault, chunked and embedded, kept between launches.
///
/// Building it costs about forty seconds over five thousand passages, which is
/// far too long to pay per question and entirely acceptable once. So it is
/// cached, and a rebuild only touches files whose modification date changed —
/// editing one note re-embeds one note.
///
/// The cache is derived data and is treated as such: a damaged or stale one is
/// discarded and rebuilt rather than repaired, because the source of truth is the
/// folder and always will be.
@MainActor
final class EvieVaultIndex: ObservableObject {
  /// Passages currently indexed, and their vectors, in the same order.
  @Published private(set) var passages: [EvieVaultPassage] = []
  @Published private(set) var vectors: [[Float]?] = []
  @Published private(set) var isBuilding = false
  @Published private(set) var lastBuilt: Date?

  /// A ceiling, so pointing her at a folder of ten thousand files does not turn
  /// into a twenty-minute build nobody asked for.
  nonisolated static let maximumPassages = 12_000

  private let embedder = EvieContextualEmbedder()
  private let cacheURL: URL
  private var buildTask: Task<Void, Never>?

  init(cacheURL: URL = EvieVaultIndex.defaultCacheURL) {
    self.cacheURL = cacheURL
    loadCache()
  }

  /// The extension changed with the format, on purpose: a file called `.json`
  /// that is not JSON is a trap for anybody who opens it, and keeping the two
  /// names apart is what lets the loader recognise the old cache and convert it
  /// rather than guess at it.
  static var defaultCacheURL: URL {
    EvieConfigurationLoader.defaultFileURL
      .deletingLastPathComponent()
      .appendingPathComponent("vault-index.evx", isDirectory: false)
  }

  var isSemanticSearchAvailable: Bool {
    embedder.isAvailable
  }

  var retriever: EvieVaultRetriever {
    EvieVaultRetriever(embedder: embedder.isAvailable ? embedder : nil)
  }

  var passageCount: Int {
    passages.count
  }

  /// Rebuilds from the granted folders, re-embedding only what changed.
  ///
  /// Runs off the main actor for the embedding, which is the expensive part, and
  /// publishes once at the end rather than per file — a progress bar that
  /// redraws five thousand times costs more than the work it reports.
  func rebuild(roots: [EvieFileRoot]) {
    buildTask?.cancel()
    guard !roots.isEmpty else {
      passages = []
      vectors = []
      writeCache()
      return
    }

    isBuilding = true
    let existing = Dictionary(
      uniqueKeysWithValues: zip(passages, vectors).map { ($0.searchableText, $1) }
    )
    let embedder = embedder

    buildTask = Task { @MainActor [weak self] in
      let harvested = await Task.detached(priority: .utility) {
        Self.collect(from: roots)
      }.value
      guard !Task.isCancelled else {
        return
      }

      let embedded = await Task.detached(priority: .utility) {
        harvested.map { passage -> [Float]? in
          // Already embedded and unchanged: the text is the key, so an edit
          // elsewhere in the note does not re-embed this paragraph.
          if let cached = existing[passage.searchableText] {
            return cached
          }
          return embedder.vector(for: passage.searchableText)
        }
      }.value
      guard !Task.isCancelled, let self else {
        return
      }

      passages = harvested
      vectors = embedded
      lastBuilt = Date()
      isBuilding = false
      writeCache()
    }
  }

  /// Reads every text file in the granted folders and cuts it into passages.
  /// Directory names that cannot hold notes, and cost a great deal to walk.
  ///
  /// Without this the index walks everything inside a granted folder. Measured
  /// on this Mac with the home folder granted: over a million files in more than
  /// 130,000 directories, and still going after 25 seconds — 354,584 of them
  /// under `~/Library` and 57,708 under `~/.bun` alone. The build never
  /// finished, so every search of the notes answered "nao achei nada" while the
  /// walk ground on in the background.
  ///
  /// Matched on a directory's own name rather than a path, so it prunes at any
  /// depth.
  nonisolated static let skippedDirectories: Set<String> = [
    "node_modules", "DerivedData", "Caches", "Containers", "Group Containers",
    "Application Support", "Logs", "Cookies", "WebKit", "Safari", "Mail",
    "Messages", "Photos Library.photoslibrary", "Music", "Movies",
    "site-packages", "venv", "vendor", "Pods", "target", "dist", "build",
    "__pycache__", "Trash",
  ]

  /// The only places inside `~/Library` worth walking.
  ///
  /// Blanket-skipping `Library` is the obvious move and it is wrong here:
  /// Obsidian's iCloud vault lives at `Library/Mobile Documents`, and Google
  /// Drive and OneDrive appear under `Library/CloudStorage`. Those are exactly
  /// the notes somebody means. Everything else under Library is application
  /// state, and none of it is anybody's writing.
  nonisolated static let librarySubdirectories: Set<String> = [
    "Mobile Documents", "CloudStorage",
  ]

  /// A ceiling on directories visited, so a folder nobody anticipated cannot
  /// turn the build into something that never ends.
  nonisolated static let maximumDirectories = 40_000

  /// Whether to walk into a directory at all.
  nonisolated static func shouldSkip(directory name: String, at components: [String]) -> Bool {
    if name.hasPrefix(".") || skippedDirectories.contains(name) {
      return true
    }
    if components.count >= 2, components[0] == "Library" {
      return !librarySubdirectories.contains(components[1])
    }
    return false
  }

  /// The folders worth reading as notes.
  ///
  /// "Which folders may she read files from" and "which folders are her notes"
  /// are different questions, and conflating them is what broke this. Granting
  /// the home folder is a reasonable answer to the first and a terrible answer
  /// to the second: the first pruned build filled its entire 12,000-passage
  /// budget on `Documents` and this project's own source tree, and stopped
  /// before it ever reached the Obsidian vault — so the notes the whole feature
  /// exists for were the one thing missing from it.
  ///
  /// When a vault is present, it *is* the notes and nothing else is. Only when
  /// there is none does the granted folder stand in, pruned.
  nonisolated static func noteRoots(from roots: [EvieFileRoot]) -> [EvieFileRoot] {
    let vaults = roots.compactMap { root -> EvieFileRoot? in
      for candidate in EvieRootsViewModel.obsidianVaultURLs
      where candidate.path.hasPrefix(root.url.path) {
        return EvieFileRoot(
          displayName: candidate.lastPathComponent,
          path: candidate.path,
          bookmark: root.bookmark
        )
      }
      return nil
    }
    return vaults.isEmpty ? roots : vaults
  }

  nonisolated static func collect(from granted: [EvieFileRoot]) -> [EvieVaultPassage] {
    var passages: [EvieVaultPassage] = []
    var visitedDirectories = 0
    let roots = noteRoots(from: granted)

    for root in roots {
      guard
        // No `.skipsHiddenFiles`: `~/Library` carries the hidden flag, and that
        // option discards everything beneath a hidden ancestor — so a vault
        // inside it enumerates as empty. Measured: 701 entries without the
        // option, 0 with it. Dotfiles are pruned by name instead.
        let walker = FileManager.default.enumerator(
          at: root.url,
          includingPropertiesForKeys: [.isRegularFileKey, .isDirectoryKey],
          options: [.skipsPackageDescendants]
        )
      else {
        continue
      }
      for case let url as URL in walker {
        guard passages.count < maximumPassages, visitedDirectories < maximumDirectories
        else {
          return passages
        }
        let relative = url.path
          .replacingOccurrences(of: root.url.path, with: "")
          .trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        let components = relative.split(separator: "/").map(String.init)

        if (try? url.resourceValues(forKeys: [.isDirectoryKey]))?.isDirectory == true {
          visitedDirectories += 1
          // Pruned with `skipDescendants` rather than filtered afterwards: not
          // reading a directory is cheap, not walking into it is the saving.
          if shouldSkip(directory: url.lastPathComponent, at: components) {
            walker.skipDescendants()
          }
          continue
        }

        // The reader's denylist, applied inside the granted folder rather than
        // to the whole path — checking the absolute path refused a vault under
        // `~/Library/Mobile Documents` because a component was called `Library`.
        guard
          !components.contains(where: { $0.hasPrefix(".") }),
          !components.contains(where: EvieScopedFileReader.isDenied),
          EvieFileToolbox.isProbablyText(url.lastPathComponent),
          let text = try? String(contentsOf: url, encoding: .utf8)
        else {
          continue
        }
        passages += EvieVaultChunker.chunk(
          markdown: text,
          path: relative,
          rootID: root.id
        )
      }
    }
    return passages
  }
}

extension EvieVaultIndex {
  /// Where the cache written by every Evie before this one still sits.
  ///
  /// Derived from `cacheURL` rather than from the configuration folder, so a
  /// test pointing the index at a temporary directory finds the old file in that
  /// same directory.
  var legacyCacheURL: URL {
    cacheURL.deletingPathExtension().appendingPathExtension("json")
  }

  /// Reads the cache, converting the old one if that is what is there.
  ///
  /// A damaged file of either kind falls through and leaves the index empty,
  /// which is the behaviour this always had: the folder is the source of truth,
  /// and a cache that cannot be read is a cache to be rebuilt rather than
  /// repaired. `EvieVaultIndexFile` refuses a truncated file outright instead of
  /// returning the passages it managed to read, so "empty and rebuilding" is the
  /// only failure state — never a half-loaded index that quietly answers fewer
  /// questions than it should.
  fileprivate func loadCache() {
    guard
      let document = EvieVaultIndexFile.loadUpgrading(
        cacheURL: cacheURL,
        legacyURL: legacyCacheURL
      )
    else {
      return
    }
    passages = document.passages
    vectors = document.vectors
    lastBuilt = document.builtAt
  }

  fileprivate func writeCache() {
    let document = EvieVaultIndexFile.Document(
      builtAt: Date(),
      passages: passages,
      vectors: vectors
    )
    try? FileManager.default.createDirectory(
      at: cacheURL.deletingLastPathComponent(),
      withIntermediateDirectories: true,
      attributes: [.posixPermissions: 0o700]
    )
    try? EvieVaultIndexFile.write(document, to: cacheURL)
  }
}
