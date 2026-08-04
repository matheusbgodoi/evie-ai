import Foundation

/// A backend-neutral role for a conversational message.
public enum ChatRole: String, Codable, CaseIterable, Hashable, Sendable {
  case system
  case developer
  case user
  case assistant
  case tool
}

/// A conversational message shared by the native shell and agent adapters.
///
/// Runtime-only fields such as an OpenAI response identifier deliberately do not
/// live here. An adapter maps this stable representation to its wire protocol.
public struct ChatMessage: Identifiable, Codable, Hashable, Sendable {
  public var id: UUID
  public var role: ChatRole
  public var content: String
  public var name: String?
  public var toolCallID: String?
  public var createdAt: Date

  public init(
    id: UUID = UUID(),
    role: ChatRole,
    content: String,
    name: String? = nil,
    toolCallID: String? = nil,
    createdAt: Date = Date()
  ) {
    self.id = id
    self.role = role
    self.content = content
    self.name = name
    self.toolCallID = toolCallID
    self.createdAt = createdAt
  }
}
