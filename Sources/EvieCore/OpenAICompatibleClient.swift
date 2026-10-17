import Foundation
import Synchronization

/// A dependency-free client for any OpenAI-compatible streaming Chat Completions
/// server: the PC gateway over the tailnet, or a server on this Mac's loopback.
///
/// Before a byte leaves the Mac the endpoint must pass `ModelTransportPolicy`,
/// and the key goes only over https to the host it was saved for — except the
/// Mac brain's per-launch key, which goes over http to 127.0.0.1 on that
/// brain's own port and nowhere else (ADR 0017). Redirects are refused
/// outright, so the `Authorization` header cannot follow one anywhere.
///
/// The client only performs inference. Tool execution and authorization belong to
/// Hermes/the Evie supervisor and are intentionally outside this adapter.
///
/// Build it through `ModelClientFactory`, which is where the keychain and the
/// policy are chosen.
public final class OpenAICompatibleClient: AgentClient, Sendable {
  public let configuration: EvieConfiguration
  private let credentials: any EvieCredentialProviding
  private let transportPolicy: ModelTransportPolicy
  private let session: URLSession
  private let deadlines: ModelDeadlinePolicy
  private let localBrainKey: LocalBrainKeyFile

  /// The largest body Evie sends. The gateway refuses anything over 64 MB with a
  /// 413; refusing at 60 MiB here means the conversation is never uploaded only
  /// to be thrown away, and leaves room for the gateway's own framing.
  static let maximumRequestBytes = 60 * 1_024 * 1_024

  /// Internal on purpose: outside EvieCore the only way to get a client is
  /// `ModelClientFactory`, so no caller can pick its own policy or key source.
  init(
    configuration: EvieConfiguration,
    credentials: any EvieCredentialProviding,
    transportPolicy: ModelTransportPolicy,
    session: URLSession,
    deadlines: ModelDeadlinePolicy = .standard,
    localBrainKey: LocalBrainKeyFile
  ) {
    self.configuration = configuration
    self.credentials = credentials
    self.transportPolicy = transportPolicy
    self.session = session
    self.deadlines = deadlines
    self.localBrainKey = localBrainKey
  }

  public func stream(
    messages: [ChatMessage]
  ) -> AsyncThrowingStream<EvieInteractionEvent, any Error> {
    stream(messages: messages, tools: [], options: .chat(configuration))
  }

  public func stream(
    messages: [ChatMessage],
    tools: [EvieToolDefinition]
  ) -> AsyncThrowingStream<EvieInteractionEvent, any Error> {
    stream(messages: messages, tools: tools, options: .chat(configuration))
  }

  /// The same turn, with a set of functions the model may ask for and the
  /// options that shape the request.
  ///
  /// Streaming is kept for tool turns rather than falling back to a plain
  /// request: the running server was measured emitting a complete, well-formed
  /// tool call inside a normal SSE delta, so there is no reason to maintain two
  /// request paths, and ordinary text still arrives token by token.
  public func stream(
    messages: [ChatMessage],
    tools: [EvieToolDefinition],
    options: TurnOptions
  ) -> AsyncThrowingStream<EvieInteractionEvent, any Error> {
    let turn = Turn(
      messages: messages,
      tools: tools,
      options: options,
      configuration: configuration,
      credentials: credentials,
      transportPolicy: transportPolicy,
      session: session,
      deadlines: deadlines,
      localBrainKey: localBrainKey
    )

    return AsyncThrowingStream { continuation in
      let requestTask = Task {
        do {
          try await turn.run(continuation: continuation)
        } catch is CancellationError {
          continuation.finish(throwing: CancellationError())
        } catch let error as EvieConfiguration.ValidationError {
          continuation.finish(
            throwing: ModelClientError.invalidConfiguration(error.localizedDescription)
          )
        } catch let error as ModelClientError {
          continuation.finish(throwing: error)
        } catch let error as URLError where error.code == .cancelled {
          continuation.finish(
            throwing: Task.isCancelled ? CancellationError() : ModelClientError.cancelled
          )
        } catch {
          continuation.finish(
            throwing: ModelClientError.unreachable(error.localizedDescription)
          )
        }
      }

      continuation.onTermination = { @Sendable _ in
        requestTask.cancel()
      }
    }
  }
}

/// Everything one request needs, gathered so the work runs off the client.
private struct Turn: Sendable {
  let messages: [ChatMessage]
  let tools: [EvieToolDefinition]
  let options: TurnOptions
  let configuration: EvieConfiguration
  let credentials: any EvieCredentialProviding
  let transportPolicy: ModelTransportPolicy
  let session: URLSession
  let deadlines: ModelDeadlinePolicy
  let localBrainKey: LocalBrainKeyFile

