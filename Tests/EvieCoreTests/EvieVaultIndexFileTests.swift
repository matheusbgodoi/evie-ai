import Foundation
import Testing

@testable import EvieCore

@Suite("Evie vault index file")
struct EvieVaultIndexFileTests {
  static func passage(_ index: Int) -> EvieVaultPassage {
    EvieVaultPassage(
      noteTitle: "Nota \(index)",
      headingPath: ["Cluemed", "Captação"],
      text: "Parágrafo \(index) com acentuação, emoji 🌱 e uma vírgula.",
      path: "Cluemed/Nota \(index).md",
      rootID: "raiz"
    )
  }

  static func vector(_ seed: Int, dimension: Int = 8) -> [Float] {
    (0..<dimension).map { Float($0 + seed) / 7 }
  }

  static func document(count: Int, missingEvery: Int = 0) -> EvieVaultIndexFile.Document {
    EvieVaultIndexFile.Document(
      // A fixed moment rather than `Date()`, so the round-trip comparison of the
      // timestamp is exact and does not depend on when the test ran.
      builtAt: Date(timeIntervalSince1970: 1_770_000_000.5),
      passages: (0..<count).map(passage),
      vectors: (0..<count).map { index in
        missingEvery > 0 && index % missingEvery == 0 ? nil : vector(index)
      }
    )
  }

  static func expectSame(
    _ written: EvieVaultIndexFile.Document,
    _ read: EvieVaultIndexFile.Document
  ) {
    #expect(read.passages == written.passages)
    #expect(read.builtAt == written.builtAt)
    #expect(read.vectors.count == written.vectors.count)
    for (left, right) in zip(read.vectors, written.vectors) {
      // Bit patterns, not values: this is the assertion that a vector came back
      // exactly as it went in rather than approximately.
      #expect(left?.map(\.bitPattern) == right?.map(\.bitPattern))
    }
  }

  // MARK: - Round trip

  @Test("what was written is what is read back")
  func roundTrips() throws {
    let written = Self.document(count: 40)

    let read = try EvieVaultIndexFile.decode(EvieVaultIndexFile.encode(written))

    Self.expectSame(written, read)
  }

  /// A passage the embedder refused still occupies a row, and the vectors after
  /// it must not shift up into its place.
  @Test("passages without a vector keep their position")
  func keepsAlignmentAroundMissingVectors() throws {
    let written = Self.document(count: 20, missingEvery: 3)

    let read = try EvieVaultIndexFile.decode(EvieVaultIndexFile.encode(written))

    #expect(read.vectors.filter { $0 == nil }.count == 7)
    Self.expectSame(written, read)
  }

  /// An index with nothing in it is a legitimate state — it is what
  /// `rebuild(roots: [])` writes when the last folder is revoked — and it must
  /// read back as empty rather than as a damaged file that triggers a rebuild.
  @Test("an empty index is a valid file")
  func encodesNothing() throws {
    let written = EvieVaultIndexFile.Document(builtAt: Date(), passages: [], vectors: [])

    let data = try EvieVaultIndexFile.encode(written)
    let read = try EvieVaultIndexFile.decode(data)

    // Header, an empty metadata document and nothing else — no vector block at
    // all, and a dimension of zero rather than a guess at one.
    #expect(data.count < EvieVaultIndexFile.headerLength + 32)
    #expect(read.passages.isEmpty)
    #expect(read.vectors.isEmpty)
  }

  @Test("a file survives a trip through the disk")
  func roundTripsThroughAFile() throws {
    let url = FileManager.default.temporaryDirectory
      .appendingPathComponent("evie-index-\(UUID().uuidString).evx")
    defer { try? FileManager.default.removeItem(at: url) }
    let written = Self.document(count: 12)

    try EvieVaultIndexFile.write(written, to: url)

    Self.expectSame(written, try EvieVaultIndexFile.read(contentsOf: url))
  }

  // MARK: - Numbers that are not numbers

