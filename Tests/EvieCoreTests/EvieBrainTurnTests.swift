import Foundation
import Testing

@testable import EvieCore

/// What a turn builds from the brain it was given, and what happens when that
/// brain fails before saying anything.
@MainActor
@Suite("Evie brain turn")
struct EvieBrainTurnTests {
  // MARK: - The plan

  @Test("a tiny context never gets an input budget larger than its window")
  func tinyContextBudget() {
    var tiny = pcProfile
    tiny.contextTokens = 1_024
    tiny.maxCompletionTokens = 1_024
    #expect(EvieTurnPlan(profile: tiny, readiness: .ready).characterBudget == 0)
  }

  @Test("the character budget comes from the profile: the PC's cap, the Mac's 32K")
  func budgetPerProfile() {
    #expect(EvieTurnPlan(profile: pcProfile, readiness: .ready).characterBudget == 360_448)
    #expect(EvieTurnPlan(profile: macProfile, readiness: .ready).characterBudget == 59_392)
  }

  @Test("a profile without tools takes the direct stream, with evidence gathered first")
  func toolLessRoute() {
    let mac = EvieTurnPlan(profile: macProfile, readiness: .ready)
    let pc = EvieTurnPlan(profile: pcProfile, readiness: .ready)

    #expect(
      mac.route(hasRoots: true, searchesTheWeb: true, readsMailAndCalendar: true)
        == .agentLoop(offersTools: false))
    #expect(
      mac.route(hasRoots: false, searchesTheWeb: true, readsMailAndCalendar: false)
        == .agentLoop(offersTools: false))
    // Mail and Calendar are reached only through tools, so there is nothing to gather.
    #expect(
      mac.route(hasRoots: false, searchesTheWeb: false, readsMailAndCalendar: true) == .directStream
    )
    #expect(
      pc.route(hasRoots: true, searchesTheWeb: false, readsMailAndCalendar: false)
        == .agentLoop(offersTools: true))
    #expect(
      pc.route(hasRoots: false, searchesTheWeb: false, readsMailAndCalendar: false) == .directStream
    )
  }

  @Test("the turn's options carry the rung, so the deadlines match the model's state")
  func optionsCarryTheRung() {
    let cold = EvieTurnPlan(profile: macProfile, readiness: .modelCold)
    let ready = EvieTurnPlan(profile: pcProfile, readiness: .ready)

    #expect(cold.options(spoken: false).readiness == .modelCold)
    #expect(cold.options(spoken: false).maxTokens == 2_048)
    #expect(ready.options(spoken: true).readiness == .ready)
    #expect(ready.options(spoken: true).maxTokens == 1_024)
  }

  @Test("the persona text matches where each profile runs")
  func personaPerLocation() {
    let base = EvieCapabilitySnapshot.allEnabled
    let onPC = EviePersona.evie.systemPrompt(
      capabilities: EvieTurnPlan(profile: pcProfile, readiness: .ready).capabilities(from: base)
    )
    let onMac = EviePersona.evie.systemPrompt(
      capabilities: EvieTurnPlan(profile: macProfile, readiness: .ready).capabilities(from: base)
    )

    #expect(onPC.contains("Você roda no PC dele, que este Mac alcança pela rede Tailscale dele"))
    #expect(!onPC.contains("inteiramente neste Mac"))
    #expect(onMac.contains("Você roda inteiramente neste Mac; nada do que ele diz sai daqui."))
    #expect(!onMac.contains("Tailscale"))
  }

  @Test("a brain without tools is never told to call one")
  func toolLessPersonaNamesNoTool() {
    let capabilities = EvieTurnPlan(profile: macProfile, readiness: .ready)
      .capabilities(from: .allEnabled)
    let prompt = EviePersona.evie.systemPrompt(capabilities: capabilities)

    #expect(!capabilities.usesTools)
    #expect(!capabilities.calculates)
    #expect(!capabilities.readsMailAndCalendar)
    for tool in [
      "list_roots", "search_content", "search_web", "read_page", "calculate",
      "propose_mail", "propose_event", "read_mail",
    ] {
      #expect(!prompt.contains(tool), "\(tool)")
    }
    #expect(prompt.contains("chega junto da pergunta"))
    // The PC keeps them.
    let pcPrompt = EviePersona.evie.systemPrompt(
      capabilities: EvieTurnPlan(profile: pcProfile, readiness: .ready).capabilities(
        from: .allEnabled)
    )
    #expect(pcPrompt.contains("list_roots"))
    #expect(pcPrompt.contains("calculate"))
  }

  @Test("the prefix keeps the system prompt and the question, and drops images without vision")
  func prefixFitsTheProfile() {
    let history = longHistory(turns: 40, charactersPerTurn: 2_500)
    let question = ChatMessage(role: .user, content: "E agora?")

    let onPC = EvieTurnPlan(profile: pcProfile, readiness: .ready).prefix(history, then: [question])
    var blind = macProfile
    blind.capabilities.vision = false
    let onMac = EvieTurnPlan(profile: blind, readiness: .ready).prefix(history, then: [question])

    #expect(onPC.count == history.count + 1)
    #expect(onPC.contains { $0.images != nil })
    #expect(characters(onMac) <= 61_440)
    #expect(onMac.first?.role == .system)
    #expect(onMac.last == question)
    #expect(onMac.allSatisfy { $0.images == nil })
    // Whole turns are dropped, oldest first: no answer is left without its question.
    #expect(onMac[1].role == .user)
  }

  // MARK: - Failover

  @Test(
    "a pre-delta failure rebuilds the prefix under the 32K budget, with no tools key and no images")
  func preDeltaFailureRebuildsForTheMac() async throws {
    var blind = macProfile
    blind.capabilities.vision = false
    let pcClient = RecordingClient([.fail(.unreachable("gateway"))])
    let macClient = RecordingClient([.answer("Oi, Matheus.")])
    let harness = ResolverHarness(
      keys: .saved,
      rungs: [pc: .ready, mac: .ready],
      fallback: .automatic,
      profiles: [blind],
      clients: [pc: pcClient, mac: macClient]
    )
    let conversation = UUID()
    let history = longHistory(turns: 40, charactersPerTurn: 2_500)
    let question = ChatMessage(role: .user, content: "E agora?")
    var notices: [String?] = []

    let first = await harness.resolver.resolve(conversation: conversation)
    let answer = try await EvieBrainTurn.run(
      conversation: conversation,
      on: first,
      resolver: harness.resolver,
      onSwitch: { notices.append($0.notice) },
      attempt: { brain in
        let plan = EvieTurnPlan(brain)
        return try await text(
          of: brain.client.stream(
            messages: plan.prefix(history, then: [question]),
            tools: [],
            options: plan.options(spoken: false)
          )
        )
      }
    )

    #expect(answer == "Oi, Matheus.")
    #expect(notices == ["PC indisponível, usando o Mac"])
    #expect(harness.resolver.pinnedProfileID(for: conversation) == mac)
    let sentToPC = try #require(await pcClient.calls.first)
    #expect(sentToPC.messages.count == history.count + 1)
    let sentToMac = try #require(await macClient.calls.first)
    #expect(characters(sentToMac.messages) <= 61_440)
    #expect(sentToMac.messages.allSatisfy { $0.images == nil })
    #expect(sentToMac.tools == 0)
    #expect(sentToMac.options.readiness == .ready)

    let request = try OpenAICompatibleClient.makeRequest(
      messages: sentToMac.messages,
      tools: [],
      options: sentToMac.options,
      configuration: blind.configuration,
      bearerToken: nil
    )
    let body = try #require(
      try JSONSerialization.jsonObject(with: request.httpBody ?? Data()) as? [String: Any]
    )
    #expect(body["tools"] == nil)
    #expect(body["enable_thinking"] as? Bool == false)
    #expect(body["chat_template_kwargs"] == nil)
    #expect(!String(decoding: request.httpBody ?? Data(), as: UTF8.self).contains("image_url"))
  }

  @Test("a failure after a delta is surfaced, with no switch and no duplicated text")
  func postDeltaFailureIsFinal() async {
    let pcClient = RecordingClient([.deltaThenFail("Comecei a responder", .unreachable("gateway"))])
    let macClient = RecordingClient([.answer("Outra resposta.")])
    let harness = ResolverHarness(
      keys: .saved,
      rungs: [pc: .ready, mac: .ready],
      fallback: .automatic,
      clients: [pc: pcClient, mac: macClient]
    )
    let conversation = UUID()
    var shown: [String] = []
    var switched = false

    let first = await harness.resolver.resolve(conversation: conversation)
    await #expect(throws: ModelClientError.unreachable("gateway")) {
      _ = try await EvieBrainTurn.run(
        conversation: conversation,
        on: first,
        resolver: harness.resolver,
        onSwitch: { _ in switched = true },
        attempt: { brain in
          for try await event in brain.client.stream(messages: [], tools: [], options: .init()) {
            if case .responseTextDelta(let delta) = event {
              shown.append(delta)
            }
          }
        }
      )
    }

    #expect(!switched)
    #expect(shown == ["Comecei a responder"])
    #expect(await macClient.calls.isEmpty)
    #expect(harness.resolver.pinnedProfileID(for: conversation) == pc)
  }

  @Test("once a tool step has completed, a later failure is not retried elsewhere")
  func failureAfterAToolStepIsFinal() async {
    let pcClient = RecordingClient([
      .tools([EvieToolCall(id: "c1", name: "list_roots", argumentsJSON: "{}")]),
      .fail(.unreachable("gateway")),
    ])
    let macClient = RecordingClient([.answer("Outra resposta.")])
    let harness = ResolverHarness(
      keys: .saved,
      rungs: [pc: .ready, mac: .ready],
      fallback: .automatic,
      clients: [pc: pcClient, mac: macClient]
    )
    let conversation = UUID()
    let first = await harness.resolver.resolve(conversation: conversation)

    await #expect(throws: ModelClientError.unreachable("gateway")) {
      _ = try await EvieBrainTurn.run(
        conversation: conversation,
        on: first,
        resolver: harness.resolver,
        onSwitch: { _ in },
        attempt: { brain in
          try await EvieAgentLoop().run(
            messages: [ChatMessage(role: .user, content: "oi")],
            roots: [],
            client: brain.client,
            emit: { _ in }
          )
        }
      )
    }
    #expect(await macClient.calls.isEmpty)
  }

  @Test("the retry happens once: a second pre-delta failure is surfaced")
  func retriesOnce() async {
    let pcClient = RecordingClient([.fail(.unreachable("gateway"))])
    let macClient = RecordingClient([.fail(.unreachable("loopback"))])
    let harness = ResolverHarness(
      keys: .saved,
      rungs: [pc: .ready, mac: .ready],
      fallback: .automatic,
      clients: [pc: pcClient, mac: macClient]
    )
    let conversation = UUID()
    let first = await harness.resolver.resolve(conversation: conversation)

    await #expect(throws: ModelClientError.unreachable("loopback")) {
      _ = try await EvieBrainTurn.run(
        conversation: conversation,
        on: first,
        resolver: harness.resolver,
        onSwitch: { _ in },
        attempt: { brain in
          try await text(of: brain.client.stream(messages: [], tools: [], options: .init()))
        }
      )
    }
    #expect(await pcClient.calls.count == 1)
    #expect(await macClient.calls.count == 1)
  }

  // MARK: - The tool-less loop

  @Test("without tools the loop gathers first and sends one request with no tools")
  func toolLessLoop() async throws {
    let client = RecordingClient([.answer("68.")])
    let root = EvieFileRoot(id: "r1", displayName: "Notas", path: "/tmp/nao-existe")

    let outcome = try await EvieAgentLoop(
      web: NoWeb(),
      offersTools: false,
      readiness: .modelCold
    ).run(
      messages: [ChatMessage(role: .user, content: "quanto é 17 vezes 4?")],
      roots: [root],
      client: client,
      emit: { _ in }
    )

    let calls = await client.calls
    #expect(calls.count == 1)
    #expect(calls[0].tools == 0)
    #expect(calls[0].options.readiness == .modelCold)
    #expect(
      calls[0].messages.contains { $0.content.contains("[A Evie calculou isto automaticamente") })
    #expect(outcome.answer == "68.")
    #expect(outcome.toolCallCount == 0)
  }

  @Test("the loop passes the rung on every step")
  func loopCarriesTheRung() async throws {
    let client = RecordingClient([
      .tools([EvieToolCall(id: "c1", name: "list_roots", argumentsJSON: "{}")]),
      .answer("Nenhuma pasta."),
    ])

    _ = try await EvieAgentLoop(readiness: .ready).run(
      messages: [ChatMessage(role: .user, content: "oi")],
      roots: [],
      client: client,
      emit: { _ in }
    )

    let calls = await client.calls
    #expect(calls.map(\.options.readiness) == [.ready, .ready])
    #expect(calls.allSatisfy { $0.tools > 0 })
  }
}