  typealias Continuation = AsyncThrowingStream<EvieInteractionEvent, any Error>.Continuation

  func run(continuation: Continuation) async throws {
    try Task.checkCancellation()
    try configuration.validate()
    let url = configuration.chatCompletionsURL
    if case .refused(let reason) = transportPolicy.evaluate(
      url,
      credentialHost: configuration.credential?.boundHost
    ) {
      throw ModelClientError.transportRefused(reason)
    }
    let bearerToken =
      try await OpenAICompatibleClient.bearerToken(
        for: url,
        credential: configuration.credential,
        from: credentials
      )
      ?? OpenAICompatibleClient.localBrainToken(
        for: url,
        port: configuration.localBrainPort,
        from: localBrainKey
      )
    let inputTokens = OpenAICompatibleClient.estimatedInputTokens(in: messages)
    let request = try OpenAICompatibleClient.makeRequest(
      messages: messages,
      tools: tools,
      options: options,
      configuration: configuration,
      bearerToken: bearerToken,
      deadlines: deadlines,
      inputTokens: inputTokens
    )
    let watchdog = ResponseWatchdog(
      deadlines: deadlines.deadlines(
        readiness: options.readiness,
        carriesImage: messages.contains { !($0.images ?? []).isEmpty },
        configuration: configuration,
        inputTokens: inputTokens
      )
    )
    let outputCap = OpenAICompatibleClient.outputCap(options: options, configuration: configuration)
    continuation.yield(.phaseChanged(.thinking))

    try await watchdog.guarding {
      let (bytes, response) = try await session.bytes(
        for: request,
        delegate: RedirectRefusal()
      )
      watchdog.headersArrived()
      try Task.checkCancellation()

      guard let httpResponse = response as? HTTPURLResponse else {
        throw ModelClientError.unreachable("a resposta não era HTTP")
      }
      guard (200...299).contains(httpResponse.statusCode) else {
        let errorBody = try await OpenAICompatibleClient.readErrorBody(from: bytes)
        if httpResponse.statusCode == 401, bearerToken != nil,
          let credential = configuration.credential
        {
          // Dropped so the next turn reads the keychain again — the key may
          // have been replaced — but this turn is not retried with it.
          await credentials.invalidate(credential)
        }
        throw OpenAICompatibleClient.httpError(
          status: httpResponse.statusCode,
          body: errorBody,
          model: configuration.model
        )
      }

      try await OpenAICompatibleClient.consumeStream(
        bytes,
        outputCap: outputCap,
        watchdog: watchdog,
        continuation: continuation
      )
    }
  }
}

/// Refuses every HTTP redirect by handing back no request.
///
/// The model endpoints Evie uses never redirect, so a redirect is either a
/// misconfiguration or someone steering the request — and following one would
/// carry the `Authorization` header to wherever `Location` points. With the
/// redirect refused, the 3xx itself becomes the response and is reported as an
/// HTTP error. It is a task delegate rather than a session delegate so it holds
/// for any session the client is given, `URLSession.shared` included. The
/// readiness probe uses it too, since its model-list request carries the key.
final class RedirectRefusal: NSObject, URLSessionTaskDelegate, Sendable {
  func urlSession(
    _ session: URLSession,
    task: URLSessionTask,
    willPerformHTTPRedirection response: HTTPURLResponse,
    newRequest request: URLRequest
  ) async -> URLRequest? {
    nil
  }
}

/// Ends a turn that waits too long for its headers or for its first token.
///
/// The idle gap (`URLRequest.timeoutInterval`) cannot do this: it restarts on
/// every byte, and a request waiting on a cold model or a long prefill receives
/// no bytes at all, so it would wait the whole gap at each stage. The watchdog
/// runs beside the request and cancels it when the current stage's deadline
/// passes; the request reports which deadline that was.
private final class ResponseWatchdog: Sendable {
  private enum Stage: Equatable {
    case awaitingHeaders
    case awaitingFirstToken
    case streaming
  }

  private struct State {
    var stage: Stage
    var deadline: ContinuousClock.Instant
  }

  private let deadlines: ModelTurnDeadlines
  private let state: Mutex<State>

  init(deadlines: ModelTurnDeadlines) {
    self.deadlines = deadlines
    state = Mutex(State(stage: .awaitingHeaders, deadline: .now + deadlines.headers))
  }

  func headersArrived() {
    let firstToken = deadlines.firstToken
    state.withLock { state in
      guard state.stage == .awaitingHeaders else { return }
      state = State(stage: .awaitingFirstToken, deadline: .now + firstToken)
    }
  }

