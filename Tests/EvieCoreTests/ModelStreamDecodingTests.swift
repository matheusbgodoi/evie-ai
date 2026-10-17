import Foundation
import Synchronization
import Testing

@testable import EvieCore

/// How a streamed turn is read back: reasoning kept apart from the answer,
/// truncation recognised, gateway errors named, and the deadlines enforced.
///
/// Every request goes to `stub.evie.test` and is answered by
/// `ModelStreamStubURLProtocol`, which picks its scenario from the path. Nothing
/// is resolved or contacted. Each test owns a random path prefix so the shared
/// request log can be read per test while suites run in parallel.
@Suite("Model stream decoding")
struct ModelStreamDecodingTests {
  @Test("reasoning_content goes only to reasoningDelta, never to the answer")
  func reasoningContentIsKeptApart() async throws {
    let events = try await collect(makeClient(.thinkingLow))

    #expect(reasoning(in: events) == GatewayStreamFixtures.thinkingLowReasoning)
    #expect(answer(in: events) == GatewayStreamFixtures.thinkingLowAnswer)
    let message = try #require(completed(in: events)?.message)
    #expect(message.content == GatewayStreamFixtures.thinkingLowAnswer)
    #expect(!message.content.contains("user"))
  }

  @Test("the reasoning alias is read the same way")
  func reasoningAlias() async throws {
    let events = try await collect(makeClient(.reasoningAlias))

    #expect(reasoning(in: events) == "pensando")
    #expect(answer(in: events) == "Pronto.")
  }

  @Test("a recorded tool call is reassembled with its identifier and arguments")
  func recordedToolCall() async throws {
    let events = try await collect(makeClient(.toolCall))

    let (message, finishReason) = try #require(completed(in: events))
    let call = try #require(message.toolCalls?.first)
    #expect(call.id == GatewayStreamFixtures.toolCallID)
    #expect(call.name == "calculate")
    #expect(call.argumentsJSON == GatewayStreamFixtures.toolCallArguments)
    #expect(finishReason == "tool_calls")
    #expect(reasoning(in: events).isEmpty)
  }

  @Test("inline think tags split across chunks are stripped from the answer")
  func inlineThinkTags() async throws {
    let events = try await collect(makeClient(.inlineThink))

    #expect(reasoning(in: events) == "pensando mais")
    #expect(answer(in: events) == "Resposta final.")
    #expect(completed(in: events)?.message.content == "Resposta final.")
  }

  @Test("an answer that quotes the think tag is shown whole, not hidden as reasoning")
  func quotedThinkTag() async throws {
    let events = try await collect(makeClient(.quotedThinkTag))

    #expect(reasoning(in: events).isEmpty)
    #expect(answer(in: events) == ModelStreamStub.quotedThinkTagAnswer)
    #expect(completed(in: events)?.message.content == ModelStreamStub.quotedThinkTagAnswer)
  }

  @Test("after separate reasoning, an answer that opens with the think tag is still the answer")
  func separateReasoningThenTag() async throws {
    let events = try await collect(makeClient(.reasoningThenTagAnswer))

    #expect(reasoning(in: events) == "pensando")
    #expect(answer(in: events) == "<think> abre o raciocínio do Qwen.")
  }

  @Test("reasoning that used the whole cap with no answer is reported as truncated")
  func truncatedReasoning() async {
    let error = await terminalError(makeClient(.reasoningUsedTheCap), maxTokens: 64)

    #expect(error == .truncated(completionTokens: 64))
  }

  @Test("reasoning that stopped with no answer is an empty stream")
  func reasoningWithoutAnswer() async {
    let error = await terminalError(makeClient(.reasoningThenStop), maxTokens: 64)

    #expect(error == .emptyStream)
  }

