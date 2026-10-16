import Foundation

/// Errors raised by the OpenAI-compatible Chat Completions adapter.
public enum OpenAICompatibleClientError: Error, Equatable, Sendable {
  case invalidConfiguration(String)
  /// `ModelTransportPolicy` refused the endpoint; nothing was sent.
  case transportRefused(String)
  /// The endpoint needs a key and none could be read; nothing was sent.
  case credentialUnavailable(String)
  case requestEncoding(String)
  case invalidHTTPResponse
  case httpStatus(code: Int, message: String?)
  case server(message: String, code: String?)
  case malformedStreamEvent
  case emptyStream
  case streamEndedBeforeDone
  case transport(String)
}

extension OpenAICompatibleClientError: LocalizedError {
  public var errorDescription: String? {
    switch self {
    case .invalidConfiguration(let message):
      "Invalid Evie configuration: \(message)"
    case .transportRefused(let message):
      "Evie refused to send the conversation: \(message)"
    case .credentialUnavailable(let message):
      "The model key is unavailable: \(message)"
    case .requestEncoding(let message):
      "Could not encode the chat request: \(message)"
    case .invalidHTTPResponse:
      "The model server returned a non-HTTP response."
    case .httpStatus(let code, let message):
      if let message, !message.isEmpty {
        "The model server returned HTTP \(code): \(message)"
      } else {
        "The model server returned HTTP \(code)."
      }
    case .server(let message, let code):
      if let code, !code.isEmpty {
        "Model server error \(code): \(message)"
      } else {
        "Model server error: \(message)"
      }
    case .malformedStreamEvent:
      "The model server sent a malformed streaming event."
    case .emptyStream:
      "The model server closed the stream without sending a response."
    case .streamEndedBeforeDone:
      "The model server closed the stream before the [DONE] marker."
    case .transport(let message):
      "Could not communicate with the model server: \(message)"
    }
  }
}