  func firstTokenArrived() {
    state.withLock { $0.stage = .streaming }
  }

  /// Runs `work`, cancelling it with the matching error if a deadline passes
  /// first. Once the first token is in, only the idle gap applies.
  func guarding(_ work: @escaping @Sendable () async throws -> Void) async throws {
    try await withThrowingTaskGroup(of: Bool.self) { group in
      group.addTask {
        try await work()
        return true
      }
      group.addTask {
        try await self.enforce()
        return false
      }
      while let workFinished = try await group.next() {
        if workFinished {
          group.cancelAll()
          return
        }
      }
    }
  }

  private func enforce() async throws {
    while true {
      let current = state.withLock { $0 }
      switch current.stage {
      case .streaming:
        return
      case .awaitingHeaders, .awaitingFirstToken:
        if ContinuousClock.now >= current.deadline {
          throw current.stage == .awaitingHeaders
            ? ModelClientError.headersTimedOut
            : ModelClientError.firstTokenTimedOut
        }
        // Wakes at the deadline of the stage it saw; if the stage moved on in
        // the meantime the loop simply reads the new deadline.
        try await Task.sleep(until: current.deadline, clock: .continuous)
      }
    }
  }
}

extension OpenAICompatibleClient {
  /// The token to attach, or `nil` when none may be.
  ///
  /// A token is attached only over https, and only to the host its credential
  /// was saved for — never over plain http, loopback included, because a
  /// loopback port can be bound by any local process. When a token applies but
  /// nothing is saved, the request is not sent at all: an unauthenticated
  /// request to the PC could only fail, and would do so after the gateway has
  /// logged it. The readiness probe asks the same question, so the two cannot
  /// disagree about where the key may go.
  static func bearerToken(
    for url: URL,
    credential: CredentialReference?,
    from credentials: any EvieCredentialProviding
  ) async throws -> String? {
    guard url.scheme?.lowercased() == "https",
      let credential,
      let host = url.host?.lowercased(),
      credential.boundHost.lowercased() == host
    else {
      return nil
    }

    let token: String?
    do {
      token = try await credentials.bearerToken(for: credential)
    } catch {
      throw ModelClientError.credentialUnavailable(error.localizedDescription)
    }
    guard let token else {
      throw ModelClientError.credentialUnavailable(
        "nenhuma chave salva para \(host)."
      )
    }
    return token
  }

  /// The Mac brain's per-launch key, or nil when it does not apply: the one
  /// key that goes over plain http, and the narrow exception to the rule
  /// above (ADR 0017).
  ///
  /// It goes only to `http://127.0.0.1:<port>`, the port Evie started that
  /// brain on and checked the listener of; not to `localhost` or `::1`, which
  /// another process could hold, not to another loopback port, and never to a
  /// configuration that is not the brain's (`localBrainPort` nil). What it can
  /// open is that one server, for that one launch: it is made at the start,
  /// lives in a 0600 file and the server's environment, and dies with the
  /// server. A missing or unreadable file sends nothing, and the server
  /// answers 401.
  static func localBrainToken(
    for url: URL,
    port: Int?,
    from keyFile: LocalBrainKeyFile
  ) -> String? {
    guard let port,
      url.scheme?.lowercased() == "http",
      url.host == "127.0.0.1",
      url.port == port
    else {
      return nil
    }
    return keyFile.read()
  }

  /// The output cap the request asks for: the turn's own, never above the
  /// configuration's.
  static func outputCap(options: TurnOptions, configuration: EvieConfiguration) -> Int {
    min(options.maxTokens ?? configuration.maxCompletionTokens, configuration.maxCompletionTokens)
  }

  /// Same character/picture proxy as conversation planning, not a tokenizer.
  /// Computed once for a streamed turn and shared by URLSession and watchdog.
  static func estimatedInputTokens(in messages: [ChatMessage]) -> Int {
    let characters = EvieTurnPlan.characters(in: messages)
    return characters / 2 + characters % 2
  }