  @Test("an answer that reached the cap counts as length even when the server said stop")
  func capReachedCountsAsLength() async throws {
    let events = try await collect(makeClient(.answerUsedTheCap), maxTokens: 64)

    let (message, finishReason) = try #require(completed(in: events))
    #expect(message.content == "Parcial")
    #expect(finishReason == "length")
  }

  @Test("an Int error code mid-stream decodes with its message")
  func integerErrorCode() async {
    let error = await terminalError(makeClient(.integerErrorCode))

    #expect(error == .streamFailed(message: "engine crashed", code: "500"))
  }

  @Test("401 is unauthorized, invalidates the cached key, and is not retried")
  func unauthorizedInvalidatesTheKey() async {
    let credentials = RecordingCredentials(token: "test-token-not-a-secret")
    let client = makeClient(.unauthorized, credentials: credentials)

    let error = await terminalError(client)

    #expect(error == .unauthorized)
    #expect(await credentials.invalidated == [ModelStreamStub.credential])
    #expect(ModelStreamStubURLProtocol.requests(containing: client.run).count == 1)
  }

  @Test("404 no router is modelNotFound naming the model")
  func noRouterIsModelNotFound() async {
    let error = await terminalError(makeClient(.noRouter))

    #expect(error == .modelNotFound("qwen-daily"))
  }

  @Test("413 is requestTooLarge")
  func payloadTooLarge() async {
    let error = await terminalError(makeClient(.payloadTooLarge))

    #expect(error == .requestTooLarge)
  }

  @Test("502 means the gateway is unreachable")
  func badGateway() async {
    let error = await terminalError(makeClient(.badGateway))

    #expect(error == .unreachable("gateway"))
  }

  @Test("another status keeps its code and the server's message")
  func otherStatus() async {
    let error = await terminalError(makeClient(.serviceUnavailable))

    #expect(error == .server(status: 503, message: "model is loading"))
  }

  @Test("the headers deadline fires when the model is ready")
  func headersDeadlineWhenReady() async {
    let error = await terminalError(makeClient(.slowHeaders), readiness: .ready)

    #expect(error == .headersTimedOut)
  }

  @Test("the headers deadline does not fire while the model is loading")
  func headersDeadlineWhenCold() async throws {
    let events = try await collect(makeClient(.slowHeaders), readiness: .modelCold)

    #expect(completed(in: events)?.message.content == "Oi")
  }

  @Test("the first-token deadline fires after the headers arrived")
  func firstTokenDeadline() async {
    let error = await terminalError(makeClient(.slowFirstToken), readiness: .ready)

    #expect(error == .firstTokenTimedOut)
  }

  @Test(
    "large inputs reserve prefill time in the actual streamed request and watchdog",
    arguments: [false, true])
  func largeInputStreamAllowsPrefill(waitAfterHeaders: Bool) async throws {
    let stub = makeClient(waitAfterHeaders ? .slowFirstToken : .slowHeaders)
    let question = ChatMessage(role: .user, content: String(repeating: "x", count: 40_000))
    var events: [EvieInteractionEvent] = []
    for try await event in stub.client.stream(
      messages: [question], tools: [], options: TurnOptions(reasoning: .off, readiness: .ready))
    {
      events.append(event)
    }
    #expect(completed(in: events)?.message.content == "Oi")
  }

