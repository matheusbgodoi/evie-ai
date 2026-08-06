import Foundation

/// A durable conversation containing only user-visible conversation history.
///
/// System and developer prompts are runtime policy and must never be persisted in
/// this value by ``EvieConversationStore``.
/// A file the person attached, kept so it can be looked at again.
///
/// What reaches the model is the text pulled out of a file — the recognised
/// characters and, for a picture, a description. That is the right thing to send
/// and the wrong thing to *keep*: a conversation that says "a imagem mostra uma
/// cordilheira" with no way to see the image is a record of an answer with the
/// question missing.
public struct EvieStoredMedia: Identifiable, Codable, Hashable, Sendable {
  public var id: UUID
  /// The name inside Evie's media folder. Never a path: a stored record must not
  /// be able to name a file outside the folder it belongs to.
  public var fileName: String
  /// What it was called when it was attached, for showing to a person.
  public var originalName: String
  public var byteCount: Int
  public var isImage: Bool
  /// Which turn it went with, so a long conversation can put each picture back
  /// beside the question it belonged to.
  public var messageID: UUID?

  public init(
    id: UUID = UUID(),
    fileName: String,
    originalName: String,
    byteCount: Int,
    isImage: Bool,
    messageID: UUID? = nil
  ) {
    self.id = id
    self.fileName = fileName
    self.originalName = originalName
    self.byteCount = byteCount
    self.isImage = isImage
    self.messageID = messageID
  }
}

public struct EvieConversation: Identifiable, Codable, Hashable, Sendable {
  public static let currentSchemaVersion = 1

  public var schemaVersion: Int
  public var id: UUID
  public var title: String
  public var createdAt: Date
  public var updatedAt: Date
  public var messages: [ChatMessage]
  /// Files attached during this conversation. They live and die with it.
  public var media: [EvieStoredMedia]

  public init(
    schemaVersion: Int = Self.currentSchemaVersion,
    id: UUID = UUID(),
    title: String,
    createdAt: Date = Date(),
    updatedAt: Date? = nil,
    messages: [ChatMessage] = [],
    media: [EvieStoredMedia] = []
  ) {
    self.schemaVersion = schemaVersion
    self.id = id
    self.title = title
    self.createdAt = createdAt
    self.updatedAt = updatedAt ?? createdAt
    self.messages = messages
    self.media = media
  }

  /// Written by hand so a conversation saved before media existed still reads.
  ///
  /// The synthesised decoder demands every stored property, so adding one would
  /// make every older file fail — which is exactly how the preferences file was
  /// once reported as corrupted when it was only older.
  public init(from decoder: any Decoder) throws {
    let container = try decoder.container(keyedBy: CodingKeys.self)
    schemaVersion = try container.decode(Int.self, forKey: .schemaVersion)
    id = try container.decode(UUID.self, forKey: .id)
    title = try container.decode(String.self, forKey: .title)
    createdAt = try container.decode(Date.self, forKey: .createdAt)
    updatedAt = try container.decode(Date.self, forKey: .updatedAt)
    messages = try container.decode([ChatMessage].self, forKey: .messages)
    media = try container.decodeIfPresent([EvieStoredMedia].self, forKey: .media) ?? []
  }

  private enum CodingKeys: String, CodingKey {
    case schemaVersion = "schema_version"
    case id
    case title
    case createdAt = "created_at"
    case updatedAt = "updated_at"
    case messages
    case media
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