  /// The request for one turn. Synchronous and free of I/O — the token is read
  /// before the call — so the body can be tested without a server.
  static func makeRequest(
    messages: [ChatMessage],
    tools: [EvieToolDefinition],
    options: TurnOptions,
    configuration: EvieConfiguration,
    bearerToken: String?,
    deadlines: ModelDeadlinePolicy = .standard,
    inputTokens: Int? = nil
  ) throws -> URLRequest {
    let preparedMessages = try EvieLensImagePreparation.prepare(
      messages, configuration: configuration)
    var request = URLRequest(url: configuration.chatCompletionsURL)
    request.httpMethod = "POST"
    request.timeoutInterval =
      deadlines.deadlines(
        readiness: options.readiness,
        carriesImage: messages.contains { !($0.images ?? []).isEmpty },
        configuration: configuration,
        inputTokens: inputTokens ?? estimatedInputTokens(in: messages)
      ).idleGap
    request.setValue("application/json", forHTTPHeaderField: "Content-Type")
    request.setValue("text/event-stream", forHTTPHeaderField: "Accept")
    if let bearerToken {
      request.setValue("Bearer \(bearerToken)", forHTTPHeaderField: "Authorization")
    }

    let outputCap = outputCap(options: options, configuration: configuration)
    let thinking = ThinkingParameters(
      style: configuration.thinkingStyle,
      options: options,
      outputCap: outputCap
    )
    let body = ChatCompletionRequest(
      model: configuration.model,
      messages: WireConversation.messages(from: preparedMessages),
      stream: true,
      streamOptions: .init(includeUsage: true),
      maxTokens: outputCap,
      temperature: configuration.temperature,
      topP: configuration.topP,
      stop: configuration.stopSequences.isEmpty ? nil : configuration.stopSequences,
      // Sent only with tools: a server may reject the field on a request that
      // declares none, and one call per turn is what the agent loop expects.
      parallelToolCalls: tools.isEmpty ? nil : false,
      chatTemplateKwargs: thinking.templateKwargs,
      enableThinking: thinking.topLevelEnable,
      thinkingBudgetTokens: thinking.budget,
      // mlx-vlm 0.7.8 (the `.topLevel` server) compacts on its own whenever a
      // prompt would not fit under its --max-kv-size: it asks the model to
      // summarize the older messages and answers from the summary. Evie's
      // character budget already keeps the prompt inside the context, so that
      // would only ever rewrite a conversation behind her back; an empty list
      // turns it off, and an oversized request then fails with a 400 instead.
      // Read from the installed source and checked live, 2026-10-16.
      contextManagement: configuration.thinkingStyle == .topLevel ? [] : nil
    )

    let encoded: Data
    do {
      let encoder = JSONEncoder()
      // A base64 image is full of "/"; escaping each one would add bytes for
      // nothing, since every JSON reader decodes both forms the same.
      encoder.outputFormatting = [.withoutEscapingSlashes]
      encoded = try encoder.encode(body)
    } catch {
      throw ModelClientError.requestEncoding(error.localizedDescription)
    }
    let finished = tools.isEmpty ? encoded : try graft(tools: tools, onto: encoded)
    guard finished.count <= maximumRequestBytes else {
      throw ModelClientError.requestTooLarge
    }
    request.httpBody = finished
    return request
  }

  /// JSON Schema is open-ended, so the tools are built as dictionaries and
  /// grafted onto the encoded body. Keeping the other fields in `Encodable`
  /// means there is still one description of them.
  private static func graft(tools: [EvieToolDefinition], onto encoded: Data) throws -> Data {
    do {
      guard var object = try JSONSerialization.jsonObject(with: encoded) as? [String: Any]
      else {
        throw ModelClientError.requestEncoding("o corpo não era um objeto")
      }
      object["tools"] = tools.map(\.wireRepresentation)
      return try JSONSerialization.data(
        withJSONObject: object,
        options: [.sortedKeys, .withoutEscapingSlashes]
      )
    } catch let error as ModelClientError {
      throw error
    } catch {
      throw ModelClientError.requestEncoding(error.localizedDescription)
    }
  }

  /// What a non-2xx status means for the caller. The bodies are the gateway's:
  /// llama-swap answers with `{"error": "<text>"}`, gateway-edge with
  /// `{"type":"error","error":{…}}`, the engine with an OpenAI error object.
  fileprivate static func httpError(status: Int, body: String?, model: String) -> ModelClientError {
    let message = body.flatMap(decodeAPIError(from:))?.message ?? body ?? ""
    switch status {
    case 401:
      return .unauthorized
    case 404 where message.localizedCaseInsensitiveContains("no router"):
      return .modelNotFound(model)
    case 413:
      return .requestTooLarge
    case 502:
      // gateway-edge could not reach the engine, or Tailscale Serve is up
      // while the gateway is stopped (the PC's gaming mode).
      return .unreachable("gateway")
    default:
      return .server(status: status, message: message)
    }
  }

