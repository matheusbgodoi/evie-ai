import Foundation
import Testing

@testable import EvieCore

@Suite("Research session")
struct EvieResearchTests {
  private let start = Date(timeIntervalSince1970: 1_000)

  @Test("a trigger does nothing until explicitly armed")
  func initiallyDisarmed() {
    var session = EvieResearchSession()
    #expect(throws: EvieResearchError.notArmed) { try session.begin(now: start) }
  }

  @Test("only one run can hold the armed session")
  func serialRuns() throws {
    var session = EvieResearchSession()
    try session.arm(goal: "  Resolva a questão visível  ", destination: .clipboard, now: start)
    let run = try session.begin(now: start)
    #expect(run.goal == "Resolva a questão visível")
    #expect(run.destination == .clipboard)
    #expect(throws: EvieResearchError.busy) { try session.begin(now: start) }
    session.finish(run)
    #expect(!session.allows(run, now: start))
    #expect(try session.begin(now: start).id != run.id)
  }

  @Test("stop revokes delivery, including a late answer after rearming")
  func revokesLateAnswers() throws {
    var session = EvieResearchSession()
    try session.arm(goal: "Resolva", destination: .clipboard, now: start)
    let old = try session.begin(now: start)
    session.disarm()
    #expect(!session.allows(old, now: start))
    try session.arm(goal: "Preencha", destination: .controlMac, now: start)
    let current = try session.begin(now: start)
    session.finish(old)
    #expect(session.allows(current, now: start))
    #expect(!session.allows(old, now: start))
  }

  @Test("expiry revokes an in-flight result and refuses another trigger")
  func expires() throws {
    var session = EvieResearchSession()
    try session.arm(goal: "Resolva", destination: .clipboard, now: start)
    let run = try session.begin(now: start)
    let expiry = start.addingTimeInterval(EvieResearchSession.lifetime)
    #expect(session.allows(run, now: expiry.addingTimeInterval(-0.001)))
    #expect(!session.allows(run, now: expiry))
    #expect(throws: EvieResearchError.notArmed) { try session.begin(now: expiry) }
  }

  @Test("invalid goals never grant authority")
  func invalidGoals() {
    var session = EvieResearchSession()
    for goal in [" \n ", String(repeating: "x", count: 1_201)] {
      #expect(throws: EvieResearchError.invalidGoal) {
        try session.arm(goal: goal, destination: .controlMac, now: start)
      }
      #expect(!session.isArmed(now: start))
    }
  }

  @Test("a research shortcut can start a grant but cannot approve a sensitive action")
  @MainActor func shortcutIsNotConfirmation() throws {
    let broker = EvieAgentModeBroker(policy: ComputerUseFixture.policy)
    let grant = try #require(broker.begin(goal: "Preencha", gesture: .researchShortcut))
    let observation = ComputerUseFixture.observation()
    #expect(broker.register(observation, grant: grant))
    let reading = broker.authorize(
      .readClipboard, grant: grant, observation: observation,
      live: ComputerUseFixture.live(for: observation))
    guard case .refused = reading else {
      Issue.record("Research must refuse reading the clipboard even before confirmation")
      return
    }
    let clearance = broker.authorize(
      .writeClipboard("Resposta sintética"), grant: grant, observation: observation,
      live: ComputerUseFixture.live(for: observation))
    guard case .needsConfirmation(let confirmation) = clearance else {
      Issue.record("An ungranted clipboard replacement should require confirmation")
      return
    }
    guard case .refused = broker.approve(confirmation, grant: grant, gesture: .researchShortcut)
    else {
      Issue.record("The research trigger must not approve sensitive steps")
      return
    }
    #expect(broker.begin(goal: "Preencha", gesture: .wakeWord) == nil)
  }

  @Test("the executor grant expires with the research lease, even for a late trigger")
  @MainActor func brokerSharesDeadline() throws {
    let broker = EvieAgentModeBroker(policy: ComputerUseFixture.policy, now: { start })
    let deadline = start.addingTimeInterval(3)
    let grant = try #require(
      broker.begin(
        goal: "Preencha", gesture: .researchShortcut, expiresAt: deadline))
    #expect(grant.expiresAt == deadline)
    #expect(broker.begin(goal: "Preencha", gesture: .researchShortcut, expiresAt: start) == nil)
    let capped = try #require(
      broker.begin(
        goal: "Preencha", gesture: .researchShortcut, expiresAt: .distantFuture))
    #expect(capped.expiresAt == start.addingTimeInterval(EvieAgentModeBroker.grantLifetime))
  }
}

