import Foundation
import Synchronization
import Testing

@testable import EvieCore

@Suite("OpenAI-compatible streaming client")
struct OpenAICompatibleClientTests {
  @Test("reassembles fragmented SSE, ignores heartbeats, and completes at DONE")
  func fragmentedStream() async throws {
    let client = makeClient(scenario: .successfulStream)

    let events = try await collect(
      client.stream(messages: [ChatMessage(role: .user, content: "Oi")])
    )

    #expect(events.count == 5)
    #expect(events[0] == .phaseChanged(.thinking))
    #expect(events[1] == .responseTextDelta("Olá"))
    #expect(events[2] == .responseTextDelta(", Evie"))
    #expect(
      events[3]
        == .usage(
          AgentUsage(
            promptTokens: 7,
            completionTokens: 3,
            totalTokens: 10,
            cachedPromptTokens: 2
          )
        )
    )

    guard case .completed(let message, let finishReason) = events[4] else {
      Issue.record("The final event should complete the assistant message.")
      return
    }
    #expect(message.role == .assistant)
    #expect(message.content == "Olá, Evie")
    #expect(finishReason == "stop")
  }

  @Test("heartbeat-only response is reported as an empty stream")
  func heartbeatOnlyStream() async {
    let error = await terminalError(for: makeClient(scenario: .heartbeatOnly))

    #expect(error == .emptyStream)
  }

  @Test("valid chunks without DONE are reported as an unfinished stream")
  func missingDoneMarker() async {
    let error = await terminalError(for: makeClient(scenario: .missingDone))

    #expect(error == .streamEndedBeforeDone)
  }

  @Test("stream error payload preserves its message and code")
  func streamErrorPayload() async {
    let error = await terminalError(for: makeClient(scenario: .serverError))

    #expect(error == .streamFailed(message: "queue is full", code: "queue_full"))
  }

  @Test("malformed data event has a deterministic protocol error")
  func malformedDataEvent() async {
    let error = await terminalError(for: makeClient(scenario: .malformedEvent))

    #expect(error == .malformedStreamEvent)
  }

  @Test("HTTP API error envelope is decoded without losing status")
  func httpErrorEnvelope() async {
    let error = await terminalError(for: makeClient(scenario: .httpError))

    #expect(error == .server(status: 503, message: "model is loading"))
  }

  @Test("chat completions URL appends once and preserves an explicit route")
  func chatCompletionsURL() {
    let base = EvieConfiguration(
      endpoint: URL(string: "http://localhost:18080/v1")!
    )
    let explicit = EvieConfiguration(
      endpoint: URL(string: "http://localhost:18080/v1/chat/completions")!
    )

    #expect(
      base.chatCompletionsURL.absoluteString
        == "http://localhost:18080/v1/chat/completions"
    )
    #expect(explicit.chatCompletionsURL == explicit.endpoint)
  }
}

extension OpenAICompatibleClientTests {
  fileprivate func makeClient(scenario: StubScenario) -> OpenAICompatibleClient {
    ModelClientFactory(
      credentials: StaticCredentialProvider(),
      session: makeSession()
    ).makeClient(
      configuration: EvieConfiguration(
        endpoint: URL(
          string: "http://127.0.0.1:\(scenario.rawValue)/v1"
        )!,
        maxCompletionTokens: 128,
        requestTimeout: 5
      )
    )
  }

  fileprivate func makeSession() -> URLSession {
    let configuration = URLSessionConfiguration.ephemeral
    configuration.protocolClasses = [OpenAICompatibleStubURLProtocol.self]
    return URLSession(configuration: configuration)
  }

  fileprivate func collect(
    _ stream: AsyncThrowingStream<EvieInteractionEvent, any Error>
  ) async throws -> [EvieInteractionEvent] {
    var events: [EvieInteractionEvent] = []
    for try await event in stream {
      events.append(event)
    }
    return events
  }