  /// The causal facts, not a wall-clock bound: the consumer's end comes before
  /// the server has answered at all, and the request reaches the server's
  /// side as a cancellation. Timing it against the stub's pause failed about
  /// one run in seven under the parallel full suite (0.876 s and 1.37 s were
  /// seen against a 1 s bound), with the client behaving correctly.
  @Test(
    "cancelling the consumer ends the turn without waiting for the server",
    .timeLimit(.minutes(1))
  )
  func cancellation() async throws {
    let client = makeClient(.heldHeaders)
    let task = Task {
      try await collect(client, readiness: .modelCold)
    }
    // Cancelled once the request is at the server, so what is tested is a
    // request in flight rather than one that was never sent.
    while ModelStreamStubURLProtocol.requests(containing: client.run).isEmpty {
      try await Task.sleep(for: .milliseconds(10))
    }
    task.cancel()

    // A cancelled consumer either sees the stream end or a CancellationError;
    // what it must not do is wait for the answer the stub holds back, or
    // receive it.
    let events = (try? await task.value) ?? []
    #expect(!ModelStreamStubURLProtocol.hasAnswered(containing: client.run))
    #expect(completed(in: events) == nil)
    // The request itself was cancelled, not left running behind the consumer.
    while !ModelStreamStubURLProtocol.wasStopped(containing: client.run) {
      try await Task.sleep(for: .milliseconds(10))
    }
    #expect(!ModelStreamStubURLProtocol.hasAnswered(containing: client.run))
  }
}

@Suite("Model deadline policy")
struct ModelDeadlinePolicyTests {
  private let configuration = EvieConfiguration(requestTimeout: 300)

  @Test("a ready model waits for headers as long as for a first token")
  func readyDeadlines() {
    let text = ModelDeadlinePolicy.standard.deadlines(
      readiness: .ready,
      carriesImage: false,
      configuration: configuration
    )
    let image = ModelDeadlinePolicy.standard.deadlines(
      readiness: .ready,
      carriesImage: true,
      configuration: configuration
    )

    #expect(
      text == ModelTurnDeadlines(idleGap: 120, headers: .seconds(60), firstToken: .seconds(60)))
    #expect(
      image == ModelTurnDeadlines(idleGap: 120, headers: .seconds(120), firstToken: .seconds(120))
    )
  }

  @Test("a cold model gets ten minutes to load")
  func coldDeadlines() {
    let cold = ModelDeadlinePolicy.standard.deadlines(
      readiness: .modelCold,
      carriesImage: false,
      configuration: configuration
    )

    #expect(
      cold == ModelTurnDeadlines(idleGap: 600, headers: .seconds(600), firstToken: .seconds(60)))
  }

  @Test("an unprobed model keeps the configured request timeout everywhere")
  func unprobedDeadlines() {
    let unknown = ModelDeadlinePolicy.standard.deadlines(
      readiness: nil,
      carriesImage: true,
      configuration: configuration
    )

    #expect(
      unknown == ModelTurnDeadlines(idleGap: 300, headers: .seconds(300), firstToken: .seconds(300))
    )
  }

  @Test("the model session allows a fifteen-minute turn")
  func sessionResourceTimeout() {
    #expect(URLSessionConfiguration.evieModel.timeoutIntervalForResource == 900)
  }
}

@Suite("Inline thinking splitter")
struct InlineThinkingSplitterTests {
  private let stream = "<think>passo 1\npasso 2</think>\n\nA resposta é 4."

  @Test("a stream cut at every offset splits the same way")
  func everyOffset() {
    for offset in 0...stream.count {
      let cut = stream.index(stream.startIndex, offsetBy: offset)
      var splitter = InlineThinkingSplitter()
      let pieces =
        splitter.consume(String(stream[..<cut]))
        + splitter.consume(String(stream[cut...]))
        + splitter.finish()

      #expect(text(of: pieces, reasoning: true) == "passo 1\npasso 2", "cut at \(offset)")
      #expect(text(of: pieces, reasoning: false) == "A resposta é 4.", "cut at \(offset)")
    }
  }

  @Test("text with no tag passes through untouched, a lone < included")
  func noTag() {
    var splitter = InlineThinkingSplitter()
    let pieces = splitter.consume("2 < 3 e ") + splitter.consume("<b") + splitter.finish()

    #expect(pieces.allSatisfy { if case .answer = $0 { true } else { false } })
    #expect(text(of: pieces, reasoning: false) == "2 < 3 e <b")
  }