  fileprivate static func consumeStream(
    _ bytes: URLSession.AsyncBytes,
    outputCap: Int,
    watchdog: ResponseWatchdog,
    continuation: AsyncThrowingStream<EvieInteractionEvent, any Error>.Continuation
  ) async throws {
    var lineBuffer = SSELineBuffer()
    var eventBuffer = SSEDataBuffer()
    var inlineThinking = InlineThinkingSplitter()
    var fullText = ""
    var finishReason: String?
    var completionTokens: Int?
    var receivedReasoning = false
    var receivedEvent = false
    var receivedDone = false
    var toolCalls = EvieToolCallAccumulator()
    var announcedToolPhase = false

    func emit(_ pieces: [InlineThinkingSplitter.Piece]) {
      for piece in pieces {
        switch piece {
        case .answer(let text):
          fullText += text
          continuation.yield(.responseTextDelta(text))
        case .reasoning(let text):
          receivedReasoning = true
          continuation.yield(.reasoningDelta(text))
        }
      }
    }

    func processPayload(_ payload: String) throws -> Bool {
      switch try decodeStreamPayload(payload) {
      case .done:
        return true

      case .chunk(let chunk):
        if let error = chunk.error {
          throw ModelClientError.streamFailed(message: error.message, code: error.code)
        }

        if let usage = chunk.usage {
          completionTokens = usage.completionTokens
          continuation.yield(.usage(usage.normalized))
        }

        for choice in chunk.choices ?? [] {
          if let reasoning = choice.delta.reasoning, !reasoning.isEmpty {
            watchdog.firstTokenArrived()
            inlineThinking.noteSeparateReasoning()
            emit([.reasoning(reasoning)])
          }
          if let delta = choice.delta.content, !delta.isEmpty {
            watchdog.firstTokenArrived()
            emit(inlineThinking.consume(delta))
          }
          for fragment in choice.delta.toolCalls ?? [] {
            watchdog.firstTokenArrived()
            toolCalls.absorb(
              index: fragment.index,
              id: fragment.id,
              name: fragment.function?.name,
              argumentsFragment: fragment.function?.arguments
            )
            if !announcedToolPhase {
              announcedToolPhase = true
              continuation.yield(.phaseChanged(.usingTool))
            }
          }
          if let reason = choice.finishReason {
            finishReason = reason
          }
        }
        return false
      }
    }

    streamLoop: for try await byte in bytes {
      try Task.checkCancellation()

      guard let line = try lineBuffer.consume(byte: byte) else {
        continue
      }
      guard let payload = eventBuffer.consume(line: line) else {
        continue
      }
      receivedEvent = true
      if try processPayload(payload) {
        receivedDone = true
        break streamLoop
      }
    }

    if !receivedDone,
      let line = try lineBuffer.finish(),
      let payload = eventBuffer.consume(line: line)
    {
      receivedEvent = true
      if try processPayload(payload) {
        receivedDone = true
      }
    }

    if !receivedDone, let payload = eventBuffer.finish() {
      receivedEvent = true
      receivedDone = try processPayload(payload)
    }

    guard receivedEvent else {
      throw ModelClientError.emptyStream
    }
    guard receivedDone else {
      throw ModelClientError.streamEndedBeforeDone
    }
    emit(inlineThinking.finish())

    // The engine can say "stop" when it was cut at the limit, which the gateway
    // does not correct; the usage is the reliable witness.
    let reachedCap = finishReason == "length" || (completionTokens ?? 0) >= outputCap
    let assembled = toolCalls.calls()
    let answered =
      !fullText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || !assembled.isEmpty
    if !answered, receivedReasoning || reachedCap {
      throw reachedCap
        ? ModelClientError.truncated(completionTokens: completionTokens ?? outputCap)
        : ModelClientError.emptyStream
    }

    try Task.checkCancellation()
    let message = ChatMessage(
      role: .assistant,
      content: fullText,
      toolCalls: assembled.isEmpty ? nil : assembled
    )
    continuation.yield(
      .completed(message: message, finishReason: reachedCap ? "length" : finishReason)
    )
    continuation.finish()
  }

  fileprivate static func decodeStreamPayload(_ payload: String) throws -> StreamPayload {
    if payload.trimmingCharacters(in: .whitespacesAndNewlines) == "[DONE]" {
      return .done
    }

    guard let data = payload.data(using: .utf8) else {
      throw ModelClientError.malformedStreamEvent
    }

    do {
      return .chunk(try JSONDecoder().decode(StreamChunk.self, from: data))
    } catch {
      throw ModelClientError.malformedStreamEvent
    }
  }

