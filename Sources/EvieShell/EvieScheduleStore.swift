import EvieCore
import Foundation

/// Reads and writes `schedules.json`, beside the rest of Evie's state.
///
/// `0600` and not because a schedule is a secret in the way a password is: the
/// prompt is a sentence the user wrote, and "resume os e-mails do Dr. Silva" is
/// exactly the kind of sentence that should not be legible to every process
/// running as this user. The plist in `~/Library/LaunchAgents` is world-readable
/// and holds nothing but an identifier for the same reason.
struct EvieScheduleStore: Sendable {
  static let supportedSchemaVersion = 1

  let fileURL: URL

  init(fileURL: URL = EvieScheduleStore.defaultFileURL) {
    self.fileURL = fileURL
  }

  static var defaultFileURL: URL {
    EvieConfigurationLoader.defaultFileURL
      .deletingLastPathComponent()
      .appendingPathComponent("schedules.json", isDirectory: false)
  }

  /// Everything on disk, or nothing when the file is absent or unreadable.
  ///
  /// A schedule that no longer validates is dropped rather than repaired. There
  /// is no sensible repair for "fires at 25:00", and silently moving it to
  /// midnight would be worse than the row disappearing from a list the user can
  /// see.
  func load() -> [EvieSchedule] {
    guard let data = try? Data(contentsOf: fileURL),
      let document = try? Self.decoder.decode(Document.self, from: data),
      document.schemaVersion == Self.supportedSchemaVersion
    else {
      return []
    }
    return
      document.schedules
      .filter { (try? $0.validate()) != nil }
      .prefix(EvieSchedule.maximumSchedules)
      .map { $0 }
  }

  func save(_ schedules: [EvieSchedule]) throws {
    for schedule in schedules {
      try schedule.validate()
    }
    guard schedules.count <= EvieSchedule.maximumSchedules else {
      throw StoreFailure.tooManySchedules
    }
    // Two schedules with one identifier would share a `launchd` label, which
    // means one job doing one of the two things at whichever of the two times
    // was written last.
    guard Set(schedules.map(\.id)).count == schedules.count else {
      throw StoreFailure.duplicateIdentifier
    }

    let directory = fileURL.deletingLastPathComponent()
    try FileManager.default.createDirectory(
      at: directory,
      withIntermediateDirectories: true,
      attributes: [.posixPermissions: 0o700]
    )
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
    encoder.dateEncodingStrategy = .iso8601
    var data = try encoder.encode(
      Document(schemaVersion: Self.supportedSchemaVersion, schedules: schedules)
    )
    data.append(0x0A)
    try data.write(to: fileURL, options: .atomic)
    try FileManager.default.setAttributes(
      [.posixPermissions: 0o600],
      ofItemAtPath: fileURL.path
    )
  }

  func schedule(withID id: String) -> EvieSchedule? {
    load().first { $0.id == id }
  }

  enum StoreFailure: Error, Equatable, Sendable {
    case tooManySchedules
    case duplicateIdentifier
  }

  private struct Document: Codable {
    enum CodingKeys: String, CodingKey {
      case schemaVersion = "schema_version"
      case schedules
    }

    let schemaVersion: Int
    let schedules: [EvieSchedule]
  }
}

extension EvieScheduleStore {
  /// Reading has to use the strategy writing used. Forgetting that is not a
  /// visible failure: the decode throws, `load` returns nothing, and every
  /// schedule the user made appears to have vanished.
  fileprivate static var decoder: JSONDecoder {
    let decoder = JSONDecoder()
    decoder.dateDecodingStrategy = .iso8601
    return decoder
  }
}
