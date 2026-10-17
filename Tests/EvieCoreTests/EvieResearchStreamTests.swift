import Foundation
import Testing

@testable import EvieCore

@Suite("Research stream failures")
struct EvieResearchStreamTests {
  @Test("cancelling while the model is running discards a late complete answer")
  func cancelInFlight() async throws {
    let client = ResearchPendingClient()
    let task = Task {
      try await EvieResearchAnswer.read(
        image: image, goal: "Resolva", client: client, readiness: .ready)
    }
    await client.waitUntilStarted()
    task.cancel()
    await client.complete(ChatMessage(role: .assistant, content: "68"))
    await #expect(throws: CancellationError.self) { try await task.value }
  }

  @Test("a transport error after response text cannot become a clipboard answer")
  func transportFailure() async throws {
    let client = ResearchPendingClient()
    let task = Task {
      try await EvieResearchAnswer.read(
        image: image, goal: "Resolva", client: client, readiness: .ready)
    }
    await client.waitUntilStarted()
    await client.fail()
    await #expect(throws: URLError.self) { try await task.value }
  }

  @Test("a model message with the wrong role is never delivered")
  func wrongRole() async throws {
    let client = ResearchPendingClient()
    let task = Task {
      try await EvieResearchAnswer.read(
        image: image, goal: "Resolva", client: client, readiness: .ready)
    }
    await client.waitUntilStarted()
    await client.complete(ChatMessage(role: .user, content: "68"))
    await #expect(throws: EvieResearchError.invalidAnswer) { try await task.value }
  }

  private var image: EvieImagePart {
    EvieImagePart(
      mimeType: "image/png", data: Data([1]), pixelSize: CGSize(width: 1, height: 1),
      origin: .screenshot)
  }
}

private actor ResearchPendingClient: AgentClient {
  nonisolated let configuration = EvieConfiguration.builtIn
  private var continuation: AsyncThrowingStream<EvieInteractionEvent, any Error>.Continuation?
  private var waiter: CheckedContinuation<Void, Never>?

  nonisolated func stream(messages: [ChatMessage]) -> AsyncThrowingStream<
    EvieInteractionEvent, any Error
  > {
    stream(messages: messages, tools: [], options: TurnOptions())
  }

  nonisolated func stream(
    messages: [ChatMessage], tools: [EvieToolDefinition], options: TurnOptions
  ) -> AsyncThrowingStream<EvieInteractionEvent, any Error> {
    AsyncThrowingStream { continuation in
      Task { await register(continuation) }
    }
  }

  private func register(
    _ continuation: AsyncThrowingStream<EvieInteractionEvent, any Error>.Continuation
  ) {
    self.continuation = continuation
    waiter?.resume()
    waiter = nil
  }

  func waitUntilStarted() async {
    if continuation != nil { return }
    await withCheckedContinuation { waiter = $0 }
  }

  func complete(_ message: ChatMessage) {
    continuation?.yield(.completed(message: message, finishReason: "stop"))
    continuation?.finish()
    continuation = nil
  }

  func fail() {
    continuation?.yield(.responseTextDelta("resposta parcial"))
    continuation?.finish(throwing: URLError(.networkConnectionLost))
    continuation = nil
  }
}