  fileprivate func terminalError(
    for client: OpenAICompatibleClient
  ) async -> ModelClientError? {
    do {
      _ = try await collect(
        client.stream(messages: [ChatMessage(role: .user, content: "teste")])
      )
      Issue.record("The stream unexpectedly completed successfully.")
      return nil
    } catch let error as ModelClientError {
      return error
    } catch {
      Issue.record("Unexpected error type: \(type(of: error))")
      return nil
    }
  }
}

private enum StubScenario: Int {
  case successfulStream = 18_080
  case heartbeatOnly = 18_081
  case missingDone = 18_082
  case serverError = 18_083
  case malformedEvent = 18_084
  case httpError = 18_085
}

private final class OpenAICompatibleStubURLProtocol: URLProtocol, @unchecked Sendable {
  override class func canInit(with request: URLRequest) -> Bool {
    request.url?.host == "127.0.0.1"
  }

  override class func canonicalRequest(for request: URLRequest) -> URLRequest {
    request
  }

  override func startLoading() {
    guard
      let url = request.url,
      let port = url.port,
      let scenario = StubScenario(rawValue: port)
    else {
      failLoading(code: .badURL)
      return
    }

    switch scenario {
    case .successfulStream:
      guard
        request.httpMethod == "POST",
        url.path == "/v1/chat/completions",
        request.value(forHTTPHeaderField: "Accept") == "text/event-stream",
        request.value(forHTTPHeaderField: "Content-Type") == "application/json"
      else {
        respond(
          status: 422,
          contentType: "text/plain",
          fragments: [Data("unexpected request contract".utf8)]
        )
        return
      }
      respond(
        status: 200,
        fragments: fragmentedBytes(
          """
          : heartbeat

          data: {"choices":[{"delta":{"content":"Olá"},"finish_reason":null}]}

          : still-alive

          data: {"choices":[{"delta":{"content":", Evie"},"finish_reason":"stop"}]}

          data: {"choices":[],"usage":{"prompt_tokens":7,"completion_tokens":3,"total_tokens":10,"prompt_tokens_details":{"cached_tokens":2}}}

          data: [DONE]

          data: {"choices":[{"delta":{"content":"ignored"},"finish_reason":null}]}

          """
          .replacingOccurrences(of: "\n", with: "\r\n")
        )
      )

    case .heartbeatOnly:
      respond(status: 200, fragments: [Data(": heartbeat\n\n".utf8)])

    case .missingDone:
      respond(
        status: 200,
        fragments: [
          Data(
            "data: {\"choices\":[{\"delta\":{\"content\":\"partial\"},\"finish_reason\":null}]}\n\n"
              .utf8
          )
        ]
      )

    case .serverError:
      respond(
        status: 200,
        fragments: [
          Data(
            "data: {\"choices\":[],\"error\":{\"message\":\"queue is full\",\"code\":\"queue_full\"}}\n\n"
              .utf8
          )
        ]
      )

    case .malformedEvent:
      respond(
        status: 200,
        fragments: [Data("data: {definitely-not-json}\n\n".utf8)]
      )

    case .httpError:
      respond(
        status: 503,
        contentType: "application/json",
        fragments: [
          Data(
            "{\"error\":{\"message\":\"model is loading\",\"code\":\"loading\"}}"
              .utf8
          )
        ]
      )
    }
  }

  override func stopLoading() {}

  func respond(
    status: Int,
    contentType: String = "text/event-stream",
    fragments: [Data]
  ) {
    guard
      let url = request.url,
      let response = HTTPURLResponse(
        url: url,
        statusCode: status,
        httpVersion: "HTTP/1.1",
        headerFields: ["Content-Type": contentType]
      )
    else {
      failLoading(code: .badServerResponse)
      return
    }

    client?.urlProtocol(
      self,
      didReceive: response,
      cacheStoragePolicy: .notAllowed
    )
    for fragment in fragments {
      client?.urlProtocol(self, didLoad: fragment)
    }
    client?.urlProtocolDidFinishLoading(self)
  }

  func failLoading(code: URLError.Code) {
    client?.urlProtocol(self, didFailWithError: URLError(code))
  }

