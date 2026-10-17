import Foundation
import Synchronization

/// Runs one turn on a resolved brain, and once more on the next one when the
/// first failed before saying anything.
@MainActor
public enum EvieBrainTurn {
  /// Calls `attempt` with `brain`. If it throws a `ModelClientError` that
  /// `allowsFailover` and the model had produced nothing yet, asks the
  /// resolver for the next brain, reports it through `onSwitch`, and calls
  /// `attempt` again with it — once. Anything else is rethrown as it is.
  ///
  /// `attempt` must build the whole request from the brain it is given — budget,
  /// persona, tools, pictures — because the second call is for a different
  /// profile. "Produced nothing" is watched on the client itself, so it holds
  /// for a direct stream and for every step of the agent loop alike: a step that
  /// came back with tool calls is output, and a failure after it is final.
  public static func run<Value>(
    conversation: UUID,
    on brain: ResolvedBrain,
    resolver: EvieBrainResolver,
    onSwitch: (ResolvedBrain) -> Void,
    attempt: (ResolvedBrain) async throws -> Value
  ) async throws -> Value {
    let output = OutputFlag()
    let watched = ResolvedBrain(
      profile: brain.profile,
      client: OutputWatchingClient(base: brain.client, output: output),
      rung: brain.rung,
      notice: brain.notice
    )
    do {
      return try await attempt(watched)
    } catch let error as ModelClientError where !output.isSet {
      guard let next = await resolver.failover(conversation: conversation, after: error) else {
        throw error
      }
      try Task.checkCancellation()
      onSwitch(next)
      return try await attempt(next)
    }
  }
}

extension EvieInteractionEvent {
  /// Whether this came from the model rather than from the client getting
  /// ready: text, reasoning, a tool call starting, usage or a finished message.
  var isModelOutput: Bool {
    switch self {
    case .responseTextDelta, .reasoningDelta, .artifactCreated, .usage, .completed:
      true
    case .phaseChanged(let phase):
      phase == .usingTool
    case .transcriptUpdated, .status, .failed:
      false
    }
  }
}

/// Set once, read after: whether a client has produced output.
final class OutputFlag: Sendable {
  private let state = Mutex(false)

  var isSet: Bool {
    state.withLock { $0 }
  }

  func set() {
    state.withLock { $0 = true }
  }
}

/// Passes a client's events through unchanged and notes the first one that is
/// model output.
struct OutputWatchingClient: AgentClient {
  let base: any AgentClient
  let output: OutputFlag

  var configuration: EvieConfiguration {
    base.configuration
  }

  func stream(
    messages: [ChatMessage]
  ) -> AsyncThrowingStream<EvieInteractionEvent, any Error> {
    watch(base.stream(messages: messages))
  }

  func stream(
    messages: [ChatMessage],
    tools: [EvieToolDefinition]
  ) -> AsyncThrowingStream<EvieInteractionEvent, any Error> {
    watch(base.stream(messages: messages, tools: tools))
  }

  func stream(
    messages: [ChatMessage],
    tools: [EvieToolDefinition],
    options: TurnOptions
  ) -> AsyncThrowingStream<EvieInteractionEvent, any Error> {
    watch(base.stream(messages: messages, tools: tools, options: options))
  }

  private func watch(
    _ upstream: AsyncThrowingStream<EvieInteractionEvent, any Error>
  ) -> AsyncThrowingStream<EvieInteractionEvent, any Error> {
    let output = output
    return AsyncThrowingStream { continuation in
      let relay = Task {
        do {
          for try await event in upstream {
            if event.isModelOutput {
              output.set()
            }
            continuation.yield(event)
          }
          continuation.finish()
        } catch {
          continuation.finish(throwing: error)
        }
      }
      // Ending the consumer's iteration ends the upstream one, which cancels
      // the request, as the contract of `AgentClient.stream` requires.
      continuation.onTermination = { _ in
        relay.cancel()
      }
    }
  }
}

/// A brain that could not be started: every request fails with the reason,
/// and nothing is sent anywhere.
struct UnavailableBrainClient: AgentClient {
  let configuration: EvieConfiguration
  let failure: EvieBrainUnavailable

  func stream(
    messages: [ChatMessage]
  ) -> AsyncThrowingStream<EvieInteractionEvent, any Error> {
    let failure = failure
    return AsyncThrowingStream { $0.finish(throwing: failure) }
  }
}