// MARK: - Helpers

extension EvieBrainTurnTests {
  fileprivate var pc: String { EvieModelProfile.pcProfileID }
  fileprivate var mac: String { EvieModelProfile.macProfileID }
  fileprivate var pcProfile: EvieModelProfile { EvieModelProfileSet.builtIn.profile(id: pc)! }
  // Keep the smaller-window failover regression independent of the qualified
  // hardware default. Custom 32K profiles must still fit and preserve the tail.
  fileprivate var macProfile: EvieModelProfile {
    var profile = EvieModelProfileSet.builtIn.profile(id: mac)!
    profile.contextTokens = 32_768
    return profile
  }

  /// A system prompt, then `turns` question-and-answer pairs, the newest
  /// question carrying a picture.
  fileprivate func longHistory(turns: Int, charactersPerTurn: Int) -> [ChatMessage] {
    var history = [ChatMessage(role: .system, content: "Você é a Evie.")]
    for index in 0..<turns {
      var question = ChatMessage(
        role: .user,
        content: "Pergunta \(index) " + String(repeating: "a", count: charactersPerTurn / 2)
      )
      if index == turns - 1 {
        question.images = [
          EvieImagePart(
            id: UUID(),
            mimeType: "image/jpeg",
            data: Data([0xFF, 0xD8]),
            pixelSize: CGSize(width: 2, height: 1),
            origin: .screenshot
          )
        ]
      }
      history.append(question)
      history.append(
        ChatMessage(role: .assistant, content: String(repeating: "b", count: charactersPerTurn / 2))
      )
    }
    return history
  }

