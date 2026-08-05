import Foundation
import Testing

@testable import EvieCore

@Suite("Evie agent loop")
struct EvieAgentLoopTests {
  @Test("answers directly when no tool is needed")
  func answersWithoutTools() async throws {
    let client = ScriptedClient(turns: [.text("17 vezes 4 é 68.")])

    let outcome = try await EvieAgentLoop().run(
      messages: [ChatMessage(role: .user, content: "Quanto é 17 vezes 4?")],
      roots: [],
      client: client,
      emit: { _ in }
    )

    #expect(outcome.answer == "17 vezes 4 é 68.")
    #expect(outcome.toolCallCount == 0)
    #expect(!outcome.exhausted)
    #expect(await client.callCount == 1)
  }

  @Test("runs a tool, feeds the result back, and answers")
  func runsOneTool() async throws {
    let root = EvieFileRoot(id: "r1", displayName: "Downloads", path: "/tmp/x")
    let client = ScriptedClient(turns: [
      .tools([EvieToolCall(id: "call_1", name: "list_roots", argumentsJSON: "{}")]),
      .text("Você me autorizou o Downloads."),
    ])

    let outcome = try await EvieAgentLoop().run(
      messages: [ChatMessage(role: .user, content: "Quais pastas eu te autorizei?")],
      roots: [root],
      client: client,
      emit: { _ in }
    )

    #expect(outcome.answer == "Você me autorizou o Downloads.")
    #expect(outcome.toolCallCount == 1)
    #expect(await client.callCount == 2)

    // The turn that asked, the result, and the answer.
    #expect(outcome.appended.count == 3)
    #expect(outcome.appended[0].toolCalls?.first?.name == "list_roots")
    #expect(outcome.appended[1].role == .tool)
    #expect(outcome.appended[1].toolCallID == "call_1")
    #expect(outcome.appended[1].content.contains("Downloads"))
    #expect(outcome.appended[2].role == .assistant)
  }

  /// The result must be paired to the call by identifier, or the model answers
  /// about nothing.
  @Test("the result carries the identifier the model asked with")
  func pairsResultToCall() async throws {
    let client = ScriptedClient(turns: [
      .tools([EvieToolCall(id: "call_abc123", name: "list_roots", argumentsJSON: "{}")]),
      .text("Pronto."),
    ])

    let outcome = try await EvieAgentLoop().run(
      messages: [ChatMessage(role: .user, content: "oi")],
      roots: [],
      client: client,
      emit: { _ in }
    )

    let sent = await client.lastMessages
    let toolMessage = try #require(sent.first { $0.role == .tool })
    #expect(toolMessage.toolCallID == "call_abc123")
    #expect(outcome.toolCallCount == 1)
  }

