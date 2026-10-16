import Foundation

/// Persists Evie's non-secret model profiles in the versioned JSON format
/// consumed by `EvieConfigurationLoader`, always as the current schema (v2).
///
/// Credentials intentionally have no representation here: a profile holds where
/// its key is kept, never the key. The parent directory and file are restricted
/// to the current user after every write.
public struct EvieConfigurationStore: Sendable {
  /// The variables that decide *which* file and *which* profile a save edits.
  /// The other `EVIE_MODEL_*` variables are overrides for one run and must never
  /// be written into the file.
  static let selectionVariables: Set<String> = ["EVIE_CONFIG_FILE", "EVIE_MODEL_PROFILE"]

  public let fileURL: URL

  public init(fileURL: URL = EvieConfigurationLoader.defaultFileURL) {
    self.fileURL = fileURL
  }

  /// Where a migrated v1 file's original bytes are kept.
  public var legacyBackupURL: URL {
    fileURL.appendingPathExtension("v1.bak")
  }

  /// Where a damaged file's bytes are kept before a settings save replaces it.
  public var damagedBackupURL: URL {
    fileURL.appendingPathExtension("damaged.bak")
  }

  public func save(_ profiles: EvieModelProfileSet) throws {
    try profiles.validate()
    try prepareDirectory()
    try writeUserOnly(Self.encode(profiles), to: fileURL)
  }

  /// The settings pane's save of the profile in use alone.
  ///
  /// `saveProfiles` with an edit to that one profile; see it for how the file
  /// is re-read, repaired or refused.
  public func saveActiveProfile(
    reading loader: EvieConfigurationLoader,
    environment: [String: String],
    otherwise baseline: EvieModelProfileSet,
    _ edit: (inout EvieModelProfile) -> Void
  ) throws -> EvieModelProfileSet {
    try saveProfiles(reading: loader, environment: environment, otherwise: baseline) {
      profiles, activeID in
      try profiles.updateProfile(id: activeID, edit)
    }
  }

  /// The settings pane's save.
  ///
  /// It re-reads the file rather than trusting what the pane was opened with,
  /// so an edit made by hand while the window was open survives in every field
  /// the pane did not change, and writes v2. Before schema v2 this was a reload
  /// and a v1 write, which would have turned a v2 file back into v1. `edit` gets
  /// the set as the file has it — no `EVIE_MODEL_*` override in it — and the id
  /// of the profile in use (`EVIE_MODEL_PROFILE`'s, or the preferred one), the
  /// one those overrides apply to.
  ///
  /// A damaged file is repaired from `baseline` instead of refusing the save:
  /// saving from Settings is how a person fixes it. Its bytes are kept first as
  /// `config.json.damaged.bak`, since a typo in a hand-edited file can hold
  /// profiles the baseline does not have. Two cases are refused instead, with the
  /// file untouched: one written by a newer schema, whose fields this build would
  /// drop, and one that cannot be read, which therefore cannot be backed up.
  public func saveProfiles(
    reading loader: EvieConfigurationLoader,
    environment: [String: String],
    otherwise baseline: EvieModelProfileSet,
    _ edit: (inout EvieModelProfileSet, _ activeID: String) throws -> Void
  ) throws -> EvieModelProfileSet {
    let selection = environment.filter { Self.selectionVariables.contains($0.key) }
    let current: EvieLoadedConfiguration?
    do {
      current = try loader.loadProfiles(environment: selection)
    } catch EvieConfigurationLoader.LoaderError.unsupportedSchemaVersion(let version)
      where version > EvieConfigurationLoader.supportedSchemaVersion
    {
      throw SaveError.newerSchema(version)
    } catch let error as EvieConfigurationLoader.LoaderError where !error.isAboutTheFile {
      throw error
    } catch {
      try keepDamagedFile()
      current = nil
    }
    var profiles = current?.profiles ?? baseline
    let activeID =
      current?.activeProfile.id
      ?? selection["EVIE_MODEL_PROFILE"].flatMap { $0.isEmpty ? nil : $0 }
      ?? baseline.preferredProfile.id
    try edit(&profiles, activeID)
    try save(profiles)
    return profiles
  }