/// A dependency-free client for any OpenAI-compatible streaming Chat Completions
/// server: the PC gateway over the tailnet, or a server on this Mac's loopback.
///
/// Before a byte leaves the Mac the endpoint must pass `ModelTransportPolicy`,
/// and the key goes only over https to the host it was saved for. Redirects are
/// refused outright, so the `Authorization` header cannot follow one anywhere.
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

  /// Internal on purpose: outside EvieCore the only way to get a client is
  /// `ModelClientFactory`, so no caller can pick its own policy or key source.
  init(
    configuration: EvieConfiguration,
    credentials: any EvieCredentialProviding,
    transportPolicy: ModelTransportPolicy,
    session: URLSession
  ) {
    self.configuration = configuration
    self.credentials = credentials
    self.transportPolicy = transportPolicy
    self.session = session
  }

  public func stream(
    messages: [ChatMessage]
  ) -> AsyncThrowingStream<EvieInteractionEvent, any Error> {
    stream(messages: messages, tools: [])
  }

  /// The same turn, with a set of functions the model may ask for.
  ///
  /// Streaming is kept for tool turns rather than falling back to a plain
  /// request: the running server was measured emitting a complete, well-formed
  /// tool call inside a normal SSE delta, so there is no reason to maintain two
  /// request paths, and ordinary text still arrives token by token.
  public func stream(
    messages: [ChatMessage],
    tools: [EvieToolDefinition]
  ) -> AsyncThrowingStream<EvieInteractionEvent, any Error> {
    let configuration = configuration
    let credentials = credentials
    let transportPolicy = transportPolicy
    let session = session

    return AsyncThrowingStream { continuation in
      let requestTask = Task {
        do {
          try Task.checkCancellation()
          try configuration.validate()
          let url = configuration.chatCompletionsURL
          if case .refused(let reason) = transportPolicy.evaluate(
            url,
            credentialHost: configuration.credential?.boundHost
          ) {
            throw OpenAICompatibleClientError.transportRefused(reason)
          }
          let bearerToken = try await Self.bearerToken(
            for: url,
            credential: configuration.credential,
            from: credentials
          )

          var request = try Self.makeRequest(
            messages: messages,
            tools: tools,
            configuration: configuration
          )
          if let bearerToken {
            request.setValue("Bearer \(bearerToken)", forHTTPHeaderField: "Authorization")
          }
          continuation.yield(.phaseChanged(.thinking))

          let (bytes, response) = try await session.bytes(
            for: request,
            delegate: RedirectRefusal()
          )
          try Task.checkCancellation()

          guard let httpResponse = response as? HTTPURLResponse else {
            throw OpenAICompatibleClientError.invalidHTTPResponse
          }

          guard (200...299).contains(httpResponse.statusCode) else {
            let errorBody = try await Self.readErrorBody(from: bytes)
            let apiError = errorBody.flatMap(Self.decodeAPIError(from:))
            throw OpenAICompatibleClientError.httpStatus(
              code: httpResponse.statusCode,
              message: apiError?.message ?? errorBody
            )
          }

          try await Self.consumeStream(
            bytes,
            continuation: continuation
          )
        } catch is CancellationError {
          continuation.finish(throwing: CancellationError())
        } catch let error as EvieConfiguration.ValidationError {
          continuation.finish(
            throwing: OpenAICompatibleClientError.invalidConfiguration(
              error.localizedDescription
            )
          )
        } catch let error as OpenAICompatibleClientError {
          continuation.finish(throwing: error)
        } catch let error as URLError where error.code == .cancelled {
          continuation.finish(throwing: CancellationError())
        } catch {
          continuation.finish(
            throwing: OpenAICompatibleClientError.transport(
              error.localizedDescription
            )
          )
        }
      }

      continuation.onTermination = { @Sendable _ in
        requestTask.cancel()
      }
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
/// for any session the client is given, `URLSession.shared` included.
private final class RedirectRefusal: NSObject, URLSessionTaskDelegate, Sendable {
  func urlSession(
    _ session: URLSession,
    task: URLSessionTask,
    willPerformHTTPRedirection response: HTTPURLResponse,
    newRequest request: URLRequest
  ) async -> URLRequest? {
    nil
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
  /// logged it.
  fileprivate static func bearerToken(
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
      throw OpenAICompatibleClientError.credentialUnavailable(error.localizedDescription)
    }
    guard let token else {
      throw OpenAICompatibleClientError.credentialUnavailable(
        "no key is saved for \(host)."
      )
    }
    return token
  }

  fileprivate static func makeRequest(
    messages: [ChatMessage],
    tools: [EvieToolDefinition],
    configuration: EvieConfiguration
  ) throws -> URLRequest {
    var request = URLRequest(url: configuration.chatCompletionsURL)
    request.httpMethod = "POST"
    request.timeoutInterval = configuration.requestTimeout
    request.setValue("application/json", forHTTPHeaderField: "Content-Type")
    request.setValue("text/event-stream", forHTTPHeaderField: "Accept")

    let body = ChatCompletionRequest(
      model: configuration.model,
      messages: messages.map(APIMessage.init),
      stream: true,
      streamOptions: .init(includeUsage: true),
      maxCompletionTokens: configuration.maxCompletionTokens,
      temperature: configuration.temperature,
      topP: configuration.topP,
      stop: configuration.stopSequences.isEmpty
        ? nil
        : configuration.stopSequences
    )

    do {
      let encoded = try JSONEncoder().encode(body)
      guard tools.isEmpty else {
        // JSON Schema is open-ended, so the tools are built as dictionaries and
        // grafted onto the encoded body. Keeping the other fields in `Encodable`
        // means there is still one description of them.
        guard
          var object = try JSONSerialization.jsonObject(with: encoded) as? [String: Any]
        else {
          throw OpenAICompatibleClientError.requestEncoding("body was not an object")
        }
        object["tools"] = tools.map(\.wireRepresentation)
        request.httpBody = try JSONSerialization.data(
          withJSONObject: object,
          options: [.sortedKeys]
        )
        return request
      }
      request.httpBody = encoded
    } catch let error as OpenAICompatibleClientError {
      throw error
    } catch {
      throw OpenAICompatibleClientError.requestEncoding(error.localizedDescription)
    }
    return request
  }

  fileprivate static func consumeStream(
    _ bytes: URLSession.AsyncBytes,
    continuation: AsyncThrowingStream<EvieInteractionEvent, any Error>.Continuation
  ) async throws {
    var lineBuffer = SSELineBuffer()
    var eventBuffer = SSEDataBuffer()
    var fullText = ""
    var finishReason: String?
    var receivedEvent = false
    var receivedDone = false
    var toolCalls = EvieToolCallAccumulator()
    var announcedToolPhase = false

    func processPayload(_ payload: String) throws -> Bool {
      switch try decodeStreamPayload(payload) {
      case .done:
        return true

      case .chunk(let chunk):
        if let error = chunk.error {
          throw OpenAICompatibleClientError.server(
            message: error.message,
            code: error.code
          )
        }

        if let usage = chunk.usage {
          continuation.yield(.usage(usage.normalized))
        }

        for choice in chunk.choices ?? [] {
          if let delta = choice.delta.content, !delta.isEmpty {
            fullText += delta
            continuation.yield(.responseTextDelta(delta))
          }
          for fragment in choice.delta.toolCalls ?? [] {
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
      throw OpenAICompatibleClientError.emptyStream
    }
    guard receivedDone else {
      throw OpenAICompatibleClientError.streamEndedBeforeDone
    }

    try Task.checkCancellation()
    let assembled = toolCalls.calls()
    let message = ChatMessage(
      role: .assistant,
      content: fullText,
      toolCalls: assembled.isEmpty ? nil : assembled
    )
    continuation.yield(
      .completed(message: message, finishReason: finishReason)
    )
    continuation.finish()
  }

  fileprivate static func decodeStreamPayload(_ payload: String) throws -> StreamPayload {
    if payload.trimmingCharacters(in: .whitespacesAndNewlines) == "[DONE]" {
      return .done
    }

    guard let data = payload.data(using: .utf8) else {
      throw OpenAICompatibleClientError.malformedStreamEvent
    }

    do {
      return .chunk(try JSONDecoder().decode(StreamChunk.self, from: data))
    } catch {
      throw OpenAICompatibleClientError.malformedStreamEvent
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

private struct ChatCompletionRequest: Encodable {
  let model: String
  let messages: [APIMessage]
  let stream: Bool
  let streamOptions: StreamOptions
  let maxCompletionTokens: Int
  let temperature: Double?
  let topP: Double?
  let stop: [String]?

  enum CodingKeys: String, CodingKey {
    case model
    case messages
    case stream
    case streamOptions = "stream_options"
    case maxCompletionTokens = "max_completion_tokens"
    case temperature
    case topP = "top_p"
    case stop
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
  let content: String
  let name: String?
  let toolCallID: String?
  let toolCalls: [APIToolCall]?

  init(_ message: ChatMessage) {
    role = message.role.rawValue
    content = message.content
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
  let toolCalls: [StreamToolCall]?

  enum CodingKeys: String, CodingKey {
    case content
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

private struct APIErrorEnvelope: Decodable {
  let error: APIError
}

private struct APIError: Decodable {
  let message: String
  let code: String?
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
      throw OpenAICompatibleClientError.malformedStreamEvent
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
