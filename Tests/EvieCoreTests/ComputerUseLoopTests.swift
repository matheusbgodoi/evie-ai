import CoreGraphics
import Foundation
import Testing

@testable import EvieCore

@Suite("Computer use loop")
@MainActor
struct ComputerUseLoopTests {
  typealias Fixture = ComputerUseFixture

  /// One session's parts: a broker on a hand-moved clock, an active grant,
  /// and the stub computer.
  @MainActor
  struct Rig {
    let clock: TestClock
    let broker: EvieAgentModeBroker
    let grant: EvieAgentModeGrant
    let computer: StubComputer

    init(goal: String = "Salva esse rascunho no Mail") {
      let clock = TestClock()
      self.clock = clock
      broker = EvieAgentModeBroker(policy: Fixture.policy, now: { clock.now })
      grant = broker.begin(goal: goal, gesture: .button)!
      computer = StubComputer(broker: broker)
      // Each action takes a second, so the broker's 250 ms gap is never hit.
      computer.onPerform = { _ in clock.advance(1) }
    }

    func session(
      acting: Bool = true,
      confirm: ((ComputerConfirmation) async -> Bool)? = nil
    ) -> ComputerUseSession {
      let clock = self.clock
      return ComputerUseSession(
        broker: broker,
        grant: grant,
        observer: computer,
        executor: acting ? computer : nil,
        convention: .normalized1000,
        imageLongEdge: 1_024,
        confirm: confirm,
        now: { clock.now },
        sleep: { _ in }
      )
    }
  }

  static let goal = [ChatMessage(role: .user, content: "Salva esse rascunho no Mail")]

  static func call(_ name: String, _ arguments: String, id: String = "c1") -> EvieToolCall {
    EvieToolCall(id: id, name: name, argumentsJSON: arguments)
  }

