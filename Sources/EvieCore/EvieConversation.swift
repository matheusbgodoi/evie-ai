import Foundation

/// A durable conversation containing only user-visible conversation history.
///
/// System and developer prompts are runtime policy and must never be persisted in
/// this value by ``EvieConversationStore``.
public struct EvieConversation: Identifiable, Codable, Hashable, Sendable {
  public static let currentSchemaVersion = 1

  public var schemaVersion: Int
  public var id: UUID
  public var title: String
  public var createdAt: Date
  public var updatedAt: Date
  public var messages: [ChatMessage]

  public init(
    schemaVersion: Int = Self.currentSchemaVersion,
    id: UUID = UUID(),
    title: String,
    createdAt: Date = Date(),
    updatedAt: Date? = nil,
    messages: [ChatMessage] = []
  ) {
    self.schemaVersion = schemaVersion
    self.id = id
    self.title = title
    self.createdAt = createdAt
    self.updatedAt = updatedAt ?? createdAt
    self.messages = messages
  }

  private enum CodingKeys: String, CodingKey {
    case schemaVersion = "schema_version"
    case id
    case title
    case createdAt = "created_at"
    case updatedAt = "updated_at"
    case messages
  }
}

/// Lightweight metadata for conversation pickers and history lists.
public struct EvieConversationSummary: Identifiable, Codable, Hashable, Sendable {
  public var id: UUID
  public var title: String
  public var createdAt: Date
  public var updatedAt: Date
  public var messageCount: Int

  public init(
    id: UUID,
    title: String,
    createdAt: Date,
    updatedAt: Date,
    messageCount: Int
  ) {
    self.id = id
    self.title = title
    self.createdAt = createdAt
    self.updatedAt = updatedAt
    self.messageCount = messageCount
  }

  public init(conversation: EvieConversation) {
    self.init(
      id: conversation.id,
      title: conversation.title,
      createdAt: conversation.createdAt,
      updatedAt: conversation.updatedAt,
      messageCount: conversation.messages.count
    )
  }
}

/// A privacy-preserving inventory of readable conversation records.
///
/// Unavailable records are reported only as a count. Their identifiers, paths,
/// metadata, and contents never enter history-list presentation state.
public struct EvieConversationScan: Equatable, Sendable {
  public var conversations: [EvieConversationSummary]
  public var unavailableRecordCount: Int

  public init(
    conversations: [EvieConversationSummary],
    unavailableRecordCount: Int
  ) {
    self.conversations = conversations
    self.unavailableRecordCount = unavailableRecordCount
  }
}
