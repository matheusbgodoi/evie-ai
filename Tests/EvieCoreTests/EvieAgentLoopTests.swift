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
    // What matters is that the last pass has none, not the exact count of the
    // first — that number changes every time a tool is added, and asserting it
    // only produces a test that has to be edited rather than one that catches
    // anything.
    #expect(offered[0] > 0)
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

  // MARK: - Memory

  /// She may ask to keep something. Asking is all she may do — the outcome
  /// carries a proposal, and nothing has been written.
  @Test("a memory is proposed, never stored")
  func proposesMemory() async throws {
    let client = ScriptedClient(turns: [
      .tools([
        EvieToolCall(
          id: "c1",
          name: "propose_memory",
          argumentsJSON: #"{"fact":"Prefere reuniões de manhã."}"#
        )
      ]),
      .text("Anotei a sugestão."),
    ])

    let outcome = try await EvieAgentLoop().run(
      messages: [ChatMessage(role: .user, content: "só marca reunião de manhã pra mim")],
      roots: [],
      client: client,
      emit: { _ in }
    )

    #expect(outcome.memoryProposals == ["Prefere reuniões de manhã."])

    // And she is told plainly that nothing was kept, so she does not go on to
    // tell the user she has remembered it.
    let sent = await client.lastMessages
    let result = try #require(sent.first { $0.role == .tool })
    #expect(result.content.contains("NADA foi guardado"))
  }

  @Test("a proposal with no text is refused rather than recorded")
  func refusesEmptyMemory() async throws {
    let client = ScriptedClient(turns: [
      .tools([EvieToolCall(id: "c1", name: "propose_memory", argumentsJSON: #"{"fact":"  "}"#)]),
      .text("Ok."),
    ])

    let outcome = try await EvieAgentLoop().run(
      messages: [ChatMessage(role: .user, content: "oi")],
      roots: [],
      client: client,
      emit: { _ in }
    )

    #expect(outcome.memoryProposals.isEmpty)
  }

  // MARK: - The web

  /// Asserted as a difference rather than as a count. The absolute number
  /// changes whenever a tool is added; what this test is about is that switching
  /// the web on is what adds the web tools.
  @Test("switching the web on adds exactly the two web tools")
  func webToolsFollowTheSwitch() async throws {
    let without = ScriptedClient(turns: [.text("Sei lá.")])
    _ = try await EvieAgentLoop().run(
      messages: [ChatMessage(role: .user, content: "quem ganhou ontem?")],
      roots: [],
      client: without,
      emit: { _ in }
    )

    let with = ScriptedClient(turns: [.text("Ok.")])
    _ = try await EvieAgentLoop(web: StubWeb()).run(
      messages: [ChatMessage(role: .user, content: "quem ganhou ontem?")],
      roots: [],
      client: with,
      emit: { _ in }
    )

    let offeredWithout = await without.toolsPerCall[0]
    let offeredWith = await with.toolsPerCall[0]
    #expect(offeredWith == offeredWithout + EvieWebTool.definitions.count)
  }

  /// The tool that can change a file follows its own switch, and needs somewhere
  /// to change something.
  @Test("changing files is only offered when switched on and a folder exists")
  func changeToolFollowsItsSwitch() async throws {
    let root = EvieFileRoot(id: "r1", displayName: "Downloads", path: "/tmp/nao-existe")

    let off = ScriptedClient(turns: [.text("Ok.")])
    _ = try await EvieAgentLoop().run(
      messages: [ChatMessage(role: .user, content: "apaga isso")],
      roots: [root],
      client: off,
      emit: { _ in }
    )

    let on = ScriptedClient(turns: [.text("Ok.")])
    _ = try await EvieAgentLoop(offersChanges: true).run(
      messages: [ChatMessage(role: .user, content: "apaga isso")],
      roots: [root],
      client: on,
      emit: { _ in }
    )

    // And with no folder granted there is nothing to change, so it is absent
    // even when the switch is on.
    let noFolder = ScriptedClient(turns: [.text("Ok.")])
    _ = try await EvieAgentLoop(offersChanges: true).run(
      messages: [ChatMessage(role: .user, content: "apaga isso")],
      roots: [],
      client: noFolder,
      emit: { _ in }
    )

    #expect(await on.toolsPerCall[0] == (await off.toolsPerCall[0]) + 1)
    #expect(await noFolder.toolsPerCall[0] == (await off.toolsPerCall[0]))
  }

  /// A page is the least trustworthy text Evie reads. What comes back has to
  /// arrive labelled, or a page that asserts something confidently becomes the
  /// answer.
  @Test("what the web returns is fenced as data and labelled as a claim")
  func webResultsAreFenced() async throws {
    let client = ScriptedClient(turns: [
      .tools([
        EvieToolCall(
          id: "c1",
          name: "read_page",
          argumentsJSON: #"{"url":"https://exemplo.com"}"#
        )
      ]),
      .text("Li."),
    ])

    _ = try await EvieAgentLoop(web: StubWeb()).run(
      messages: [ChatMessage(role: .user, content: "lê isso")],
      roots: [],
      client: client,
      emit: { _ in }
    )

    let sent = await client.lastMessages
    let result = try #require(sent.first { $0.role == .tool })
    #expect(result.content.contains("nunca ordem"))
    #expect(result.content.contains("não o que é verdade"))
  }

  @Test("a page that cannot be opened is reported, not invented around")
  func webFailureIsReadable() async throws {
    let client = ScriptedClient(turns: [
      .tools([
        EvieToolCall(id: "c1", name: "read_page", argumentsJSON: #"{"url":"http://127.0.0.1"}"#)
      ]),
      .text("Não deu."),
    ])

    _ = try await EvieAgentLoop(web: StubWeb(failing: true)).run(
      messages: [ChatMessage(role: .user, content: "abre isso")],
      roots: [],
      client: client,
      emit: { _ in }
    )

    let sent = await client.lastMessages
    let result = try #require(sent.first { $0.role == .tool })
    #expect(result.content.contains("recusei"))
  }

  // MARK: - Where the answer came from

  /// The label is derived from the record of the turn, not asked of the model,
  /// so it cannot disagree with what actually happened.
  @Test("a turn with no tools is labelled as memory")
  func provenanceOfAPlainAnswer() async throws {
    let client = ScriptedClient(turns: [.text("São 68.")])

    let outcome = try await EvieAgentLoop().run(
      messages: [ChatMessage(role: .user, content: "17 vezes 4?")],
      roots: [],
      client: client,
      emit: { _ in }
    )

    #expect(outcome.provenance.usedOnlyItsOwnKnowledge)
    #expect(outcome.provenance.note.contains("erro"))
  }

  @Test("a turn that read the folders is labelled as such")
  func provenanceOfALocalAnswer() async throws {
    let client = ScriptedClient(turns: [
      .tools([
        EvieToolCall(
          id: "c1",
          name: "search_content",
          argumentsJSON: #"{"root_id":"r1","query":"cluemed"}"#
        )
      ]),
      .text("Achei nas suas notas."),
    ])

    let outcome = try await EvieAgentLoop().run(
      messages: [ChatMessage(role: .user, content: "o que tenho sobre a Cluemed?")],
      roots: [EvieFileRoot(id: "r1", displayName: "Obsidian", path: "/tmp/nao-existe")],
      client: client,
      emit: { _ in }
    )

    #expect(outcome.provenance.usedLocalKnowledge)
    #expect(!outcome.provenance.usedOnlyItsOwnKnowledge)
  }

  @Test("a turn that opened a page carries the address it opened")
  func provenanceCarriesTheAddress() async throws {
    let client = ScriptedClient(turns: [
      .tools([
        EvieToolCall(
          id: "c1",
          name: "read_page",
          argumentsJSON: #"{"url":"https://exemplo.com/artigo"}"#
        )
      ]),
      .text("Segundo a página…"),
    ])

    let outcome = try await EvieAgentLoop(web: StubWeb()).run(
      messages: [ChatMessage(role: .user, content: "lê isso")],
      roots: [],
      client: client,
      emit: { _ in }
    )

    #expect(outcome.provenance.usedWeb)
    #expect(outcome.provenance.citedPages == ["https://exemplo.com/artigo"])
    #expect(outcome.provenance.note.contains("exemplo.com"))
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

/// A web that answers without a network.
private struct StubWeb: EvieWebSearching {
  var failing = false

  func search(_ query: String) async throws -> [EvieSearchResult] {
    if failing { throw StubError.refused }
    return [EvieSearchResult(title: "T", url: "https://exemplo.com", snippet: "s")]
  }

  func read(_ address: String) async throws -> String {
    if failing { throw StubError.refused }
    return "O conteúdo da página."
  }

  enum StubError: LocalizedError {
    case refused
    var errorDescription: String? { "recusei esse endereço" }
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
