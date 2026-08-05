import Foundation

/// Reads and writes `preferences.json` next to the model configuration.
///
/// Preferences are user comfort settings, never credentials. A damaged or
/// future-schema file resolves to the built-in defaults instead of blocking
/// launch, because losing a shortcut must not make Evie unreachable.
public struct EviePreferencesStore: Sendable {
  public static let supportedSchemaVersion = 1

  public let fileURL: URL

  public init(fileURL: URL = EviePreferencesStore.defaultFileURL) {
    self.fileURL = fileURL
  }

  public static var defaultFileURL: URL {
    EvieConfigurationLoader.defaultFileURL
      .deletingLastPathComponent()
      .appendingPathComponent("preferences.json", isDirectory: false)
  }

  /// The preferences on disk, or the defaults when the file is absent,
  /// unreadable, damaged, or written by an unsupported future version.
  public func load() -> EviePreferences {
    loadWithDiagnostics().preferences
  }

  /// Same resolution as `load()`, plus the reason the file was ignored. The
  /// settings window uses the reason to tell the user why a value looks reset.
  public func loadWithDiagnostics() -> (preferences: EviePreferences, failure: LoadFailure?) {
    guard FileManager.default.fileExists(atPath: fileURL.path) else {
      return (EviePreferences(), nil)
    }

    let data: Data
    do {
      data = try Data(contentsOf: fileURL, options: [.mappedIfSafe])
    } catch {
      return (EviePreferences(), .unreadable)
    }

    let decoder = JSONDecoder()
    // No key strategy. `convertToSnakeCase` and `convertFromSnakeCase` are not
    // inverses around an acronym — `clonedVoiceID` is written `cloned_voice_id`
    // and read back as `clonedVoiceId` — so every type below names its keys.

    let document: PreferencesDocument
    do {
      document = try decoder.decode(PreferencesDocument.self, from: data)
    } catch {
      return (EviePreferences(), .damaged)
    }

    guard document.schemaVersion == Self.supportedSchemaVersion else {
      return (EviePreferences(), .unsupportedSchemaVersion(document.schemaVersion))
    }

    var preferences = EviePreferences(
      appearance: document.appearance ?? EvieAppearancePreferences(),
      shortcuts: document.shortcuts ?? EvieShortcutPreferences(),
      voice: document.voice ?? EvieVoicePreferences(),
      webSearchEnabled: document.webSearchEnabled ?? false
    )

    do {
      try preferences.validate()
    } catch {
      preferences = repaired(preferences)
    }
    return (preferences, nil)
  }

  public func save(_ preferences: EviePreferences) throws {
    try preferences.validate()

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

    let document = PreferencesDocument(
      schemaVersion: Self.supportedSchemaVersion,
      appearance: preferences.appearance,
      shortcuts: preferences.shortcuts,
      voice: preferences.voice,
      webSearchEnabled: preferences.webSearchEnabled
    )
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
    var data = try encoder.encode(document)
    data.append(0x0A)
    try data.write(to: fileURL, options: .atomic)
    try FileManager.default.setAttributes(
      [.posixPermissions: 0o600],
      ofItemAtPath: fileURL.path
    )
  }

  public enum LoadFailure: Equatable, Sendable {
    case unreadable
    case damaged
    case unsupportedSchemaVersion(Int)

    public var message: String {
      switch self {
      case .unreadable:
        "Não consegui ler suas preferências, então usei os padrões desta vez."
      case .damaged:
        "O arquivo de preferências estava corrompido; voltei para os padrões."
      case .unsupportedSchemaVersion(let version):
        "As preferências foram salvas por uma versão mais nova (\(version)); "
          + "usei os padrões para não perder nada."
      }
    }
  }
}

extension EviePreferencesStore {
  /// Fixes an internally inconsistent document instead of discarding it whole,
  /// so a hand edit to one field cannot silently reset unrelated settings.
  fileprivate func repaired(_ preferences: EviePreferences) -> EviePreferences {
    var repaired = preferences
    repaired.appearance.overlayWidth = repaired.appearance.resolvedOverlayWidth
    repaired.voice.setSpeechOutputEnabled(repaired.voice.speechOutputEnabled)
    if repaired.voice.wakeWordEnabled,
      repaired.voice.wakePhrase.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    {
      repaired.voice.wakePhrase = EvieVoicePreferences.defaultWakePhrase
    }
    if !repaired.shortcuts.conflicts().isEmpty {
      repaired.shortcuts.resetAll()
    }
    for action in EvieShortcutAction.allCases {
      guard let shortcut = repaired.shortcuts.shortcut(for: action) else {
        continue
      }
      if (try? shortcut.validate()) == nil {
        repaired.shortcuts.reset(action)
      }
    }
    return (try? repaired.validate()) == nil ? EviePreferences() : repaired
  }

  fileprivate struct PreferencesDocument: Codable {
    enum CodingKeys: String, CodingKey {
      case schemaVersion = "schema_version"
      case appearance
      case shortcuts
      case voice
      case webSearchEnabled = "web_search_enabled"
    }

    let schemaVersion: Int
    let appearance: EvieAppearancePreferences?
    let shortcuts: EvieShortcutPreferences?
    let voice: EvieVoicePreferences?
    let webSearchEnabled: Bool?
  }
}