  static let finish = call(
    "finish", #"{"status":"success","summary":"Rascunho salvo."}"#, id: "c-end")

  @Test("the first observation, with its picture, comes before the model is asked")
  func observesFirst() async throws {
    let rig = Rig()
    let client = ComputerScriptedClient(turns: [.tools([Self.finish])], thinking: .templateKwargs)

    let outcome = try await EvieAgentLoop().runComputerUse(
      messages: Self.goal, client: client, session: rig.session(), emit: { _ in })

    #expect(outcome.ending == .finished(.success))
    #expect(outcome.summary == "Rascunho salvo.")
    #expect(rig.computer.requests.map(\.withImage) == [true])
    #expect(rig.computer.requests.first?.maxLongEdge == 1_024)
    let sent = try #require(await client.sent.first)
    let observation = try #require(sent.first { $0.content.contains("Observação inicial") })
    #expect(observation.role == .user)
    #expect(observation.content.contains("<conteudo_da_tela nao_confiavel id="))
    #expect(observation.content.contains(#"[0] AXButton "Enviar" box="#))
    let last = try #require(sent.last)
    #expect(last.role == .user)
    #expect(last.images?.count == 1)
    #expect(last.content.hasPrefix("[observação obs-1]"))
  }

  @Test("each step declares the computer-use tools and thinks low on a server that can")
  func stepOptions() async throws {
    let rig = Rig()
    let client = ComputerScriptedClient(turns: [.tools([Self.finish])], thinking: .templateKwargs)

    _ = try await EvieAgentLoop().runComputerUse(
      messages: Self.goal, client: client, session: rig.session(), emit: { _ in })

    let tools = try #require(await client.tools.first)
    #expect(Set(tools) == Set(ComputerToolName.allCases.map(\.rawValue)))
    let options = try #require(await client.options.first)
    #expect(options.reasoning == .low)
    #expect(options.maxTokens == 1_024)
  }

  @Test("the rules go as a late system message, after the person's request")
  func rulesAfterTheRequest() async throws {
    let rig = Rig()
    let client = ComputerScriptedClient(turns: [.tools([Self.finish])])

    _ = try await EvieAgentLoop().runComputerUse(
      messages: Self.goal, client: client, session: rig.session(), emit: { _ in })

    let sent = try #require(await client.sent.first)
    #expect(sent[0].content == Self.goal[0].content)
    #expect(sent[1].role == .system)
    #expect(sent[1].content.contains("Sessão de controle do Mac"))
  }

  @Test("look_screen observes again with a picture, and only the newest picture is sent")
  func onlyTheNewestPicture() async throws {
    let rig = Rig()
    let client = ComputerScriptedClient(turns: [
      .tools([Self.call("look_screen", "{}")]),
      .tools([Self.finish]),
    ])

    _ = try await EvieAgentLoop().runComputerUse(
      messages: Self.goal, client: client, session: rig.session(), emit: { _ in })

    #expect(rig.computer.requests.map(\.withImage) == [true, true])
    let second = try #require(await client.sent.last)
    let pictures = second.filter { !($0.images ?? []).isEmpty }
    #expect(pictures.count == 1)
    #expect(pictures.first?.content.hasPrefix("[observação obs-2]") == true)
    #expect(second.last?.images?.count == 1)
    // The older observation is a log line, its picture a marker.
    #expect(second.contains { $0.content.contains("[observação obs-1: captura de tela omitida") })
    let first = try #require(second.first { $0.content.contains("Observação inicial") })
    #expect(first.content.contains("já substituída"))
    #expect(!first.content.contains("AXButton"))
    // A tool message never carries the picture.
    #expect(second.filter { $0.role == .tool }.allSatisfy { ($0.images ?? []).isEmpty })
  }

  @Test("after an action that changed little, the list alone is read again, with the diff")
  func listOnlyAfterSmallChange() async throws {
    let rig = Rig()
    rig.computer.screens = [
      Fixture.observation(),
      Fixture.observation(focused: 3),
    ]
    let client = ComputerScriptedClient(turns: [
      .tools([Self.call("computer", #"{"action":"left_click","element":3,"observation_id":"obs-1"}"#)]),
      .tools([Self.finish]),
    ])

    let outcome = try await EvieAgentLoop().runComputerUse(
      messages: Self.goal, client: client, session: rig.session(), emit: { _ in })

    #expect(rig.computer.performed.count == 1)
    #expect(rig.computer.requests.map(\.withImage) == [true, false])
    #expect(outcome.actions == 1)
    #expect(outcome.observations == 2)
    let sent = await client.sent
    let after = try #require(sent.last)
    let result = try #require(after.last { $0.role == .tool })
    #expect(result.content.contains("Feito."))
    #expect(result.content.contains("mudanças desde obs-1"))
    #expect(result.content.contains("foco agora em [3]"))
    #expect(result.content.contains("observation_id=obs-2"))
    #expect(result.content.contains("Sem imagem nova"))
    // Still the first picture, and the earlier request is a prefix of this one.
    #expect(after.filter { !($0.images ?? []).isEmpty }.count == 1)
    let before = sent[0]
    #expect(Array(after.prefix(before.count)).map(Wire.init) == before.map(Wire.init))
  }

  @Test("an action that changed the screen meaningfully brings a new picture")
  func pictureAfterMeaningfulChange() async throws {
    let rig = Rig()
    rig.computer.screens = [
      Fixture.observation(),
      Fixture.observation(windowTitle: "Rascunhos"),
      Fixture.observation(windowTitle: "Rascunhos"),
    ]
    let client = ComputerScriptedClient(turns: [
      .tools([Self.call("computer", #"{"action":"left_click","element":3,"observation_id":"obs-1"}"#)]),
      .tools([Self.finish]),
    ])

    _ = try await EvieAgentLoop().runComputerUse(
      messages: Self.goal, client: client, session: rig.session(), emit: { _ in })

    #expect(rig.computer.requests.map(\.withImage) == [true, false, true])
    let after = try #require(await client.sent.last)
    let result = try #require(after.last { $0.role == .tool })
    #expect(result.content.contains("observation_id=obs-3"))
    #expect(result.content.contains("outra janela"))
    #expect(after.last?.content.hasPrefix("[observação obs-3]") == true)
    #expect(after.filter { !($0.images ?? []).isEmpty }.count == 1)
  }

  @Test("without an executor an action is answered, never carried out")
  func observeOnly() async throws {
    let rig = Rig()
    let client = ComputerScriptedClient(turns: [
      .tools([Self.call("computer", #"{"action":"left_click","element":3,"observation_id":"obs-1"}"#)]),
      .tools([Self.finish]),
    ])

    _ = try await EvieAgentLoop().runComputerUse(
      messages: Self.goal, client: client, session: rig.session(acting: false), emit: { _ in })

    #expect(rig.computer.performed.isEmpty)
    let after = try #require(await client.sent.last)
    let result = try #require(after.last { $0.role == .tool })
    #expect(result.content.contains("só olha a tela"))
    #expect(rig.computer.requests.count == 1)
  }

  @Test("a refused action goes back to the model as the reason")
  func refusalIsTheResult() async throws {
    let rig = Rig()
    rig.computer.screens = [Fixture.observation(focused: 2)]
    let client = ComputerScriptedClient(turns: [
      .tools([Self.call("computer", #"{"action":"type","text":"segredo","observation_id":"obs-1"}"#)]),
      .tools([Self.finish]),
    ])

    _ = try await EvieAgentLoop().runComputerUse(
      messages: Self.goal, client: client, session: rig.session(), emit: { _ in })

    #expect(rig.computer.performed.isEmpty)
    let result = try #require(await client.sent.last?.last { $0.role == .tool })
    #expect(result.content.contains(ComputerActionPolicy.passwordFieldRefusal))
  }

  @Test("a stale observation id is refused before the policy sees it")
  func staleObservation() async throws {
    let rig = Rig()
    let client = ComputerScriptedClient(turns: [
      .tools([Self.call("computer", #"{"action":"left_click","element":3,"observation_id":"obs-9"}"#)]),
      .tools([Self.finish]),
    ])

    _ = try await EvieAgentLoop().runComputerUse(
      messages: Self.goal, client: client, session: rig.session(), emit: { _ in })

    #expect(rig.computer.performed.isEmpty)
    let result = try #require(await client.sent.last?.last { $0.role == .tool })
    #expect(result.content.contains(ComputerToolParseError.staleObservation.localizedDescription))
  }

  @Test("a declined confirmation tells the model the person refused, and nothing is done")
  func declinedConfirmation() async throws {
    let rig = Rig()
    var asked: [String] = []
    let client = ComputerScriptedClient(turns: [
      .tools([Self.call("computer", #"{"action":"left_click","element":0,"observation_id":"obs-1"}"#)]),
      .tools([Self.finish]),
    ])

    _ = try await EvieAgentLoop().runComputerUse(
      messages: Self.goal, client: client,
      session: rig.session(confirm: { question in
        asked.append(question.text)
        return false
      }),
      emit: { _ in })

    #expect(asked.count == 1)
    #expect(asked.first?.contains("Enviar") == true)
    #expect(rig.computer.performed.isEmpty)
    let result = try #require(await client.sent.last?.last { $0.role == .tool })
    #expect(result.content.contains("usuário recusou"))
  }

  @Test("an approved confirmation is carried out")
  func approvedConfirmation() async throws {
    let rig = Rig()
    let client = ComputerScriptedClient(turns: [
      .tools([Self.call("computer", #"{"action":"left_click","element":0,"observation_id":"obs-1"}"#)]),
      .tools([Self.finish]),
    ])

    _ = try await EvieAgentLoop().runComputerUse(
      messages: Self.goal, client: client, session: rig.session(confirm: { _ in true }),
      emit: { _ in })

    #expect(
      rig.computer.performed == [
        .click(.element(observationID: "obs-1", index: 0), button: .left, count: 1)
      ])
  }

  @Test("without a confirmation card, what needs asking is not done")
  func noCardNoAction() async throws {
    let rig = Rig()
    let client = ComputerScriptedClient(turns: [
      .tools([Self.call("computer", #"{"action":"left_click","element":0,"observation_id":"obs-1"}"#)]),
      .tools([Self.finish]),
    ])

    _ = try await EvieAgentLoop().runComputerUse(
      messages: Self.goal, client: client, session: rig.session(), emit: { _ in })

    #expect(rig.computer.performed.isEmpty)
  }

  @Test("a revoked session ends the loop before the next request")
  func revokeEnds() async throws {
    let rig = Rig()
    let broker = rig.broker
    rig.computer.onPerform = { _ in broker.revoke() }
    let client = ComputerScriptedClient(turns: [
      .tools([Self.call("computer", #"{"action":"left_click","element":3,"observation_id":"obs-1"}"#)]),
      .tools([Self.finish]),
    ])

    let outcome = try await EvieAgentLoop().runComputerUse(
      messages: Self.goal, client: client, session: rig.session(), emit: { _ in })

    #expect(outcome.ending == .sessionEnded)
    #expect(await client.sent.count == 1)
    #expect(rig.computer.endedSucceeded == false)
  }

  @Test("three actions in a row that changed nothing end the session for the person")
  func setbacksNeedTheUser() async throws {
    let rig = Rig()
    rig.computer.result = ActionResult(outcome: .noChange, detail: "Nada mudou.")
    let click: (Int) -> ComputerScriptedClient.Turn = { n in
      .tools([Self.call("computer", #"{"action":"left_click","element":3,"observation_id":"obs-\#(n)"}"#, id: "c\(n)")])
    }
    let client = ComputerScriptedClient(turns: [click(1), click(2), click(3), .tools([Self.finish])])

    let outcome = try await EvieAgentLoop().runComputerUse(
      messages: Self.goal, client: client, session: rig.session(), emit: { _ in })

    #expect(outcome.ending == .needsUser)
    #expect(outcome.summary == ComputerUseBudget.Exhaustion.setbacks.message)
    #expect(rig.computer.performed.count == 3)
    #expect(await client.sent.count == 3)
  }

  @Test("only the first call of a step is carried out; the rest are answered")
  func oneCallPerStep() async throws {
    let rig = Rig()
    let client = ComputerScriptedClient(turns: [
      .tools([
        Self.call("look_screen", "{}", id: "a"),
        Self.call("computer", #"{"action":"left_click","element":3,"observation_id":"obs-1"}"#, id: "b"),
      ]),
      .tools([Self.finish]),
    ])

    _ = try await EvieAgentLoop().runComputerUse(
      messages: Self.goal, client: client, session: rig.session(), emit: { _ in })

    #expect(rig.computer.performed.isEmpty)
    let sent = try #require(await client.sent.last)
    let extra = try #require(sent.first { $0.toolCallID == "b" })
    #expect(extra.content.contains("Uma ação por vez"))
  }

  @Test("an answer in words ends the session as answered")
  func answered() async throws {
    let rig = Rig()
    let client = ComputerScriptedClient(turns: [.text("Não sei fazer isso.")])

    let outcome = try await EvieAgentLoop().runComputerUse(
      messages: Self.goal, client: client, session: rig.session(), emit: { _ in })

    #expect(outcome.ending == .answered)
    #expect(outcome.summary == "Não sei fazer isso.")
  }

  @Test("a request for the window observes the front window")
  func windowTarget() async throws {
    let rig = Rig(goal: "Fecha as abas nessa janela")
    let client = ComputerScriptedClient(turns: [.tools([Self.finish])])

    _ = try await EvieAgentLoop().runComputerUse(
      messages: Self.goal, client: client, session: rig.session(), emit: { _ in })

    #expect(rig.computer.requests.first?.target == .frontWindow)
  }

  @Test("finish with success takes the glow down as a success")
  func glowComesDown() async throws {
    let rig = Rig()
    let client = ComputerScriptedClient(turns: [.tools([Self.finish])])

    _ = try await EvieAgentLoop().runComputerUse(
      messages: Self.goal, client: client, session: rig.session(), emit: { _ in })

    #expect(rig.computer.endedSucceeded == true)
  }
}

/// A message as it goes on the wire, for comparing requests byte for byte.
struct Wire: Equatable {
  let role: ChatRole
  let content: String
  let toolCallID: String?
  let calls: [String]
  let pictures: [UUID]

  init(_ message: ChatMessage) {
    role = message.role
    content = message.content
    toolCallID = message.toolCallID
    calls = (message.toolCalls ?? []).map { "\($0.id) \($0.name) \($0.argumentsJSON)" }
    pictures = (message.images ?? []).map(\.id)
  }
}

/// A client that replays a script of replies and records each request.
actor ComputerScriptedClient: AgentClient {
  enum Turn {
    case text(String)
    case tools([EvieToolCall])
  }

  nonisolated let configuration: EvieConfiguration
  private let turns: [Turn]
  private(set) var sent: [[ChatMessage]] = []
  private(set) var tools: [[String]] = []
  private(set) var options: [TurnOptions] = []

  init(turns: [Turn], thinking: ThinkingParameterStyle = .none) {
    var configuration = EvieConfiguration()
    configuration.thinkingStyle = thinking
    self.configuration = configuration
    self.turns = turns
  }

  private func record(_ messages: [ChatMessage], _ tools: [EvieToolDefinition], _ options: TurnOptions)
    -> Turn?
  {
    sent.append(messages)
    self.tools.append(tools.map(\.name))
    self.options.append(options)
    return sent.count <= turns.count ? turns[sent.count - 1] : nil
  }

  nonisolated func stream(messages: [ChatMessage]) -> AsyncThrowingStream<EvieInteractionEvent, any Error> {
    stream(messages: messages, tools: [], options: TurnOptions())
  }

  nonisolated func stream(
    messages: [ChatMessage],
    tools: [EvieToolDefinition]
  ) -> AsyncThrowingStream<EvieInteractionEvent, any Error> {
    stream(messages: messages, tools: tools, options: TurnOptions())
  }

  nonisolated func stream(
    messages: [ChatMessage],
    tools: [EvieToolDefinition],
    options: TurnOptions
  ) -> AsyncThrowingStream<EvieInteractionEvent, any Error> {
    AsyncThrowingStream { continuation in
      Task {
        guard let turn = await record(messages, tools, options) else {
          continuation.finish(throwing: ModelClientError.emptyStream)
          return
        }
        let message =
          switch turn {
          case .text(let text): ChatMessage(role: .assistant, content: text)
          case .tools(let calls): ChatMessage(role: .assistant, content: "", toolCalls: calls)
          }
        continuation.yield(.completed(message: message, finishReason: "stop"))
        continuation.finish()
      }
    }
  }
}
