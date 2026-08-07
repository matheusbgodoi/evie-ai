import Foundation

/// The vault index on disk: a small header, the passages as JSON, the vectors as
/// a block of raw `Float32`.
///
/// The whole index used to be one JSON document, and the cost of that was
/// measured rather than suspected. 8,629 passages with a 512-dimension vector
/// each are 17 MB of numbers; written as decimal strings — `0.043117132`, eleven
/// or twelve characters and a comma for every one of them — the file was 57 MB.
/// Reading it meant decoding 4.4 million `Float`s out of text, one
/// `Decodable` allocation at a time, and the process footprint went to 253 MB
/// three seconds after launch for an index that occupies 11 MB once it is
/// settled. None of that bought anything: a float is four bytes, and it was the
/// container spending the other eight.
///
/// So the two halves are stored the way each wants to be stored. The passages
/// are text of wildly varying length with a shape that will change again, and
/// JSON is genuinely the right tool for them — they are about 4 MB and decode in
/// a blink. The vectors are a rectangle of fixed-width numbers, and for those
/// JSON is nothing but overhead. They go at the end, in one contiguous run, so a
/// reader knows where each vector begins by arithmetic and can copy it straight
/// into the array it will live in.
///
/// **Byte order and float width are part of the format.** Integers in the header
/// are little-endian; the vector block is raw IEEE-754 `binary32`, four bytes
/// each, in the host's own order. That is a deliberate refusal to be portable:
/// byte-swapping 4.4 million floats on every load would spend real time
/// defending against a case that cannot happen, since this file is derived data
/// written and read by the same application on the same Mac, and every Mac is
/// little-endian. `supportsThisHost` states the assumption out loud and decoding
/// refuses rather than misreading if it is ever false.
public enum EvieVaultIndexFile {
  /// Eight bytes, so the first thing any reader learns is whether this is the
  /// file it thinks it is. The old cache begins with `{`, which fails here on
  /// the very first byte instead of somewhere deep inside a decoder.
  public static let magic = Array("EVIEIDX1".utf8)

  /// Bumped when the layout changes. A file from a version this code does not
  /// know is refused, not guessed at — the index is derived data and rebuilding
  /// is always available, so there is never a reason to read a format
  /// approximately.
  public static let formatVersion: UInt32 = 1

  /// magic(8) version(4) dimension(4) passages(4) vectors(4) metadata(8) builtAt(8)
  static let headerLength = 40

  /// The vector block starts on a 16-byte boundary.
  ///
  /// Nothing here requires it — every read is a `copyBytes` that does not care
  /// about alignment. It costs at most 15 bytes of padding and it keeps the door
  /// open for a reader that wants to hand the mapped pages to something with an
  /// alignment requirement, which is the whole reason for storing the vectors
  /// contiguously in the first place.
  static let vectorAlignment = 16

  /// What a cache file holds. Vectors are positional: `vectors[i]` belongs to
  /// `passages[i]`, and `nil` means that passage was never embedded.
  public struct Document: Sendable {
    public var builtAt: Date
    public var passages: [EvieVaultPassage]
    public var vectors: [[Float]?]

    public init(builtAt: Date, passages: [EvieVaultPassage], vectors: [[Float]?]) {
      self.builtAt = builtAt
      self.passages = passages
      self.vectors = vectors
    }
  }

  public enum Failure: Error, Equatable {
    /// Not this format at all — most likely the 57 MB JSON cache from an older
    /// Evie. `decodeLegacyJSON` is what to try next.
    case notThisFormat
    case unsupportedVersion(UInt32)
    /// The file ends before the layout says it should: a write interrupted
    /// halfway, or a vector cut in two.
    case truncated(expected: Int, found: Int)
    /// Longer than the layout says. Not a real failure mode of an atomic write,
    /// which is why it is suspicious enough to refuse.
    case trailingBytes(expected: Int, found: Int)
    case damagedMetadata
    /// One passage has a vector and another has a vector of a different length.
    /// The file stores one dimension for the whole block; a caller holding
    /// ragged vectors is a bug upstream, and writing half of them would hide it.
    case inconsistentDimension
    /// More passages than vectors or the other way round. They are positional,
    /// so writing them out of step would silently attach every vector to the
    /// wrong passage.
    case mismatchedCounts
    /// A big-endian host, or one where `Float` is not four bytes. Neither exists
    /// on macOS; both would silently produce nonsense vectors.
    case unsupportedHost
  }

  /// The two things the raw vector block assumes about the machine reading it.
  static var supportsThisHost: Bool {
    UInt32(1).littleEndian == 1 && MemoryLayout<Float>.size == 4
  }

