import Foundation

/// Five explicitly recorded wake samples calibrate recognition text locally.
/// This is not a voiceprint and does not identify who is speaking.
public struct EvieWakeEnrollment: Codable, Equatable, Sendable {
  public static let sampleCount = 5
  public static let canonicalPhrase = "Evie"
  public let aliases: [String]
  public let completedAt: Date

  /// Deliberately narrow: a recognizer hearing unrelated conversation during
  /// enrollment must not make arbitrary household speech a wake command.
  private static let plausibleAliases: Set<String> = [
    "evie", "evi", "ivi", "ivie", "eve", "ive", "ivy",
  ]

  public init(samples: [String], completedAt: Date = Date()) throws {
    guard samples.count == Self.sampleCount else { throw Problem.needsFiveSamples }
    let normalized = try samples.map(Self.acceptedAlias)
    aliases = Array(Set(normalized + ["evie"])).sorted()
    self.completedAt = completedAt
  }

  public static func acceptedAlias(_ transcript: String) throws -> String {
    guard transcript.count <= 40 else { throw Problem.unrelatedSample }
    let value = EvieWakePhrase.normalize(transcript)
    guard plausibleAliases.contains(value) else { throw Problem.unrelatedSample }
    return value
  }

  /// Short calibrated aliases use exact whole-utterance matching, with no
  /// fuzzy suffix matching. “eu vi”, “hoje eu vi” and “Steve” do not wake Evie.
  public func matches(_ transcript: String) -> Bool {
    guard transcript.count <= 40 else { return false }
    return aliases.contains(EvieWakePhrase.normalize(transcript))
  }

  public func validate() throws {
    guard !aliases.isEmpty, aliases.count <= Self.sampleCount + 1,
      aliases.contains("evie"), Set(aliases).count == aliases.count,
      aliases.allSatisfy(Self.plausibleAliases.contains),
      completedAt.timeIntervalSince1970.isFinite
    else { throw Problem.invalidRecord }
  }

  public enum Problem: Error, LocalizedError, Equatable {
    case needsFiveSamples
    case unrelatedSample
    case invalidRecord

    public var errorDescription: String? {
      switch self {
      case .needsFiveSamples: "Grave cinco chamadas antes de salvar a calibração."
      case .unrelatedSample:
        "Não reconheci uma chamada parecida com Evie. Tente de novo em silêncio."
      case .invalidRecord: "A calibração salva não é válida. Grave as cinco chamadas novamente."
      }
    }
  }
}

/// Stores recognized aliases only; never raw audio, embeddings or a voiceprint.
public struct EvieWakeEnrollmentStore: Sendable {
  public let fileURL: URL

  public init(fileURL: URL) { self.fileURL = fileURL }

  public func load() throws -> EvieWakeEnrollment? {
    guard FileManager.default.fileExists(atPath: fileURL.path) else { return nil }
    let bytes = try Data(contentsOf: fileURL)
    guard bytes.count <= 4_096 else { throw EvieWakeEnrollment.Problem.invalidRecord }
    let record = try JSONDecoder().decode(EvieWakeEnrollment.self, from: bytes)
    try record.validate()
    return record
  }

  public func save(_ enrollment: EvieWakeEnrollment) throws {
    try enrollment.validate()
    let directory = fileURL.deletingLastPathComponent()
    try FileManager.default.createDirectory(
      at: directory, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
    try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: directory.path)
    let bytes = try JSONEncoder().encode(enrollment)
    try bytes.write(to: fileURL, options: [.atomic])
    try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: fileURL.path)
  }

  public func remove() throws {
    if FileManager.default.fileExists(atPath: fileURL.path) {
      try FileManager.default.removeItem(at: fileURL)
    }
  }
}
