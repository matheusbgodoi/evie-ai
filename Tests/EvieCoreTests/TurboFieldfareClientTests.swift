import Foundation
import Testing

@testable import EvieCore

@Suite("TurboFieldfare streaming client")
struct TurboFieldfareClientTests {
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

    #expect(error == .server(message: "queue is full", code: "queue_full"))
  }

  @Test("malformed data event has a deterministic protocol error")
  func malformedDataEvent() async {
    let error = await terminalError(for: makeClient(scenario: .malformedEvent))

    #expect(error == .malformedStreamEvent)
  }

  @Test("HTTP API error envelope is decoded without losing status")
  func httpErrorEnvelope() async {
    let error = await terminalError(for: makeClient(scenario: .httpError))

    #expect(error == .httpStatus(code: 503, message: "model is loading"))
  }

  @Test("non-loopback inference endpoint is rejected before transport")
  func rejectsRemoteEndpoint() async {
    let configuration = EvieConfiguration(
      endpoint: URL(string: "https://example.com/v1")!
    )
    let client = TurboFieldfareClient(
      configuration: configuration,
      session: makeSession()
    )

    let error = await terminalError(for: client)

    guard case .invalidConfiguration(let message) = error else {
      Issue.record("Expected a loopback configuration error.")
      return
    }
    #expect(message.contains("loopback"))
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

extension TurboFieldfareClientTests {
  fileprivate func makeClient(scenario: StubScenario) -> TurboFieldfareClient {
    TurboFieldfareClient(
      configuration: EvieConfiguration(
        endpoint: URL(
          string: "http://127.0.0.1:\(scenario.rawValue)/v1"
        )!,
        maxCompletionTokens: 128,
        requestTimeout: 5
      ),
      session: makeSession()
    )
  }

  fileprivate func makeSession() -> URLSession {
    let configuration = URLSessionConfiguration.ephemeral
    configuration.protocolClasses = [TurboFieldfareStubURLProtocol.self]
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
    for client: TurboFieldfareClient
  ) async -> TurboFieldfareClientError? {
    do {
      _ = try await collect(
        client.stream(messages: [ChatMessage(role: .user, content: "teste")])
      )
      Issue.record("The stream unexpectedly completed successfully.")
      return nil
    } catch let error as TurboFieldfareClientError {
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

private final class TurboFieldfareStubURLProtocol: URLProtocol, @unchecked Sendable {
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
