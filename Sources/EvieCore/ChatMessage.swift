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
  /// Set on an assistant message that asked for tools. The calls must be sent
  /// back verbatim on the next turn: the model matches its own results by these
  /// identifiers, and a rewritten one produces an answer about nothing.
  public var toolCalls: [EvieToolCall]?
  public var createdAt: Date
  /// Pictures sent with this message, for this request only. Not in
  /// `CodingKeys`, so they are never saved, exported or logged, and a
  /// conversation file written before they existed decodes unchanged.
  public var images: [EvieImagePart]? = nil
  /// Set on what a turn with a picture adds beside it — the question that
  /// carried it, the note about it, its recognised text and description — so
  /// the request still counts as carrying the picture once the picture is a
  /// marker or was never sent (a brain that cannot see gets the text only).
  /// Text read off a screen can say anything, and `EvieTurnPlan.carriesPicture`
  /// keeps it away from tools and from auto-approval exactly as it does the
  /// picture. Not in `CodingKeys`, like `images`: it lives for the requests of
  /// one session.
  public var derivedFromPicture = false

  public init(
    id: UUID = UUID(),
    role: ChatRole,
    content: String,
    name: String? = nil,
    toolCallID: String? = nil,
    toolCalls: [EvieToolCall]? = nil,
    createdAt: Date = Date()
  ) {
    self.id = id
    self.role = role
    self.content = content
    self.name = name
    self.toolCallID = toolCallID
    self.toolCalls = toolCalls
    self.createdAt = createdAt
  }

  /// Spelled out only to leave `images` out. The raw values are the property
  /// names the synthesized keys always used, so saved files keep their shape.
  private enum CodingKeys: String, CodingKey {
    case id
    case role
    case content
    case name
    case toolCallID
    case toolCalls
    case createdAt
  }
}