  /// NaN and the infinities survive because the format never converts a float to
  /// anything — it copies the four bytes. This is asserted rather than assumed
  /// because the old format could not do it at all: `JSONEncoder` throws on a
  /// non-conforming float by default, so a single NaN vector meant `writeCache`
  /// silently wrote nothing and the whole index was rebuilt on the next launch.
  @Test("NaN and infinity come back exactly as they went in")
  func carriesNonFiniteFloats() throws {
    let strange: [Float] = [
      .nan, -.nan, .infinity, -.infinity, .zero, -.zero,
      .leastNonzeroMagnitude, .greatestFiniteMagnitude,
    ]
    let written = EvieVaultIndexFile.Document(
      builtAt: Date(timeIntervalSince1970: 0),
      passages: [Self.passage(0)],
      vectors: [strange]
    )

    let read = try EvieVaultIndexFile.decode(EvieVaultIndexFile.encode(written))

    #expect(read.vectors[0]?.map(\.bitPattern) == strange.map(\.bitPattern))
    #expect(read.vectors[0]?[0].isNaN == true)
    #expect(read.vectors[0]?[5].sign == .minus)
  }

  // MARK: - Refusals

  @Test("a file cut off mid-vector is refused, not half-read")
  func refusesTruncation() throws {
    let data = try EvieVaultIndexFile.encode(Self.document(count: 30))

    // Two bytes into the last vector, which is the case the size arithmetic
    // exists to catch: everything before it is perfectly readable.
    #expect(throws: EvieVaultIndexFile.Failure.self) {
      try EvieVaultIndexFile.decode(data.prefix(data.count - 30))
    }
    #expect(throws: EvieVaultIndexFile.Failure.self) {
      try EvieVaultIndexFile.decode(data.prefix(EvieVaultIndexFile.headerLength + 4))
    }
    #expect(throws: EvieVaultIndexFile.Failure.self) {
      try EvieVaultIndexFile.decode(Data())
    }
  }

  @Test("a file longer than its header claims is refused")
  func refusesTrailingBytes() throws {
    var data = try EvieVaultIndexFile.encode(Self.document(count: 4))
    data.append(contentsOf: [0, 0, 0, 0])

    #expect(throws: EvieVaultIndexFile.Failure.self) {
      try EvieVaultIndexFile.decode(data)
    }
  }

  @Test("damage inside the vectors is refused when it changes the length")
  func refusesADamagedHeader() throws {
    var data = try EvieVaultIndexFile.encode(Self.document(count: 4))
    // The dimension, at offset 12. Claiming a wider vector than was written is
    // indistinguishable from a truncated file, which is the point.
    data[12] = 99

    #expect(throws: EvieVaultIndexFile.Failure.self) {
      try EvieVaultIndexFile.decode(data)
    }
  }

  @Test("a version from the future is refused rather than guessed at")
  func refusesAnotherVersion() throws {
    var data = try EvieVaultIndexFile.encode(Self.document(count: 4))
    data[8] = UInt8(EvieVaultIndexFile.formatVersion) + 1

    #expect(
      throws: EvieVaultIndexFile.Failure.unsupportedVersion(EvieVaultIndexFile.formatVersion + 1)
    ) {
      try EvieVaultIndexFile.decode(data)
    }
  }

  @Test("vectors of different lengths are refused at the door")
  func refusesRaggedVectors() {
    let document = EvieVaultIndexFile.Document(
      builtAt: Date(),
      passages: [Self.passage(0), Self.passage(1)],
      vectors: [Self.vector(0, dimension: 8), Self.vector(1, dimension: 7)]
    )

    #expect(throws: EvieVaultIndexFile.Failure.inconsistentDimension) {
      try EvieVaultIndexFile.encode(document)
    }
  }

  // MARK: - The cache this replaced

  @Test("the old JSON cache is recognised as not being this format")
  func refusesTheOldCache() throws {
    let legacy = try Self.legacyJSON(count: 3)

    #expect(throws: EvieVaultIndexFile.Failure.notThisFormat) {
      try EvieVaultIndexFile.decode(legacy)
    }
  }

  /// The upgrade path: the 57 MB file somebody already has is read once and
  /// carries its vectors across intact, so nobody pays forty seconds of
  /// re-embedding for a vault that has not changed.
  @Test("the old JSON cache converts without losing anything")
  func readsTheOldCache() throws {
    let legacy = try Self.legacyJSON(count: 6)

    let read = try EvieVaultIndexFile.decodeLegacyJSON(legacy)
    let rewritten = try EvieVaultIndexFile.decode(EvieVaultIndexFile.encode(read))

    #expect(read.passages.count == 6)
    #expect(read.vectors[2]?.count == 8)
    Self.expectSame(read, rewritten)
  }

  @Test("a new-format file is not mistaken for the old cache")
  func doesNotReadTheNewFileAsJSON() throws {
    let data = try EvieVaultIndexFile.encode(Self.document(count: 2))

    #expect(throws: EvieVaultIndexFile.Failure.notThisFormat) {
      try EvieVaultIndexFile.decodeLegacyJSON(data)
    }
  }

  // MARK: - Updating with the old cache in place

  /// What happens to somebody who updates Evie with the 57 MB JSON file sitting
  /// there: it is read once, rewritten in the new format, and removed. The
  /// vectors arrive intact and the build date is the vault's, not the moment of
  /// the conversion.
  @Test("an old cache is converted in place, not rebuilt from nothing")
  func upgradesTheOldCache() throws {
    let folder = try Self.scratchFolder()
    defer { try? FileManager.default.removeItem(at: folder) }
    let cacheURL = folder.appendingPathComponent("vault-index.evx")
    let legacyURL = folder.appendingPathComponent("vault-index.json")
    try Self.legacyJSON(count: 5).write(to: legacyURL)

    let loaded = try #require(
      EvieVaultIndexFile.loadUpgrading(cacheURL: cacheURL, legacyURL: legacyURL)
    )

    #expect(loaded.passages.count == 5)
    #expect(loaded.builtAt == Date(timeIntervalSince1970: 1_770_000_000.5))
    #expect(!FileManager.default.fileExists(atPath: legacyURL.path))
    Self.expectSame(loaded, try EvieVaultIndexFile.read(contentsOf: cacheURL))
    // The cache carries the text of every note indexed, so it is readable by
    // nobody but its owner — including the one written by the conversion, which
    // is a new file and does not inherit the old one's mode.
    let mode = try FileManager.default.attributesOfItem(atPath: cacheURL.path)[.posixPermissions]
    #expect(mode as? Int == 0o600)
  }

  @Test("a damaged cache is discarded rather than half-loaded")
  func refusesToLoadDamage() throws {
    let folder = try Self.scratchFolder()
    defer { try? FileManager.default.removeItem(at: folder) }
    let cacheURL = folder.appendingPathComponent("vault-index.evx")
    let data = try EvieVaultIndexFile.encode(Self.document(count: 50))
    try data.prefix(data.count / 2).write(to: cacheURL)

    let loaded = EvieVaultIndexFile.loadUpgrading(
      cacheURL: cacheURL,
      legacyURL: folder.appendingPathComponent("vault-index.json")
    )

    // Nothing, which is the same answer as "no cache yet" — and the index
    // rebuilds. A partial load would answer questions with a silently smaller
    // vault, which is the failure worth being strict about.
    #expect(loaded?.passages == nil)
  }

  @Test("a fresh install with no cache at all is not an error")
  func loadsNothingFromNothing() throws {
    let folder = try Self.scratchFolder()
    defer { try? FileManager.default.removeItem(at: folder) }

    let loaded = EvieVaultIndexFile.loadUpgrading(
      cacheURL: folder.appendingPathComponent("vault-index.evx"),
      legacyURL: folder.appendingPathComponent("vault-index.json")
    )

    #expect(loaded?.passages == nil)
  }

  static func scratchFolder() throws -> URL {
    let folder = FileManager.default.temporaryDirectory
      .appendingPathComponent("evie-index-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
    return folder
  }

  static func legacyJSON(count: Int) throws -> Data {
    try JSONEncoder().encode(
      EvieVaultIndexFile.LegacyIndex(
        schemaVersion: EvieVaultIndexFile.LegacyIndex.currentSchemaVersion,
        builtAt: Date(timeIntervalSince1970: 1_770_000_000.5),
        entries: (0..<count).map { index in
          let passage = passage(index)
          return EvieVaultIndexFile.LegacyIndex.Entry(
            noteTitle: passage.noteTitle,
            headingPath: passage.headingPath,
            text: passage.text,
            path: passage.path,
            rootID: passage.rootID,
            vector: vector(index)
          )
        }
      )
    )
  }
}