  @Test("a tag quoted inside the answer stays answer text at every cut")
  func quotedTag() {
    let quoted = "O Qwen usa a tag <think> para raciocinar, e fecha com </think>."
    for offset in 0...quoted.count {
      let cut = quoted.index(quoted.startIndex, offsetBy: offset)
      var splitter = InlineThinkingSplitter()
      let pieces =
        splitter.consume(String(quoted[..<cut]))
        + splitter.consume(String(quoted[cut...]))
        + splitter.finish()

      #expect(text(of: pieces, reasoning: true).isEmpty, "cut at \(offset)")
      #expect(text(of: pieces, reasoning: false) == quoted, "cut at \(offset)")
    }
  }

  @Test("only a trace that opens the answer is reasoning; a later tag is text")
  func onlyTheOpeningTrace() {
    var splitter = InlineThinkingSplitter()
    let pieces =
      splitter.consume("\n<think>passo</think>\n\nA tag <think> abre")
      + splitter.consume(" um raciocínio.")
      + splitter.finish()

    #expect(text(of: pieces, reasoning: true) == "passo")
    #expect(text(of: pieces, reasoning: false) == "A tag <think> abre um raciocínio.")
  }

  @Test("once the server sends reasoning apart, an opening tag is answer text")
  func separateReasoningDisablesSplitting() {
    var splitter = InlineThinkingSplitter()
    splitter.noteSeparateReasoning()
    let pieces = splitter.consume("<think> é a tag.") + splitter.finish()

    #expect(text(of: pieces, reasoning: true).isEmpty)
    #expect(text(of: pieces, reasoning: false) == "<think> é a tag.")
  }

  @Test("whitespace alone, or a partial tag at the end, is answer text")
  func undecidedTailIsAnswer() {
    var whitespace = InlineThinkingSplitter()
    let blank = whitespace.consume("\n") + whitespace.finish()
    #expect(text(of: blank, reasoning: false) == "\n")

    var partial = InlineThinkingSplitter()
    let cut = partial.consume("<thi") + partial.finish()
    #expect(text(of: cut, reasoning: false) == "<thi")
    #expect(text(of: cut, reasoning: true).isEmpty)
  }

  @Test("an unclosed think block is all reasoning")
  func unclosed() {
    var splitter = InlineThinkingSplitter()
    let pieces = splitter.consume("<think>ainda pensando</th") + splitter.finish()

    #expect(text(of: pieces, reasoning: true) == "ainda pensando</th")
    #expect(text(of: pieces, reasoning: false).isEmpty)
  }

  private func text(of pieces: [InlineThinkingSplitter.Piece], reasoning: Bool) -> String {
    pieces.map { piece in
      switch piece {
      case .reasoning(let text): reasoning ? text : ""
      case .answer(let text): reasoning ? "" : text
      }
    }.joined()
  }
}

// MARK: - Helpers

extension ModelStreamDecodingTests {
  fileprivate struct StubClient {
    let client: OpenAICompatibleClient
    let run: String
  }

  fileprivate func makeClient(
    _ scenario: ModelStreamStub.Scenario,
    credentials: (any EvieCredentialProviding)? = nil
  ) -> StubClient {
    let run = UUID().uuidString
    let session = URLSessionConfiguration.ephemeral
    session.protocolClasses = [ModelStreamStubURLProtocol.self]
    let client = ModelClientFactory(
      credentials: credentials
        ?? StaticCredentialProvider(tokens: [ModelStreamStub.credential: "test-token-not-a-secret"]),
      transportPolicy: ModelTransportPolicy(allowedRemoteHosts: [ModelStreamStub.host]),
      session: URLSession(configuration: session),
      deadlines: ModelDeadlinePolicy(
        idleGap: 120,
        coldIdleGap: 600,
        textResponse: .milliseconds(300),
        imageResponse: .milliseconds(300),
        coldHeaders: .seconds(10)
      )
    ).makeClient(
      configuration: EvieConfiguration(
        endpoint: URL(string: "https://\(ModelStreamStub.host)/\(run)/\(scenario.rawValue)/v1")!,
        model: "qwen-daily",
        contextWindowTokens: 135_168,
        maxCompletionTokens: 16_384,
        requestTimeout: 5,
        credential: ModelStreamStub.credential,
        thinkingStyle: .templateKwargs
      )
    )
    return StubClient(client: client, run: run)
  }