  /// Keeps a v1 file's original bytes as `<file>.v1.bak`, then replaces the file
  /// with its v2 migration. A backup from an earlier migration is replaced: the
  /// bytes being migrated now are the newer v1 state.
  func replaceLegacyFile(originalBytes: Data, with profiles: EvieModelProfileSet) throws {
    try profiles.validate()
    try prepareDirectory()
    try writeUserOnly(originalBytes, to: legacyBackupURL)
    try writeUserOnly(Self.encode(profiles), to: fileURL)
  }

  /// Copies the file about to be repaired to `damagedBackupURL`, user-only. A
  /// backup from an earlier repair is replaced: these bytes are the newer state.
  private func keepDamagedFile() throws {
    guard FileManager.default.fileExists(atPath: fileURL.path) else { return }
    let bytes: Data
    do {
      bytes = try Data(contentsOf: fileURL)
    } catch {
      throw SaveError.unreadableFile(path: fileURL.path)
    }
    try prepareDirectory()
    try writeUserOnly(bytes, to: damagedBackupURL)
  }

  /// The file's bytes for a set, with no validation. Internal so a test can
  /// write a file the store itself would refuse.
  static func encode(_ profiles: EvieModelProfileSet) throws -> Data {
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
    var data = try encoder.encode(
      ConfigurationDocument(
        schemaVersion: EvieConfigurationLoader.supportedSchemaVersion,
        profiles: profiles
      )
    )
    data.append(0x0A)
    return data
  }
}

extension EvieConfigurationStore {
  /// Why a settings save left the file as it was. The messages are in Portuguese
  /// because the settings pane shows them as they are.
  public enum SaveError: Error, Equatable, Sendable {
    case newerSchema(Int)
    case unreadableFile(path: String)
  }
}

extension EvieConfigurationStore.SaveError: LocalizedError {
  public var errorDescription: String? {
    switch self {
    case .newerSchema(let version):
      "O config.json foi gravado por uma versão mais nova da Evie (esquema \(version)). "
        + "Nada foi salvo, para não apagar o que essa versão guardou."
    case .unreadableFile(let path):
      "Não consegui ler \(path) para guardar uma cópia antes de consertá-lo. Nada foi salvo."
    }
  }
}

extension EvieConfigurationLoader.LoaderError {
  /// Whether the error is about the file's contents, which a settings save may
  /// repair, rather than about the environment that chose the file or profile.
  fileprivate var isAboutTheFile: Bool {
    switch self {
    case .configurationPathMustBeAbsolute, .invalidEnvironmentVariable:
      false
    case .unreadableFile, .invalidFile, .unsupportedSchemaVersion, .migrationFailed:
      true
    }
  }
}

extension EvieConfigurationStore {
  /// `{"schema_version": 2}` merged with the set's own keys, so the loader can
  /// read the header first and the set second from the same bytes.
  fileprivate struct ConfigurationDocument: Encodable {
    let schemaVersion: Int
    let profiles: EvieModelProfileSet

    enum HeaderKeys: String, CodingKey {
      case schemaVersion = "schema_version"
    }

    func encode(to encoder: any Encoder) throws {
      var header = encoder.container(keyedBy: HeaderKeys.self)
      try header.encode(schemaVersion, forKey: .schemaVersion)
      try profiles.encode(to: encoder)
    }
  }

  fileprivate func prepareDirectory() throws {
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
  }

  fileprivate func writeUserOnly(_ data: Data, to url: URL) throws {
    try data.write(to: url, options: .atomic)
    try FileManager.default.setAttributes(
      [.posixPermissions: 0o600],
      ofItemAtPath: url.path
    )
  }
}