  func fragmentedBytes(_ value: String) -> [Data] {
    let data = Data(value.utf8)
    let splitOffsets = [1, 7, 19, 48, 79, 121, 167, 223]
      .filter { $0 < data.count }

    var fragments: [Data] = []
    var start = data.startIndex
    for offset in splitOffsets {
      let end = data.index(data.startIndex, offsetBy: offset)
      fragments.append(data[start..<end])
      start = end
    }
    fragments.append(data[start..<data.endIndex])
    return fragments
  }
}

/// What the client puts on the wire before the model says anything: which host,
/// which scheme, and whether the key goes with it.
///
/// Every request in this suite is answered by `TransportStubURLProtocol`, which
/// claims every URL its session is given — the remote hosts here are never
/// resolved, let alone contacted. Each test owns a random path prefix so the
/// shared request log can be read per test while the suites run in parallel.
@Suite("OpenAI-compatible client transport")
struct OpenAICompatibleClientTransportTests {
  private let stubHost = "stub.evie.test"
  private let token = "test-token-not-a-secret"

  @Test("no Bearer header is sent over http, even to loopback with a bound key")
  func noBearerOverHTTP() async throws {
    let run = UUID().uuidString
    let credential = CredentialReference(
      service: "test",
      account: "loopback",
      boundHost: "127.0.0.1"
    )
    let client = makeClient(
      endpoint: "http://127.0.0.1:18090/\(run)/ok/v1",
      credential: credential,
      tokens: [credential: token]
    )

    _ = try await collect(client.stream(messages: [ChatMessage(role: .user, content: "Oi")]))

    let sent = TransportStubURLProtocol.requests(containing: run)
    #expect(sent.count == 1)
    #expect(sent.first?.authorization == nil)
  }

  @Test("the Mac brain's per-launch key goes over http only to 127.0.0.1 on its own port")
  func localBrainKeyOnlyToItsPort() async throws {
    let keyFile = try LocalBrainKeyTests.temporaryKeyFile()
    let key = LocalBrainKeyFile.makeKey()
    try keyFile.write(key)
    let cases: [(endpoint: String, port: Int?, expected: String?)] = [
      ("http://127.0.0.1:18091", 18_091, "Bearer \(key)"),
      // Another loopback port is another process, whoever it is.
      ("http://127.0.0.1:18092", 18_091, nil),
      ("http://localhost:18091", 18_091, nil),
      ("http://[::1]:18091", 18_091, nil),
      // A loopback server Evie did not start never gets it.
      ("http://127.0.0.1:18091", nil, nil),
    ]

    for (endpoint, port, expected) in cases {
      let run = UUID().uuidString
      let client = makeClient(
        endpoint: "\(endpoint)/\(run)/ok/v1",
        credential: nil,
        tokens: [:],
        localBrainPort: port,
        keyFile: keyFile
      )

      _ = try await collect(client.stream(messages: [ChatMessage(role: .user, content: "Oi")]))

      let sent = TransportStubURLProtocol.requests(containing: run)
      #expect(sent.count == 1, "\(endpoint) \(String(describing: port))")
      #expect(sent.first?.authorization == expected, "\(endpoint) \(String(describing: port))")
    }
  }

  @Test("without a key file the Mac brain is asked without a key, and refuses")
  func localBrainWithoutKeyFile() async throws {
    let run = UUID().uuidString
    let client = makeClient(
      endpoint: "http://127.0.0.1:18093/\(run)/ok/v1",
      credential: nil,
      tokens: [:],
      localBrainPort: 18_093,
      keyFile: try LocalBrainKeyTests.temporaryKeyFile()
    )

    _ = try await collect(client.stream(messages: [ChatMessage(role: .user, content: "Oi")]))

    #expect(TransportStubURLProtocol.requests(containing: run).first?.authorization == nil)
  }