  fileprivate static func readErrorBody(from bytes: URLSession.AsyncBytes) async throws -> String? {
    let maximumBytes = 8_192
    var body = Data()
    body.reserveCapacity(maximumBytes)

    for try await byte in bytes {
      try Task.checkCancellation()
      guard body.count < maximumBytes else { break }
      body.append(byte)
    }

    guard !body.isEmpty else { return nil }
    return String(data: body, encoding: .utf8)?
      .trimmingCharacters(in: .whitespacesAndNewlines)
  }

  fileprivate static func decodeAPIError(from body: String) -> APIError? {
    guard let data = body.data(using: .utf8) else { return nil }
    return try? JSONDecoder().decode(APIErrorEnvelope.self, from: data).error
  }
}

/// The thinking fields for one request, in the form its server understands.
private struct ThinkingParameters {
  var templateKwargs: ChatTemplateKwargs?
  var topLevelEnable: Bool?
  var budget: Int?

  init(style: ThinkingParameterStyle, options: TurnOptions, outputCap: Int) {
    let thinks = options.reasoning != .off
    switch style {
    case .templateKwargs:
      // Off sends only the switch: the gateway drops an effort that comes with
      // thinking off, and an absent switch means the template's default, which
      // for Qwen is to think.
      templateKwargs =
        thinks
        ? ChatTemplateKwargs(
          enableThinking: true,
          reasoningEffort: options.reasoning.rawValue,
          preserveThinking: false
        )
        : ChatTemplateKwargs(enableThinking: false, reasoningEffort: nil, preserveThinking: nil)
      budget =
        thinks
        ? options.thinkingBudgetTokens.map {
          min($0, ReasoningLevel.thinkingBudget(forOutputCap: outputCap))
        }
        : nil
    case .topLevel:
      topLevelEnable = thinks
    case .none:
      break
    }
  }
}

/// The conversation as the wire carries it.
///
/// The first message, when it is the system prompt, goes out byte for byte: it
/// is the head of the server's prefix cache. Any later system or developer
/// message — skill guidance, a screen note — is not merged into it, which would
/// change the cached head whenever a skill came or went, and not sent as a
/// system message either, which Qwen's template refuses after index 0. It is
/// wrapped in `<system-context>` and prepended to the next user message, the
/// same rewrite the PC gateway applies to a late system message.
private enum WireConversation {
  static func messages(from messages: [ChatMessage]) -> [APIMessage] {
    var wire: [APIMessage] = []
    var lateInstructions: [String] = []

    for (index, message) in messages.enumerated() {
      if index > 0, message.role == .system || message.role == .developer {
        let text = message.content.trimmingCharacters(in: .whitespacesAndNewlines)
        if !text.isEmpty {
          lateInstructions.append(text)
        }
        continue
      }
      if message.role == .user, !lateInstructions.isEmpty {
        wire.append(APIMessage(message, systemContext: block(lateInstructions)))
        lateInstructions.removeAll()
      } else {
        wire.append(APIMessage(message, systemContext: nil))
      }
    }
    // Guidance with no question after it still has to arrive somewhere.
    if !lateInstructions.isEmpty {
      wire.append(APIMessage(role: .user, content: .text(block(lateInstructions))))
    }
    return wire
  }

  /// Text that is already a block is kept as it is, so replaying a rewritten
  /// conversation cannot nest the tags.
  private static func block(_ instructions: [String]) -> String {
    instructions.map { text in
      text.hasPrefix("<system-context>") && text.hasSuffix("</system-context>")
        ? text
        : "<system-context>\n\(text)\n</system-context>"
    }.joined(separator: "\n\n")
  }
}

private struct ChatCompletionRequest: Encodable {
  let model: String
  let messages: [APIMessage]
  let stream: Bool
  let streamOptions: StreamOptions
  /// `max_tokens`, not `max_completion_tokens`: it is what the gateway, every
  /// other client of it and the loopback server all honour.
  let maxTokens: Int
  let temperature: Double?
  let topP: Double?
  let stop: [String]?
  let parallelToolCalls: Bool?
  let chatTemplateKwargs: ChatTemplateKwargs?
  let enableThinking: Bool?
  let thinkingBudgetTokens: Int?
  /// Always empty when sent: no compaction rule at all.
  let contextManagement: [String]?

  enum CodingKeys: String, CodingKey {
    case model
    case messages
    case stream
    case streamOptions = "stream_options"
    case maxTokens = "max_tokens"
    case temperature
    case topP = "top_p"
    case stop
    case parallelToolCalls = "parallel_tool_calls"
    case chatTemplateKwargs = "chat_template_kwargs"
    case enableThinking = "enable_thinking"
    case thinkingBudgetTokens = "thinking_budget_tokens"
    case contextManagement = "context_management"
  }
}

