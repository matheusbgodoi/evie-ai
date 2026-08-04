import Foundation

/// A result that can be rendered as a transient card by the native shell.
public struct EvieArtifact: Identifiable, Codable, Hashable, Sendable {
  public enum Kind: String, Codable, CaseIterable, Hashable, Sendable {
    case text
    case markdown
    case link
    case file
    case image
    case email
    case calendarEvent
    case workflow
    case approval
    case diagnostic
    case custom
  }

  public var id: UUID
  public var kind: Kind
  public var title: String
  public var content: String
  public var sourceURL: URL?
  public var metadata: [String: String]
  public var createdAt: Date

  public init(
    id: UUID = UUID(),
    kind: Kind,
    title: String,
    content: String,
    sourceURL: URL? = nil,
    metadata: [String: String] = [:],
    createdAt: Date = Date()
  ) {
    self.id = id
    self.kind = kind
    self.title = title
    self.content = content
    self.sourceURL = sourceURL
    self.metadata = metadata
    self.createdAt = createdAt
  }
}