  // MARK: - Writing

  public static func encode(_ document: Document) throws -> Data {
    guard supportsThisHost else {
      throw Failure.unsupportedHost
    }
    guard document.passages.count == document.vectors.count else {
      throw Failure.mismatchedCounts
    }

    let present = document.vectors.compactMap { $0 }
    let dimension = present.first?.count ?? 0
    guard present.allSatisfy({ $0.count == dimension }) else {
      throw Failure.inconsistentDimension
    }

    let metadata = try JSONEncoder().encode(
      Metadata(
        entries: zip(document.passages, document.vectors).map { passage, vector in
          Metadata.Entry(
            noteTitle: passage.noteTitle,
            headingPath: passage.headingPath,
            text: passage.text,
            path: passage.path,
            rootID: passage.rootID,
            hasVector: vector != nil
          )
        }
      )
    )

    var file = Data()
    file.reserveCapacity(
      headerLength + metadata.count + vectorAlignment
        + present.count * dimension * MemoryLayout<Float>.size
    )
    file.append(contentsOf: magic)
    file.append(littleEndian: formatVersion)
    file.append(littleEndian: UInt32(dimension))
    file.append(littleEndian: UInt32(document.passages.count))
    file.append(littleEndian: UInt32(present.count))
    file.append(littleEndian: UInt64(metadata.count))
    file.append(littleEndian: document.builtAt.timeIntervalSince1970.bitPattern)
    file.append(metadata)
    file.append(
      contentsOf: repeatElement(0, count: padding(after: headerLength + metadata.count))
    )
    for vector in present {
      vector.withUnsafeBytes { file.append(contentsOf: $0) }
    }
    return file
  }

  public static func write(_ document: Document, to url: URL) throws {
    // Atomic, because a cache half-replaced by an interrupted write is the one
    // failure the reader below cannot distinguish from a cache that is simply
    // shorter than it claims.
    try encode(document).write(to: url, options: .atomic)
    // It holds the text of everything indexed, so it is as private as the vault
    // is. Set here rather than by the caller because an atomic write replaces
    // the file, and with it whatever permissions the old one had.
    try? FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
  }

  /// Reads the cache, converting the old JSON one if that is what is there.
  ///
  /// Somebody updating Evie has a 57 MB `vault-index.json` sitting in
  /// Application Support and no `.evx` at all. The two honest options were to
  /// ignore it and rebuild — forty seconds of re-embedding a vault that has not
  /// changed a line — or to read it once and write it out in the new format.
  /// This does the second, and then removes the old file, which is 57 MB of the
  /// vault's own text and no longer read by anything.
  ///
  /// The build date is carried across rather than reset to now: it is the date
  /// the vault was last read, and the conversion did not read the vault.
  ///
  /// `nil` when there is nothing readable, which is the same answer as "no cache
  /// yet" on purpose — a damaged cache and an absent one both mean rebuild.
  public static func loadUpgrading(cacheURL: URL, legacyURL: URL) -> Document? {
    if let document = try? read(contentsOf: cacheURL) {
      return document
    }
    guard let data = try? Data(contentsOf: legacyURL, options: [.mappedIfSafe]),
      let document = try? decodeLegacyJSON(data)
    else {
      return nil
    }
    // The old file is only removed once the new one is on disk. A conversion
    // that fails halfway must leave the owner with the cache they had.
    if (try? write(document, to: cacheURL)) != nil {
      try? FileManager.default.removeItem(at: legacyURL)
    }
    return document
  }

  // MARK: - Reading

  /// Reads a cache file without pulling all of it into memory.
  ///
  /// `.mappedIfSafe` leaves the file in the page cache and hands back a window
  /// onto it; the only bytes that become resident are the ones actually touched.
  /// The passages are touched — they are decoded into Swift objects — but each
  /// vector is copied exactly once, from the mapping into the `[Float]` it will
  /// spend the rest of the run in. No intermediate `Data`, no `Array(data)`, and
  /// nothing that holds the whole 17 MB block and a copy of it at the same time.
  public static func read(contentsOf url: URL) throws -> Document {
    try decode(Data(contentsOf: url, options: [.mappedIfSafe]))
  }