  fileprivate func collect(
    _ stub: StubClient,
    maxTokens: Int? = nil,
    readiness: ReadinessRung? = nil
  ) async throws -> [EvieInteractionEvent] {
    let options = TurnOptions(reasoning: .off, maxTokens: maxTokens, readiness: readiness)
    var events: [EvieInteractionEvent] = []
    for try await event in stub.client.stream(
      messages: [ChatMessage(role: .user, content: "Oi")],
      tools: [],
      options: options
    ) {
      events.append(event)
    }
    return events
  }

  fileprivate func terminalError(
    _ stub: StubClient,
    maxTokens: Int? = nil,
    readiness: ReadinessRung? = nil
  ) async -> ModelClientError? {
    do {
      _ = try await collect(stub, maxTokens: maxTokens, readiness: readiness)
      Issue.record("The stream unexpectedly completed successfully.")
      return nil
    } catch let error as ModelClientError {
      return error
    } catch {
      Issue.record("Unexpected error type: \(type(of: error)): \(error)")
      return nil
    }
  }

  fileprivate func reasoning(in events: [EvieInteractionEvent]) -> String {
    events.compactMap { if case .reasoningDelta(let text) = $0 { text } else { nil } }.joined()
  }

  fileprivate func answer(in events: [EvieInteractionEvent]) -> String {
    events.compactMap { if case .responseTextDelta(let text) = $0 { text } else { nil } }.joined()
  }

  fileprivate func completed(
    in events: [EvieInteractionEvent]
  ) -> (message: ChatMessage, finishReason: String?)? {
    for event in events {
      if case .completed(let message, let finishReason) = event {
        return (message, finishReason)
      }
    }
    return nil
  }
}

/// A key store that remembers what it was told to forget.
private actor RecordingCredentials: EvieCredentialProviding {
  let token: String
  private(set) var invalidated: [CredentialReference] = []

  init(token: String) {
    self.token = token
  }

  func bearerToken(for reference: CredentialReference) -> String? {
    token
  }

  func invalidate(_ reference: CredentialReference) {
    invalidated.append(reference)
  }
}

private enum ModelStreamStub {
  static let host = "stub.evie.test"
  static let credential = CredentialReference(service: "test", account: "stub", boundHost: host)

  enum Scenario: String {
    case thinkingLow = "thinking-low"
    case reasoningAlias = "reasoning-alias"
    case toolCall = "tool-call"
    case inlineThink = "inline-think"
    case reasoningUsedTheCap = "reasoning-used-the-cap"
    case reasoningThenStop = "reasoning-then-stop"
    case answerUsedTheCap = "answer-used-the-cap"
    case integerErrorCode = "integer-error-code"
    case unauthorized
    case noRouter = "no-router"
    case payloadTooLarge = "payload-too-large"
    case badGateway = "bad-gateway"
    case serviceUnavailable = "service-unavailable"
    case slowHeaders = "slow-headers"
    case slowFirstToken = "slow-first-token"
    /// Says nothing until the client stops listening, or for 30 s.
    case heldHeaders = "held-headers"
    case quotedThinkTag = "quoted-think-tag"
    case reasoningThenTagAnswer = "reasoning-then-tag-answer"
  }

  /// The PC's shape with thinking off: the answer alone in `delta.content`. It
  /// talks about the tag and never closes it, so a splitter that matched the tag
  /// anywhere would hide everything after it and end the turn empty.
  static let quotedThinkTagAnswer = "O Qwen marca o raciocínio com a tag <think> no começo."

