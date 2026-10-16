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

  public func save(_ profiles: EvieModelProfileSet) throws {
    try profiles.validate()
    try prepareDirectory()
    try writeUserOnly(Self.encode(profiles), to: fileURL)
  }

  /// The settings pane's save.
  ///
  /// It re-reads the file rather than trusting what the pane was opened with,
  /// so an edit made by hand while the window was open survives, changes only
  /// the profile in use, and writes v2. Before schema v2 this was a reload and a
  /// v1 write, which would have turned a v2 file back into v1.
  ///
  /// A file that cannot be read is repaired from `baseline` instead of refusing
  /// the save: saving from Settings is how a person fixes it.
  public func saveActiveProfile(
    reading loader: EvieConfigurationLoader,
    environment: [String: String],
    otherwise baseline: EvieModelProfileSet,
    _ edit: (inout EvieModelProfile) -> Void
  ) throws -> EvieModelProfileSet {
    let selection = environment.filter { Self.selectionVariables.contains($0.key) }
    let current = try? loader.loadProfiles(environment: selection)
    var profiles = current?.profiles ?? baseline
    let activeID =
      current?.activeProfile.id
      ?? selection["EVIE_MODEL_PROFILE"].flatMap { $0.isEmpty ? nil : $0 }
      ?? baseline.preferredProfile.id
    try profiles.updateProfile(id: activeID, edit)
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