  @Test("chains one tool into the next")
  func chainsTools() async throws {
    let client = ScriptedClient(turns: [
      .tools([EvieToolCall(id: "c1", name: "list_roots", argumentsJSON: "{}")]),
      .tools([
        EvieToolCall(id: "c2", name: "list_folder", argumentsJSON: #"{"root_id":"r1"}"#)
      ]),
      .text("Tem dois arquivos lá."),
    ])

    let outcome = try await EvieAgentLoop().run(
      messages: [ChatMessage(role: .user, content: "o que tem no Downloads?")],
      roots: [EvieFileRoot(id: "r1", displayName: "Downloads", path: "/tmp/nao-existe")],
      client: client,
      emit: { _ in }
    )

    #expect(outcome.toolCallCount == 2)
    #expect(outcome.answer == "Tem dois arquivos lá.")
  }

  // MARK: - The bounds

  /// A model that keeps asking must not keep the user waiting forever.
  @Test("stops at the iteration ceiling")
  func stopsAtTheCeiling() async throws {
    let client = ScriptedClient(
      turns: Array(
        repeating: .tools([
          EvieToolCall(id: "c", name: "list_roots", argumentsJSON: "{}")
        ]),
        count: 20
      )
    )

    let outcome = try await EvieAgentLoop(maximumIterations: 3).run(
      messages: [ChatMessage(role: .user, content: "oi")],
      roots: [],
      client: client,
      emit: { _ in }
    )

    #expect(outcome.exhausted)
    #expect(await client.callCount == 3)
  }

  /// The last pass withdraws the tools so the model has to produce words.
  @Test("the final request offers no tools")
  func lastIterationWithdrawsTools() async throws {
    let client = ScriptedClient(
      turns: Array(
        repeating: .tools([
          EvieToolCall(id: "c", name: "list_roots", argumentsJSON: "{}")
        ]),
        count: 20
      )
    )

    _ = try await EvieAgentLoop(maximumIterations: 2).run(
      messages: [ChatMessage(role: .user, content: "oi")],
      roots: [],
      client: client,
      emit: { _ in }
    )

    let offered = await client.toolsPerCall
    #expect(offered.count == 2)
    #expect(offered[0] == EvieFileToolbox.definitions.count)
    #expect(offered[1] == 0)
  }

  /// Every call needs an answer, honoured or not, or the next request is
  /// malformed.
  @Test("calls beyond the per-step limit are still answered")
  func answersEveryCallEvenWhenRefused() async throws {
    let manyCalls = (0..<9).map { index in
      EvieToolCall(id: "c\(index)", name: "list_roots", argumentsJSON: "{}")
    }
    let client = ScriptedClient(turns: [.tools(manyCalls), .text("Ok.")])

    _ = try await EvieAgentLoop().run(
      messages: [ChatMessage(role: .user, content: "oi")],
      roots: [],
      client: client,
      emit: { _ in }
    )

    let sent = await client.lastMessages
    let answered = Set(sent.filter { $0.role == .tool }.compactMap(\.toolCallID))
    #expect(answered == Set(manyCalls.map(\.id)))
  }

  // MARK: - What the user sees

  @Test("says what she is doing while a tool runs")
  func reportsProgress() async throws {
    let client = ScriptedClient(turns: [
      .tools([
        EvieToolCall(
          id: "c1",
          name: "search_files",
          argumentsJSON: #"{"root_id":"r1","query":"contrato"}"#
        )
      ]),
      .text("Achei."),
    ])
    let collected = Collector()

    _ = try await EvieAgentLoop().run(
      messages: [ChatMessage(role: .user, content: "cadê o contrato?")],
      roots: [EvieFileRoot(id: "r1", displayName: "Downloads", path: "/tmp/nao-existe")],
      client: client,
      emit: { event in collected.append(event) }
    )

    let statuses = collected.statuses()
    #expect(statuses.contains { $0.contains("contrato") })
  }

  /// The overlay must not be given a path or an opaque identifier to display.
  @Test("progress never mentions a path or an identifier")
  func progressStaysHuman() async throws {
    let client = ScriptedClient(turns: [
      .tools([
        EvieToolCall(
          id: "c1",
          name: "read_file",
          argumentsJSON: #"{"root_id":"a1b2c3d4","path":"projeto/notas/plano.md"}"#
        )
      ]),
      .text("Li."),
    ])
    let collected = Collector()

    _ = try await EvieAgentLoop().run(
      messages: [ChatMessage(role: .user, content: "lê o plano")],
      roots: [EvieFileRoot(id: "a1b2c3d4", displayName: "Trabalho", path: "/tmp/nao-existe")],
      client: client,
      emit: { event in collected.append(event) }
    )

    for status in collected.statuses() {
      #expect(!status.contains("a1b2c3d4"), "vazou o identificador: \(status)")
      #expect(!status.contains("projeto/notas"), "vazou o caminho: \(status)")
    }
    #expect(collected.statuses().contains { $0.contains("plano.md") })
  }

  @Test("cancelling stops the loop")
  func cancels() async throws {
    let client = ScriptedClient(
      turns: Array(
        repeating: .tools([EvieToolCall(id: "c", name: "list_roots", argumentsJSON: "{}")]),
        count: 20
      )
    )

    let task = Task {
      try await EvieAgentLoop(maximumIterations: 20).run(
        messages: [ChatMessage(role: .user, content: "oi")],
        roots: [],
        client: client,
        emit: { _ in }
      )
    }
    task.cancel()

    await #expect(throws: CancellationError.self) {
      _ = try await task.value
    }
  }
}

// MARK: - Doubles

/// A client that replays a fixed script, and records what it was offered.
private actor ScriptedClient: AgentClient {
  enum Turn {
    case text(String)
    case tools([EvieToolCall])
  }

  nonisolated let configuration = EvieConfiguration()

  private let turns: [Turn]
  private(set) var callCount = 0
  private(set) var lastMessages: [ChatMessage] = []
  private(set) var toolsPerCall: [Int] = []

  init(turns: [Turn]) {
    self.turns = turns
  }

  private func record(messages: [ChatMessage], toolCount: Int) -> Turn? {
    lastMessages = messages
    toolsPerCall.append(toolCount)
    defer { callCount += 1 }
    return callCount < turns.count ? turns[callCount] : nil
  }

  nonisolated func stream(
    messages: [ChatMessage]
  ) -> AsyncThrowingStream<EvieInteractionEvent, any Error> {
    stream(messages: messages, tools: [])
  }

  nonisolated func stream(
    messages: [ChatMessage],
    tools: [EvieToolDefinition]
  ) -> AsyncThrowingStream<EvieInteractionEvent, any Error> {
    AsyncThrowingStream { continuation in
      Task {
        guard let turn = await record(messages: messages, toolCount: tools.count) else {
          continuation.finish(throwing: TurboFieldfareClientError.emptyStream)
          return
        }
        switch turn {
        case .text(let text):
          continuation.yield(.responseTextDelta(text))
          continuation.yield(
            .completed(
              message: ChatMessage(role: .assistant, content: text),
              finishReason: "stop"
            )
          )
        case .tools(let calls):
          continuation.yield(.phaseChanged(.usingTool))
          continuation.yield(
            .completed(
              message: ChatMessage(role: .assistant, content: "", toolCalls: calls),
              finishReason: "tool_calls"
            )
          )
        }
        continuation.finish()
      }
    }
  }
}

/// Gathers emitted events from whatever context the loop runs on.
private final class Collector: @unchecked Sendable {
  private let lock = NSLock()
  private var events: [EvieInteractionEvent] = []

  func append(_ event: EvieInteractionEvent) {
    lock.lock()
    defer { lock.unlock() }
    events.append(event)
  }

  func statuses() -> [String] {
    lock.lock()
    defer { lock.unlock() }
    return events.compactMap { event in
      if case .status(let message) = event {
        return message
      }
      return nil
    }
  }
}