  static func chunk(_ delta: String, finish: String? = nil) -> String {
    let reason = finish.map { "\"\($0)\"" } ?? "null"
    return #"{"choices":[{"index":0,"delta":\#(delta),"finish_reason":\#(reason)}]}"#
  }

  static func usage(completion: Int) -> String {
    #"{"choices":[],"usage":{"prompt_tokens":5,"completion_tokens":\#(completion),"total_tokens":\#(completion + 5)}}"#
  }

  static let shortAnswer = GatewayStreamFixtures.sse([
    chunk(#"{"content":"Oi"}"#, finish: "stop"), "[DONE]",
  ])
}

/// Answers by the scenario named in the path and keeps a log of what it was
/// sent. The slow scenarios answer from a background queue after a pause, and
/// say nothing at all once the client has stopped listening. Which requests a
/// slow scenario answered, and which the client stopped, are logged too.
private final class ModelStreamStubURLProtocol: URLProtocol, @unchecked Sendable {
  private static let log = Mutex<[String]>([])
  private static let answeredLog = Mutex<[String]>([])
  private static let stoppedLog = Mutex<[String]>([])
  private let stopped = Mutex(false)

  static func requests(containing marker: String) -> [String] {
    log.withLock { $0.filter { $0.contains(marker) } }
  }

  /// Whether a slow scenario sent anything for a request under `marker`.
  static func hasAnswered(containing marker: String) -> Bool {
    answeredLog.withLock { $0.contains { $0.contains(marker) } }
  }

  /// Whether the client stopped a request under `marker`.
  static func wasStopped(containing marker: String) -> Bool {
    stoppedLog.withLock { $0.contains { $0.contains(marker) } }
  }

  override class func canInit(with request: URLRequest) -> Bool {
    request.url?.host == ModelStreamStub.host
  }

  override class func canonicalRequest(for request: URLRequest) -> URLRequest {
    request
  }