  @Test("a Mac profile's configuration names its port, and no other profile's does")
  func localBrainPortFromTheProfile() {
    let profiles = EvieModelProfileSet.builtIn
    #expect(profiles.profile(id: EvieModelProfile.macProfileID)?.configuration.localBrainPort == 38_480)
    #expect(profiles.profile(id: EvieModelProfile.pcProfileID)?.configuration.localBrainPort == nil)
  }

  @Test("the Bearer header is sent over https to the host the key is bound to")
  func bearerOverHTTPS() async throws {
    let run = UUID().uuidString
    let credential = CredentialReference(
      service: "test",
      account: "stub",
      boundHost: stubHost
    )
    let client = makeClient(
      endpoint: "https://\(stubHost)/\(run)/ok/v1",
      credential: credential,
      tokens: [credential: token]
    )

    _ = try await collect(client.stream(messages: [ChatMessage(role: .user, content: "Oi")]))

    let sent = TransportStubURLProtocol.requests(containing: run)
    #expect(sent.count == 1)
    #expect(sent.first?.authorization == "Bearer \(token)")
  }

  @Test("a redirect is refused and the redirected request is never sent")
  func redirectRefused() async {
    let run = UUID().uuidString
    let credential = CredentialReference(
      service: "test",
      account: "stub",
      boundHost: stubHost
    )
    let client = makeClient(
      endpoint: "https://\(stubHost)/\(run)/redirect/v1",
      credential: credential,
      tokens: [credential: token]
    )

    let error = await terminalError(for: client)

    let sent = TransportStubURLProtocol.requests(containing: run)
    #expect(sent.map(\.host) == [stubHost])
    #expect(!sent.contains { $0.host == TransportStubURLProtocol.redirectTarget })
    guard case .server(let code, _) = error else {
      Issue.record("Expected the 302 itself to be reported, got \(String(describing: error)).")
      return
    }
    #expect(code == 302)
  }

  @Test("an endpoint off the allowlist is refused before any request is sent")
  func unlistedHostRefusedBeforeTransport() async {
    let run = UUID().uuidString
    let credential = CredentialReference(
      service: "test",
      account: "evil",
      boundHost: "evil.example"
    )
    let client = makeClient(
      endpoint: "https://evil.example/\(run)/ok/v1",
      credential: credential,
      tokens: [credential: token]
    )

    let error = await terminalError(for: client)

    guard case .transportRefused = error else {
      Issue.record("Expected a transport refusal, got \(String(describing: error)).")
      return
    }
    #expect(TransportStubURLProtocol.requests(containing: run).isEmpty)
  }

  @Test("a key bound to another host is refused before any request is sent")
  func credentialForAnotherHostRefused() async {
    let run = UUID().uuidString
    let credential = CredentialReference(
      service: "test",
      account: "elsewhere",
      boundHost: "other.evie.test"
    )
    let client = makeClient(
      endpoint: "https://\(stubHost)/\(run)/ok/v1",
      credential: credential,
      tokens: [credential: token]
    )

    let error = await terminalError(for: client)

    guard case .transportRefused = error else {
      Issue.record("Expected a transport refusal, got \(String(describing: error)).")
      return
    }
    #expect(TransportStubURLProtocol.requests(containing: run).isEmpty)
  }

  @Test("a remote host whose key is not saved is not asked anything")
  func missingKeyIsNotSent() async {
    let run = UUID().uuidString
    let credential = CredentialReference(
      service: "test",
      account: "unsaved",
      boundHost: stubHost
    )
    let client = makeClient(
      endpoint: "https://\(stubHost)/\(run)/ok/v1",
      credential: credential,
      tokens: [:]
    )

    let error = await terminalError(for: client)

    guard case .credentialUnavailable = error else {
      Issue.record("Expected a missing-key error, got \(String(describing: error)).")
      return
    }
    #expect(TransportStubURLProtocol.requests(containing: run).isEmpty)
  }
}

