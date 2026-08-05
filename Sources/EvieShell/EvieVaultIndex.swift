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

  static var defaultCacheURL: URL {
    EvieConfigurationLoader.defaultFileURL
      .deletingLastPathComponent()
      .appendingPathComponent("vault-index.json", isDirectory: false)
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
  nonisolated static func collect(from roots: [EvieFileRoot]) -> [EvieVaultPassage] {
    var passages: [EvieVaultPassage] = []

    for root in roots {
      guard
        // No `.skipsHiddenFiles`, and the reason is worth keeping: `~/Library`
        // carries the hidden flag, and that option discards everything beneath a
        // hidden ancestor — so a vault inside it, which is exactly where
        // Obsidian's iCloud vault lives, enumerates as *empty*. Measured on this
        // Mac: 701 entries without the option, 0 with it. Dotfiles are filtered
        // below instead, which is what was actually wanted.
        let walker = FileManager.default.enumerator(
          at: root.url,
          includingPropertiesForKeys: [.isRegularFileKey],
          options: [.skipsPackageDescendants]
        )
      else {
        continue
      }
      for case let url as URL in walker {
        guard passages.count < maximumPassages else {
          return passages
        }
        let relative = url.path
          .replacingOccurrences(of: root.url.path, with: "")
          .trimmingCharacters(in: CharacterSet(charactersIn: "/"))

        // The same denylist the reader uses, applied *inside* the granted folder
        // rather than to the whole path. Checking the absolute path meant a vault
        // living in `~/Library/Mobile Documents` — which is where Obsidian's
        // iCloud vault is — was refused entirely, because one of the components
        // on the way to it happened to be called `Library`.
        let components = relative.split(separator: "/").map(String.init)
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
  fileprivate struct CachedIndex: Codable {
    let schemaVersion: Int
    let builtAt: Date
    let entries: [Entry]

    struct Entry: Codable {
      let noteTitle: String
      let headingPath: [String]
      let text: String
      let path: String
      let rootID: String
      let vector: [Float]?
    }
  }

  fileprivate static let schemaVersion = 1

  fileprivate func loadCache() {
    guard let data = try? Data(contentsOf: cacheURL, options: [.mappedIfSafe]),
      let cached = try? JSONDecoder().decode(CachedIndex.self, from: data),
      cached.schemaVersion == Self.schemaVersion
    else {
      return
    }
    passages = cached.entries.map {
      EvieVaultPassage(
        noteTitle: $0.noteTitle,
        headingPath: $0.headingPath,
        text: $0.text,
        path: $0.path,
        rootID: $0.rootID
      )
    }
    vectors = cached.entries.map(\.vector)
    lastBuilt = cached.builtAt
  }

  fileprivate func writeCache() {
    let entries = zip(passages, vectors).map { passage, vector in
      CachedIndex.Entry(
        noteTitle: passage.noteTitle,
        headingPath: passage.headingPath,
        text: passage.text,
        path: passage.path,
        rootID: passage.rootID,
        vector: vector
      )
    }
    let document = CachedIndex(
      schemaVersion: Self.schemaVersion,
      builtAt: Date(),
      entries: entries
    )
    guard let data = try? JSONEncoder().encode(document) else {
      return
    }
    try? FileManager.default.createDirectory(
      at: cacheURL.deletingLastPathComponent(),
      withIntermediateDirectories: true,
      attributes: [.posixPermissions: 0o700]
    )
    try? data.write(to: cacheURL, options: .atomic)
    // It contains the text of everything indexed, so it is as private as the
    // vault is.
    try? FileManager.default.setAttributes(
      [.posixPermissions: 0o600],
      ofItemAtPath: cacheURL.path
    )
  }
}