  public static func decode(_ data: Data) throws -> Document {
    guard supportsThisHost else {
      throw Failure.unsupportedHost
    }
    guard data.count >= headerLength, data.starts(with: magic) else {
      throw Failure.notThisFormat
    }

    let version: UInt32 = data.littleEndianInteger(at: 8)
    guard version == formatVersion else {
      throw Failure.unsupportedVersion(version)
    }

    let dimension = Int(data.littleEndianInteger(at: 12) as UInt32)
    let passageCount = Int(data.littleEndianInteger(at: 16) as UInt32)
    let vectorCount = Int(data.littleEndianInteger(at: 20) as UInt32)
    let metadataLength = Int(data.littleEndianInteger(at: 24) as UInt64)
    let builtAt = Date(
      timeIntervalSince1970: Double(bitPattern: data.littleEndianInteger(at: 32))
    )

    let metadataEnd = headerLength + metadataLength
    let vectorsStart = metadataEnd + padding(after: metadataEnd)
    let stride = dimension * MemoryLayout<Float>.size
    let expected = vectorsStart + vectorCount * stride
    // Both directions of "the file is not the size the header says". Short means
    // truncated — the interesting case, and the one that catches a vector cut in
    // half, since the arithmetic above counts whole vectors only. Long means
    // something appended to a file that is written atomically and never appended
    // to, which is not a state worth trying to interpret.
    guard data.count >= expected else {
      throw Failure.truncated(expected: expected, found: data.count)
    }
    guard data.count == expected else {
      throw Failure.trailingBytes(expected: expected, found: data.count)
    }

    let base = data.startIndex
    guard
      let metadata = try? JSONDecoder().decode(
        Metadata.self,
        from: data[(base + headerLength)..<(base + metadataEnd)]
      ),
      metadata.entries.count == passageCount,
      metadata.entries.filter(\.hasVector).count == vectorCount
    else {
      throw Failure.damagedMetadata
    }

    var vectors: [[Float]?] = []
    vectors.reserveCapacity(passageCount)
    var read = 0
    for entry in metadata.entries {
      guard entry.hasVector else {
        vectors.append(nil)
        continue
      }
      let start = base + vectorsStart + read * stride
      var vector = [Float](repeating: 0, count: dimension)
      _ = vector.withUnsafeMutableBytes { destination in
        data.copyBytes(to: destination, from: start..<(start + stride))
      }
      vectors.append(vector)
      read += 1
    }

    return Document(
      builtAt: builtAt,
      passages: metadata.entries.map {
        EvieVaultPassage(
          noteTitle: $0.noteTitle,
          headingPath: $0.headingPath,
          text: $0.text,
          path: $0.path,
          rootID: $0.rootID
        )
      },
      vectors: vectors
    )
  }

  // MARK: - The cache this replaced

  /// Reads the old all-JSON cache, so somebody who updates Evie with a 57 MB
  /// `vault-index.json` sitting there gets their index converted instead of
  /// rebuilt.
  ///
  /// This is the expensive read the new format exists to avoid, and it is paid
  /// exactly once, on the first launch after the update — against forty seconds
  /// of re-embedding the whole vault, which is the alternative.
  public static func decodeLegacyJSON(_ data: Data) throws -> Document {
    guard let legacy = try? JSONDecoder().decode(LegacyIndex.self, from: data),
      legacy.schemaVersion == LegacyIndex.currentSchemaVersion
    else {
      throw Failure.notThisFormat
    }
    return Document(
      builtAt: legacy.builtAt,
      passages: legacy.entries.map {
        EvieVaultPassage(
          noteTitle: $0.noteTitle,
          headingPath: $0.headingPath,
          text: $0.text,
          path: $0.path,
          rootID: $0.rootID
        )
      },
      vectors: legacy.entries.map(\.vector)
    )
  }

  struct LegacyIndex: Codable {
    static let currentSchemaVersion = 1

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

  // MARK: - Layout arithmetic

  struct Metadata: Codable {
    let entries: [Entry]

    struct Entry: Codable {
      let noteTitle: String
      let headingPath: [String]
      let text: String
      let path: String
      let rootID: String
      /// Which passages take a vector out of the block, and in what order. A
      /// passage the embedder could not handle still occupies a row here, so the
      /// two arrays stay aligned, but costs nothing in the block.
      let hasVector: Bool
    }
  }

  static func padding(after offset: Int) -> Int {
    (vectorAlignment - offset % vectorAlignment) % vectorAlignment
  }
}

extension Data {
  fileprivate mutating func append<T: FixedWidthInteger>(littleEndian value: T) {
    Swift.withUnsafeBytes(of: value.littleEndian) { append(contentsOf: $0) }
  }

  /// `loadUnaligned` because the header is packed and offsets do not respect the
  /// natural alignment of what sits at them.
  fileprivate func littleEndianInteger<T: FixedWidthInteger>(at offset: Int) -> T {
    let raw = withUnsafeBytes { $0.loadUnaligned(fromByteOffset: offset, as: T.self) }
    return T(littleEndian: raw)
  }
}
