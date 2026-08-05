/// A replaceable source of backend-neutral Evie interaction events.
public protocol AgentClient: Sendable {
  var configuration: EvieConfiguration { get }

  /// Starts a streamed response for the complete conversation prefix.
  ///
  /// Cancelling the task consuming this stream must cancel the underlying
  /// request. Implementations must not execute tool calls or authorize actions.
  func stream(
    messages: [ChatMessage]
  ) -> AsyncThrowingStream<EvieInteractionEvent, any Error>

  /// The same turn, offering the model a set of functions it may ask for.
  ///
  /// Asking for a tool is all a client does. Deciding whether the call is
  /// allowed, running it, and telling the user what happened stay outside — a
  /// client that could also execute would be a client that prompt injection can
  /// reach.
  func stream(
    messages: [ChatMessage],
    tools: [EvieToolDefinition]
  ) -> AsyncThrowingStream<EvieInteractionEvent, any Error>
}

extension AgentClient {
  /// A backend with no tool support still answers; it simply never asks for one.
  public func stream(
    messages: [ChatMessage],
    tools: [EvieToolDefinition]
  ) -> AsyncThrowingStream<EvieInteractionEvent, any Error> {
    stream(messages: messages)
  }
}
