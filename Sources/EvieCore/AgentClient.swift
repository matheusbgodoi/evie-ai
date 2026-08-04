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
}