@Suite("Research answers")
struct EvieResearchAnswerTests {
  @Test("the image reaches the model with no tools or conversation history")
  func isolatedAnswer() async throws {
    let client = ResearchTestClient(message: ChatMessage(role: .assistant, content: " 42 \n"))
    let image = self.image
    let answer = try await EvieResearchAnswer.read(
      image: image, goal: "Resolva", client: client, readiness: .ready)
    #expect(answer == "42")
    let requests = await client.requests
    #expect(requests.count == 1)
    #expect(requests[0].tools.isEmpty)
    #expect(requests[0].messages.count == 2)
    #expect(requests[0].messages.last?.images == [image])
    #expect(requests[0].messages.last?.derivedFromPicture == true)
  }

  @Test("empty, partial, and tool-call responses never become clipboard answers")
  func invalidResponses() async {
    let responses: [ChatMessage?] = [
      nil, ChatMessage(role: .assistant, content: " \n"),
      ChatMessage(
        role: .assistant, content: "x",
        toolCalls: [
          EvieToolCall(id: "c", name: "computer", argumentsJSON: "{}")
        ]),
      ChatMessage(role: .assistant, content: String(repeating: "x", count: 16_001)),
    ]
    for response in responses {
      await #expect(throws: EvieResearchError.invalidAnswer) {
        try await EvieResearchAnswer.read(
          image: image, goal: "Resolva", client: ResearchTestClient(message: response),
          readiness: .ready)
      }
    }
  }

  @Test("cancellation after a completed response still discards it")
  func cancelledResponse() async throws {
    let task = Task {
      withUnsafeCurrentTask { $0?.cancel() }
      return try await EvieResearchAnswer.read(
        image: image, goal: "Resolva",
        client: ResearchTestClient(message: ChatMessage(role: .assistant, content: "42")),
        readiness: .ready)
    }
    await #expect(throws: CancellationError.self) { try await task.value }
  }

  @Test("a truncated answer is not delivered as a complete answer")
  func truncatedAnswer() async {
    await #expect(throws: EvieResearchError.invalidAnswer) {
      try await EvieResearchAnswer.read(
        image: image, goal: "Resolva",
        client: ResearchTestClient(
          message: ChatMessage(role: .assistant, content: "incompleta"), finishReason: "length"),
        readiness: .ready)
    }
  }

  private var image: EvieImagePart {
    EvieImagePart(
      mimeType: "image/jpeg", data: Data([1]), pixelSize: CGSize(width: 1, height: 1),
      origin: .screenshot)
  }
}

private actor ResearchTestClient: AgentClient {
  nonisolated let configuration = EvieConfiguration.builtIn
  struct Request: Sendable {
    let messages: [ChatMessage]
    let tools: [EvieToolDefinition]
  }
  var requests: [Request] = []
  let message: ChatMessage?
  let finishReason: String

  init(message: ChatMessage?, finishReason: String = "stop") {
    self.message = message
    self.finishReason = finishReason
  }

  nonisolated func stream(messages: [ChatMessage]) -> AsyncThrowingStream<
    EvieInteractionEvent, any Error
  > {
    stream(messages: messages, tools: [], options: TurnOptions())
  }

  nonisolated func stream(
    messages: [ChatMessage], tools: [EvieToolDefinition], options: TurnOptions
  ) -> AsyncThrowingStream<EvieInteractionEvent, any Error> {
    AsyncThrowingStream { continuation in
      let task = Task {
        await record(messages, tools: tools)
        continuation.yield(.responseTextDelta("partial"))
        if let message {
          continuation.yield(.completed(message: message, finishReason: finishReason))
        }
        continuation.finish()
      }
      continuation.onTermination = { _ in task.cancel() }
    }
  }

  private func record(_ messages: [ChatMessage], tools: [EvieToolDefinition]) {
    requests.append(Request(messages: messages, tools: tools))
  }
}