extension OpenAICompatibleClientTransportTests {
  fileprivate func makeClient(
    endpoint: String,
    credential: CredentialReference?,
    tokens: [CredentialReference: String],
    localBrainPort: Int? = nil,
    keyFile: LocalBrainKeyFile? = nil
  ) -> OpenAICompatibleClient {
    let configuration = URLSessionConfiguration.ephemeral
    configuration.protocolClasses = [TransportStubURLProtocol.self]
    var client = EvieConfiguration(
      endpoint: URL(string: endpoint)!,
      maxCompletionTokens: 128,
      requestTimeout: 5,
      credential: credential
    )
    client.localBrainPort = localBrainPort
    return ModelClientFactory(
      credentials: StaticCredentialProvider(tokens: tokens),
      transportPolicy: ModelTransportPolicy(allowedRemoteHosts: [stubHost]),
      session: URLSession(configuration: configuration),
      localBrainKey: keyFile ?? LocalBrainKeyFile(
        url: FileManager.default.temporaryDirectory.appendingPathComponent("\(UUID().uuidString).key"))
    ).makeClient(configuration: client)
  }

  fileprivate func collect(
    _ stream: AsyncThrowingStream<EvieInteractionEvent, any Error>
  ) async throws -> [EvieInteractionEvent] {
    var events: [EvieInteractionEvent] = []
    for try await event in stream {
      events.append(event)
    }
    return events
  }

  fileprivate func terminalError(
    for client: OpenAICompatibleClient
  ) async -> ModelClientError? {
    do {
      _ = try await collect(
        client.stream(messages: [ChatMessage(role: .user, content: "teste")])
      )
      Issue.record("The stream unexpectedly completed successfully.")
      return nil
    } catch let error as ModelClientError {
      return error
    } catch {
      Issue.record("Unexpected error type: \(type(of: error)): \(error)")
      return nil
    }
  }
}

/// Answers every request by the scenario named in its path and remembers what
/// it was sent.
///
/// `/ok/` streams a one-word answer. `/redirect/` answers 302 to a different
/// host, which the client must refuse to follow; if it followed, this stub
/// would see — and record — the second request.
private final class TransportStubURLProtocol: URLProtocol, @unchecked Sendable {
  struct Sent: Sendable {
    let host: String?
    let path: String
    let authorization: String?
  }

  static let redirectTarget = "redirected.evie.test"
  private static let log = Mutex<[Sent]>([])

  static func requests(containing marker: String) -> [Sent] {
    log.withLock { $0.filter { $0.path.contains(marker) } }
  }

  override class func canInit(with request: URLRequest) -> Bool {
    true
  }

  override class func canonicalRequest(for request: URLRequest) -> URLRequest {
    request
  }

  override func startLoading() {
    guard let url = request.url else {
      client?.urlProtocol(self, didFailWithError: URLError(.badURL))
      return
    }
    let sent = Sent(
      host: url.host,
      path: url.path,
      authorization: request.value(forHTTPHeaderField: "Authorization")
    )
    Self.log.withLock { $0.append(sent) }

    if url.path.contains("/redirect/") {
      var target = URLComponents(url: url, resolvingAgainstBaseURL: false)!
      target.host = Self.redirectTarget
      let response = HTTPURLResponse(
        url: url,
        statusCode: 302,
        httpVersion: "HTTP/1.1",
        headerFields: ["Location": target.url!.absoluteString]
      )!
      client?.urlProtocol(
        self,
        wasRedirectedTo: URLRequest(url: target.url!),
        redirectResponse: response
      )
      client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
      client?.urlProtocolDidFinishLoading(self)
      return
    }

    let response = HTTPURLResponse(
      url: url,
      statusCode: 200,
      httpVersion: "HTTP/1.1",
      headerFields: ["Content-Type": "text/event-stream"]
    )!
    client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
    client?.urlProtocol(
      self,
      didLoad: Data(
        """
        data: {"choices":[{"delta":{"content":"Oi"},"finish_reason":"stop"}]}

        data: [DONE]


        """.utf8
      )
    )
    client?.urlProtocolDidFinishLoading(self)
  }

  override func stopLoading() {}
}