private struct ChatTemplateKwargs: Encodable {
  let enableThinking: Bool
  let reasoningEffort: String?
  let preserveThinking: Bool?

  enum CodingKeys: String, CodingKey {
    case enableThinking = "enable_thinking"
    case reasoningEffort = "reasoning_effort"
    case preserveThinking = "preserve_thinking"
  }
}

private struct StreamOptions: Encodable {
  let includeUsage: Bool

  enum CodingKeys: String, CodingKey {
    case includeUsage = "include_usage"
  }
}

private struct APIMessage: Encodable {
  let role: String
  let content: APIContent
  let name: String?
  let toolCallID: String?
  let toolCalls: [APIToolCall]?

  init(role: ChatRole, content: APIContent) {
    self.role = role.rawValue
    self.content = content
    name = nil
    toolCallID = nil
    toolCalls = nil
  }

  init(_ message: ChatMessage, systemContext: String?) {
    role = message.role.rawValue
    let text =
      switch systemContext {
      case nil: message.content
      case let context? where message.content.isEmpty: context
      case let context?: context + "\n\n" + message.content
      }
    if let images = message.images, !images.isEmpty {
      content = .parts([.text(text)] + images.map { .image(dataURL: $0.dataURL) })
    } else {
      content = .text(text)
    }
    name = message.name
    toolCallID = message.toolCallID
    toolCalls = message.toolCalls.map { $0.map(APIToolCall.init) }
  }

  enum CodingKeys: String, CodingKey {
    case role
    case content
    case name
    case toolCallID = "tool_call_id"
    case toolCalls = "tool_calls"
  }
}

/// A plain string unless the message carries an image, so a text-only request
/// is the same bytes it always was.
private enum APIContent: Encodable {
  case text(String)
  case parts([APIContentPart])

  func encode(to encoder: any Encoder) throws {
    var container = encoder.singleValueContainer()
    switch self {
    case .text(let text): try container.encode(text)
    case .parts(let parts): try container.encode(parts)
    }
  }
}

private enum APIContentPart: Encodable {
  case text(String)
  case image(dataURL: String)

  private enum CodingKeys: String, CodingKey {
    case type
    case text
    case imageURL = "image_url"
  }

  private struct ImageURL: Encodable {
    let url: String
  }

  func encode(to encoder: any Encoder) throws {
    var container = encoder.container(keyedBy: CodingKeys.self)
    switch self {
    case .text(let text):
      try container.encode("text", forKey: .type)
      try container.encode(text, forKey: .text)
    case .image(let dataURL):
      try container.encode("image_url", forKey: .type)
      try container.encode(ImageURL(url: dataURL), forKey: .imageURL)
    }
  }
}

/// A call being sent back so the model can see what it asked for.
///
/// The identifier is carried through untouched — it is how the model pairs its
/// own request with the result that follows it.
private struct APIToolCall: Encodable {
  let id: String
  let type: String
  let function: Function

  init(_ call: EvieToolCall) {
    id = call.id
    type = "function"
    function = Function(name: call.name, arguments: call.argumentsJSON)
  }

  struct Function: Encodable {
    let name: String
    let arguments: String
  }
}

private enum StreamPayload {
  case done
  case chunk(StreamChunk)
}

private struct StreamChunk: Decodable {
  let choices: [StreamChoice]?
  let usage: APIUsage?
  let error: APIError?
}

private struct StreamChoice: Decodable {
  let delta: StreamDelta
  let finishReason: String?

  enum CodingKeys: String, CodingKey {
    case delta
    case finishReason = "finish_reason"
  }
}

private struct StreamDelta: Decodable {
  let content: String?
  /// `reasoning_content` from llama.cpp (`--reasoning-format deepseek`, as the
  /// PC runs it — recorded 2026-10-16), or `reasoning` from servers that use
  /// the newer name.
  let reasoning: String?
  let toolCalls: [StreamToolCall]?

  init(from decoder: any Decoder) throws {
    let container = try decoder.container(keyedBy: CodingKeys.self)
    content = try container.decodeIfPresent(String.self, forKey: .content)
    reasoning =
      try container.decodeIfPresent(String.self, forKey: .reasoningContent)
      ?? container.decodeIfPresent(String.self, forKey: .reasoning)
    toolCalls = try container.decodeIfPresent([StreamToolCall].self, forKey: .toolCalls)
  }

  enum CodingKeys: String, CodingKey {
    case content
    case reasoningContent = "reasoning_content"
    case reasoning
    case toolCalls = "tool_calls"
  }
}

