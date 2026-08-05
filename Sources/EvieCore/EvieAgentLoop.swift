import Foundation

/// Runs a turn in which Evie may look things up before answering.
///
/// The loop is bounded in every direction that can run away. Each step costs a
/// full request against the local model, and a step is expensive: measured on
/// this Mac against a freshly started server, one tool took 20 s end to end and a
/// three-tool chain took 37 s. Four steps is enough for the deepest sensible
/// chain here (list_roots → search_files → read_file → answer) and short enough
/// that a confused model gives up while the user is still willing to wait.
///
/// Those numbers hold only on a server that has not been running for hours. The
/// same four questions against a server up for ten hours took 102 s, 123 s,
/// 318 s and 235 s — the request cost had grown from about 6 s to nearly 60 s
/// regardless of prompt size. That is a defect in the inference server, not in
/// this loop, but it is what makes the difference between usable and not.
public struct EvieAgentLoop: Sendable {
  /// How many times the model may ask for tools before it must answer.
  public static let maximumIterations = 4
  /// How many calls are honoured in a single step. A model that asks for twenty
  /// at once has lost the thread.
  public static let maximumCallsPerIteration = 4

  public var toolbox: EvieFileToolbox
  public var maximumIterations: Int

  public init(
    toolbox: EvieFileToolbox = EvieFileToolbox(),
    maximumIterations: Int = EvieAgentLoop.maximumIterations
  ) {
    self.toolbox = toolbox
    self.maximumIterations = maximumIterations
  }

  /// What the turn produced.
  public struct Outcome: Sendable {
    /// Everything added to the conversation: the assistant turns that asked for
    /// tools, the results, and the final answer.
    public var appended: [ChatMessage]
    /// The answer to show and speak. Empty when the model never produced one.
    public var answer: String
    /// How many tools actually ran, for the user to see afterwards.
    public var toolCallCount: Int
    /// True when the loop hit its ceiling instead of the model finishing.
    public var exhausted: Bool
  }

  /// Runs the turn.
  ///
  /// `emit` receives the same events a plain turn produces, so the overlay shows
  /// text streaming in exactly as it always did, plus the phase changes that say
  /// she is looking something up. It is `async` so the interface can be updated
  /// on the main actor while the loop itself — including the blocking file reads
  /// a tool performs — stays off it.
  public func run(
    messages: [ChatMessage],
    roots: [EvieFileRoot],
    client: any AgentClient,
    emit: @Sendable (EvieInteractionEvent) async -> Void
  ) async throws -> Outcome {
    var conversation = messages
    var appended: [ChatMessage] = []
    var toolCallCount = 0
    let tools = EvieFileToolbox.definitions

    for iteration in 0..<maximumIterations {
      try Task.checkCancellation()

      let isLastIteration = iteration == maximumIterations - 1
      // On the last pass the tools are withdrawn. Offering them again would
      // invite a call that can no longer be honoured, and the model would stop
      // having said nothing to the user.
      let step = try await Self.completeOnce(
        messages: conversation,
        tools: isLastIteration ? [] : tools,
        client: client,
        emit: emit
      )

      guard let calls = step.message.toolCalls, !calls.isEmpty else {
        appended.append(step.message)
        return Outcome(
          appended: appended,
          answer: step.message.content,
          toolCallCount: toolCallCount,
          exhausted: false
        )
      }

      conversation.append(step.message)
      appended.append(step.message)

      let honoured = calls.prefix(Self.maximumCallsPerIteration)
      for call in honoured {
        try Task.checkCancellation()
        await emit(.status(message: Self.describe(call)))

        let result = toolbox.execute(call, roots: roots)
        toolCallCount += 1
        conversation.append(result.message)
        appended.append(result.message)
      }
      // A call that was not run still needs an answer, or the model waits for a
      // result that never comes and the next turn is malformed.
      for call in calls.dropFirst(Self.maximumCallsPerIteration) {
        let refusal = EvieToolResult(
          callID: call.id,
          name: call.name,
          content: "Pedidos demais de uma vez. Peça um por vez.",
          isFailure: true
        )
        conversation.append(refusal.message)
        appended.append(refusal.message)
      }
    }

    return Outcome(
      appended: appended,
      answer: "",
      toolCallCount: toolCallCount,
      exhausted: true
    )
  }
}

extension EvieAgentLoop {
  fileprivate struct Step {
    var message: ChatMessage
    var finishReason: EvieFinishReason
  }

  /// One request, collapsed from the event stream into a single message.
  fileprivate static func completeOnce(
    messages: [ChatMessage],
    tools: [EvieToolDefinition],
    client: any AgentClient,
    emit: @Sendable (EvieInteractionEvent) async -> Void
  ) async throws -> Step {
    var message: ChatMessage?
    var finishReason = EvieFinishReason.other

    for try await event in client.stream(messages: messages, tools: tools) {
      try Task.checkCancellation()
      await emit(event)
      if case .completed(let completed, let reason) = event {
        message = completed
        finishReason = EvieFinishReason(wireValue: reason)
      }
    }

    guard let message else {
      throw TurboFieldfareClientError.emptyStream
    }
    return Step(message: message, finishReason: finishReason)
  }

  /// What the overlay says while a tool runs.
  ///
  /// Said in terms of what the user granted, never in terms of a path or an
  /// identifier: "olhando em Downloads" is the truth at the level they care
  /// about.
  fileprivate static func describe(_ call: EvieToolCall) -> String {
    let arguments = (try? call.arguments()) ?? [:]
    switch EvieFileToolbox.ToolName(rawValue: call.name) {
    case .listRoots:
      return "Vendo o que você me autorizou…"
    case .listFolder:
      return "Olhando a pasta…"
    case .readFile:
      if let path = arguments["path"], !path.isEmpty {
        return "Lendo \((path as NSString).lastPathComponent)…"
      }
      return "Lendo um arquivo…"
    case .searchFiles:
      if let query = arguments["query"], !query.isEmpty {
        return "Procurando por \"\(query)\"…"
      }
      return "Procurando…"
    case .fileInfo:
      return "Conferindo os detalhes…"
    case nil:
      return "Um instante…"
    }
  }
}