  fileprivate func characters(_ messages: [ChatMessage]) -> Int {
    messages.reduce(0) { $0 + $1.content.count }
  }

  fileprivate func text(
    of stream: AsyncThrowingStream<EvieInteractionEvent, any Error>
  ) async throws -> String {
    var text = ""
    for try await event in stream {
      if case .responseTextDelta(let delta) = event {
        text += delta
      }
    }
    return text
  }
}

/// A client that plays one scripted step per call and records each call.
actor RecordingClient: AgentClient {
  enum Step {
    case answer(String)
    case tools([EvieToolCall])
    case fail(ModelClientError)
    case deltaThenFail(String, ModelClientError)
  }

  struct Call {
    let messages: [ChatMessage]
    let tools: Int
    let options: TurnOptions
  }

  nonisolated let configuration = EvieConfiguration()
  private let steps: [Step]
  private(set) var calls: [Call] = []

  init(_ steps: [Step]) {
    self.steps = steps
  }

  private func record(_ call: Call) -> Step {
    calls.append(call)
    let index = calls.count - 1
    return index < steps.count ? steps[index] : .fail(.emptyStream)
  }

  nonisolated func stream(
    messages: [ChatMessage]
  ) -> AsyncThrowingStream<EvieInteractionEvent, any Error> {
    stream(messages: messages, tools: [], options: TurnOptions())
  }

  nonisolated func stream(
    messages: [ChatMessage],
    tools: [EvieToolDefinition],
    options: TurnOptions
  ) -> AsyncThrowingStream<EvieInteractionEvent, any Error> {
    AsyncThrowingStream { continuation in
      Task {
        let step = await record(Call(messages: messages, tools: tools.count, options: options))
        continuation.yield(.phaseChanged(.thinking))
        switch step {
        case .answer(let text):
          continuation.yield(.responseTextDelta(text))
          continuation.yield(
            .completed(message: ChatMessage(role: .assistant, content: text), finishReason: "stop")
          )
          continuation.finish()
        case .tools(let calls):
          continuation.yield(.phaseChanged(.usingTool))
          continuation.yield(
            .completed(
              message: ChatMessage(role: .assistant, content: "", toolCalls: calls),
              finishReason: "tool_calls"
            )
          )
          continuation.finish()
        case .fail(let error):
          continuation.finish(throwing: error)
        case .deltaThenFail(let text, let error):
          continuation.yield(.responseTextDelta(text))
          continuation.finish(throwing: error)
        }
      }
    }
  }
}

/// A web switched on that finds nothing.
private struct NoWeb: EvieWebSearching {
  func search(_ query: String) async throws -> [EvieSearchResult] { [] }
  func read(_ address: String) async throws -> String { "" }
}