  override func startLoading() {
    guard
      let url = request.url,
      let scenario = url.pathComponents.lazy.compactMap(ModelStreamStub.Scenario.init).first
    else {
      client?.urlProtocol(self, didFailWithError: URLError(.badURL))
      return
    }
    Self.log.withLock { $0.append(url.path) }

    typealias Stub = ModelStreamStub
    switch scenario {
    case .thinkingLow:
      respond(200, GatewayStreamFixtures.thinkingLow)
    case .reasoningAlias:
      respond(
        200,
        GatewayStreamFixtures.sse([
          Stub.chunk(#"{"reasoning":"pensando"}"#),
          Stub.chunk(#"{"content":"Pronto."}"#, finish: "stop"),
          "[DONE]",
        ])
      )
    case .toolCall:
      respond(200, GatewayStreamFixtures.toolCallThinkingOff)
    case .inlineThink:
      respond(
        200,
        GatewayStreamFixtures.sse([
          Stub.chunk(#"{"content":"<thi"}"#),
          Stub.chunk(#"{"content":"nk>pensando"}"#),
          Stub.chunk(#"{"content":" mais</th"}"#),
          Stub.chunk(#"{"content":"ink>\n\nResposta"}"#),
          Stub.chunk(#"{"content":" final."}"#, finish: "stop"),
          "[DONE]",
        ])
      )
    case .quotedThinkTag:
      respond(
        200,
        GatewayStreamFixtures.sse([
          Stub.chunk(#"{"role":"assistant","content":""}"#),
          Stub.chunk(#"{"content":"O Qwen marca o raciocínio com a tag <th"}"#),
          Stub.chunk(#"{"content":"ink> no começo."}"#, finish: "stop"),
          "[DONE]",
        ])
      )
    case .reasoningThenTagAnswer:
      respond(
        200,
        GatewayStreamFixtures.sse([
          Stub.chunk(#"{"reasoning_content":"pensando"}"#),
          Stub.chunk(#"{"content":"<think> abre"}"#),
          Stub.chunk(#"{"content":" o raciocínio do Qwen."}"#, finish: "stop"),
          "[DONE]",
        ])
      )
    case .reasoningUsedTheCap:
      // The engine says "stop" when it was cut at the limit; the usage is the
      // only honest witness.
      respond(
        200,
        GatewayStreamFixtures.sse([
          Stub.chunk(#"{"reasoning_content":"pensando sem parar"}"#),
          Stub.chunk("{}", finish: "stop"),
          Stub.usage(completion: 64),
          "[DONE]",
        ])
      )
    case .reasoningThenStop:
      respond(
        200,
        GatewayStreamFixtures.sse([
          Stub.chunk(#"{"reasoning_content":"pensei"}"#),
          Stub.chunk("{}", finish: "stop"),
          Stub.usage(completion: 10),
          "[DONE]",
        ])
      )
    case .answerUsedTheCap:
      respond(
        200,
        GatewayStreamFixtures.sse([
          Stub.chunk(#"{"content":"Parcial"}"#, finish: "stop"),
          Stub.usage(completion: 64),
          "[DONE]",
        ])
      )
    case .integerErrorCode:
      respond(
        200,
        GatewayStreamFixtures.sse([
          #"{"choices":[],"error":{"code":500,"message":"engine crashed","type":"server_error"}}"#
        ])
      )
    case .unauthorized:
      respond(401, #"{"error":"unauthorized: invalid or missing API key","src":"llama-swap"}"#)
    case .noRouter:
      respond(404, #"{"error":"no router for requested model","src":"llama-swap"}"#)
    case .payloadTooLarge:
      respond(
        413,
        #"{"type":"error","error":{"type":"request_too_large","message":"body exceeds 64 MB"}}"#
      )
    case .badGateway:
      respond(
        502,
        #"{"type":"error","error":{"type":"api_error","message":"gateway-edge: upstream refused"}}"#
      )
    case .serviceUnavailable:
      respond(503, #"{"error":{"message":"model is loading","code":"loading"}}"#)
    case .slowHeaders:
      later(seconds: 1.5) { $0.respond(200, Stub.shortAnswer) }
    case .slowFirstToken:
      sendHeaders(200)
      later(seconds: 1.5) {
        $0.client?.urlProtocol($0, didLoad: Data(Stub.shortAnswer.utf8))
        $0.client?.urlProtocolDidFinishLoading($0)
      }
    case .heldHeaders:
      later(seconds: 30) { $0.respond(200, Stub.shortAnswer) }
    }
  }

  override func stopLoading() {
    stopped.withLock { $0 = true }
    if let path = request.url?.path {
      Self.stoppedLog.withLock { $0.append(path) }
    }
  }

  private func later(
    seconds: Double, _ work: @escaping @Sendable (ModelStreamStubURLProtocol) -> Void
  ) {
    DispatchQueue.global().asyncAfter(deadline: .now() + seconds) { [self] in
      // Checked and logged under one lock, so an answer is either logged
      // before a stop is seen or never sent.
      let answering = stopped.withLock { stopped in
        guard !stopped else { return false }
        if let path = request.url?.path {
          Self.answeredLog.withLock { $0.append(path) }
        }
        return true
      }
      guard answering else { return }
      work(self)
    }
  }

  private func sendHeaders(_ status: Int) {
    let response = HTTPURLResponse(
      url: request.url!,
      statusCode: status,
      httpVersion: "HTTP/1.1",
      headerFields: ["Content-Type": status == 200 ? "text/event-stream" : "application/json"]
    )!
    client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
  }

  private func respond(_ status: Int, _ body: String) {
    sendHeaders(status)
    client?.urlProtocol(self, didLoad: Data(body.utf8))
    client?.urlProtocolDidFinishLoading(self)
  }
}