private struct StreamToolCall: Decodable {
  /// Which call this fragment belongs to. A server that sends one call per chunk
  /// may omit it; a single call is index zero either way.
  let index: Int
  let id: String?
  let function: StreamToolFunction?

  init(from decoder: any Decoder) throws {
    let container = try decoder.container(keyedBy: CodingKeys.self)
    index = try container.decodeIfPresent(Int.self, forKey: .index) ?? 0
    id = try container.decodeIfPresent(String.self, forKey: .id)
    function = try container.decodeIfPresent(StreamToolFunction.self, forKey: .function)
  }

  enum CodingKeys: String, CodingKey {
    case index
    case id
    case function
  }
}

private struct StreamToolFunction: Decodable {
  let name: String?
  let arguments: String?
}

private struct APIUsage: Decodable {
  let promptTokens: Int
  let completionTokens: Int
  let totalTokens: Int
  let promptTokensDetails: PromptTokenDetails?

  var normalized: AgentUsage {
    AgentUsage(
      promptTokens: promptTokens,
      completionTokens: completionTokens,
      totalTokens: totalTokens,
      cachedPromptTokens: promptTokensDetails?.cachedTokens
    )
  }

  enum CodingKeys: String, CodingKey {
    case promptTokens = "prompt_tokens"
    case completionTokens = "completion_tokens"
    case totalTokens = "total_tokens"
    case promptTokensDetails = "prompt_tokens_details"
  }
}

private struct PromptTokenDetails: Decodable {
  let cachedTokens: Int?

  enum CodingKeys: String, CodingKey {
    case cachedTokens = "cached_tokens"
  }
}

/// `{"error": {…}}` from the engine and gateway-edge, `{"error": "<text>"}` from
/// llama-swap.
private struct APIErrorEnvelope: Decodable {
  let error: APIError

  init(from decoder: any Decoder) throws {
    let container = try decoder.container(keyedBy: CodingKeys.self)
    if let message = try? container.decode(String.self, forKey: .error) {
      error = APIError(message: message, code: nil)
    } else {
      error = try container.decode(APIError.self, forKey: .error)
    }
  }

  enum CodingKeys: String, CodingKey {
    case error
  }
}

private struct APIError: Decodable {
  let message: String
  /// Text whichever way it was sent: llama.cpp sends `"code": 500`, other
  /// servers a string such as `"queue_full"`. A number used to fail the whole
  /// decode and turn the server's message into "malformed event".
  let code: String?

  init(message: String, code: String?) {
    self.message = message
    self.code = code
  }

  init(from decoder: any Decoder) throws {
    let container = try decoder.container(keyedBy: CodingKeys.self)
    message = try container.decode(String.self, forKey: .message)
    if let number = try? container.decodeIfPresent(Int.self, forKey: .code) {
      code = String(number)
    } else {
      code = try container.decodeIfPresent(String.self, forKey: .code)
    }
  }

  enum CodingKeys: String, CodingKey {
    case message
    case code
  }
}

private struct SSELineBuffer {
  private var bytes = Data()
  private var ignoresNextLineFeed = false

  mutating func consume(byte: UInt8) throws -> String? {
    switch byte {
    case 0x0A:
      if ignoresNextLineFeed {
        ignoresNextLineFeed = false
        return nil
      }
      return try finishLine()

    case 0x0D:
      ignoresNextLineFeed = true
      return try finishLine()

    default:
      ignoresNextLineFeed = false
      bytes.append(byte)
      return nil
    }
  }

  mutating func finish() throws -> String? {
    ignoresNextLineFeed = false
    guard !bytes.isEmpty else { return nil }
    return try finishLine()
  }

  private mutating func finishLine() throws -> String {
    defer { bytes.removeAll(keepingCapacity: true) }
    guard let line = String(data: bytes, encoding: .utf8) else {
      throw ModelClientError.malformedStreamEvent
    }
    return line
  }
}

private struct SSEDataBuffer {
  private var dataLines: [String] = []

  mutating func consume(line: String) -> String? {
    if line.isEmpty {
      return finish()
    }
    if line.hasPrefix(":") {
      return nil
    }

    let parts = line.split(separator: ":", maxSplits: 1, omittingEmptySubsequences: false)
    guard parts.first == "data" else { return nil }

    var value = parts.count == 2 ? String(parts[1]) : ""
    if value.first == " " {
      value.removeFirst()
    }
    dataLines.append(value)
    return nil
  }

  mutating func finish() -> String? {
    guard !dataLines.isEmpty else { return nil }
    defer { dataLines.removeAll(keepingCapacity: true) }
    return dataLines.joined(separator: "\n")
  }
}
