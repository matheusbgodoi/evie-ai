import Foundation

/// Errors raised by the local TurboFieldfare Chat Completions adapter.
public enum TurboFieldfareClientError: Error, Equatable, Sendable {
  case invalidConfiguration(String)
  case requestEncoding(String)
  case invalidHTTPResponse
  case httpStatus(code: Int, message: String?)
  case server(message: String, code: String?)
  case malformedStreamEvent
  case emptyStream
  case streamEndedBeforeDone
  case transport(String)
}

extension TurboFieldfareClientError: LocalizedError {
  public var errorDescription: String? {
    switch self {
    case .invalidConfiguration(let message):
      "Invalid Evie configuration: \(message)"
    case .requestEncoding(let message):
      "Could not encode the chat request: \(message)"
    case .invalidHTTPResponse:
      "TurboFieldfare returned a non-HTTP response."
    case .httpStatus(let code, let message):
      if let message, !message.isEmpty {
        "TurboFieldfare returned HTTP \(code): \(message)"
      } else {
        "TurboFieldfare returned HTTP \(code)."
      }
    case .server(let message, let code):
      if let code, !code.isEmpty {
        "TurboFieldfare error \(code): \(message)"
      } else {
        "TurboFieldfare error: \(message)"
      }
    case .malformedStreamEvent:
      "TurboFieldfare sent a malformed streaming event."
    case .emptyStream:
      "TurboFieldfare closed the stream without sending a response."
    case .streamEndedBeforeDone:
      "TurboFieldfare closed the stream before the [DONE] marker."
    case .transport(let message):
      "Could not communicate with TurboFieldfare: \(message)"
    }
  }
}

/// A dependency-free client for TurboFieldfare's OpenAI-compatible streaming API.
///
/// The client only performs inference. Tool execution and authorization belong to
/// Hermes/the Evie supervisor and are intentionally outside this adapter.
public final class TurboFieldfareClient: AgentClient, Sendable {
  public let configuration: EvieConfiguration
  private let session: URLSession

  public init(
    configuration: EvieConfiguration = EvieConfiguration(),
    session: URLSession = .shared
  ) {
    self.configuration = configuration
    self.session = session
  }

  public func stream(
    messages: [ChatMessage]
  ) -> AsyncThrowingStream<EvieInteractionEvent, any Error> {
    let configuration = configuration
    let session = session

    return AsyncThrowingStream { continuation in
      let requestTask = Task {
        do {
          try Task.checkCancellation()
          try configuration.validate()
          try Self.validateLoopbackEndpoint(configuration.endpoint)

          let request = try Self.makeRequest(
            messages: messages,
            configuration: configuration
          )
          continuation.yield(.phaseChanged(.thinking))

          let (bytes, response) = try await session.bytes(for: request)
          try Task.checkCancellation()

          guard let httpResponse = response as? HTTPURLResponse else {
            throw TurboFieldfareClientError.invalidHTTPResponse
          }

          guard (200...299).contains(httpResponse.statusCode) else {
            let errorBody = try await Self.readErrorBody(from: bytes)
            let apiError = errorBody.flatMap(Self.decodeAPIError(from:))
            throw TurboFieldfareClientError.httpStatus(
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
            throwing: TurboFieldfareClientError.invalidConfiguration(
              error.localizedDescription
            )
          )
        } catch let error as TurboFieldfareClientError {
          continuation.finish(throwing: error)
        } catch let error as URLError where error.code == .cancelled {
          continuation.finish(throwing: CancellationError())
        } catch {
          continuation.finish(
            throwing: TurboFieldfareClientError.transport(
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

extension TurboFieldfareClient {
  fileprivate static func validateLoopbackEndpoint(_ endpoint: URL) throws {
    let host = endpoint.host?.lowercased()
    let loopbackHosts: Set<String> = ["127.0.0.1", "localhost", "::1", "[::1]"]
    guard let host, loopbackHosts.contains(host) else {
      throw TurboFieldfareClientError.invalidConfiguration(
        "TurboFieldfare must use a loopback endpoint."
      )
    }
  }

  fileprivate static func makeRequest(
    messages: [ChatMessage],
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
      request.httpBody = try JSONEncoder().encode(body)
    } catch {
      throw TurboFieldfareClientError.requestEncoding(error.localizedDescription)
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

    func processPayload(_ payload: String) throws -> Bool {
      switch try decodeStreamPayload(payload) {
      case .done:
        return true

      case .chunk(let chunk):
        if let error = chunk.error {
          throw TurboFieldfareClientError.server(
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
      throw TurboFieldfareClientError.emptyStream
    }
    guard receivedDone else {
      throw TurboFieldfareClientError.streamEndedBeforeDone
    }

    try Task.checkCancellation()
    let message = ChatMessage(role: .assistant, content: fullText)
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
      throw TurboFieldfareClientError.malformedStreamEvent
    }

    do {
      return .chunk(try JSONDecoder().decode(StreamChunk.self, from: data))
    } catch {
      throw TurboFieldfareClientError.malformedStreamEvent
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

  init(_ message: ChatMessage) {
    role = message.role.rawValue
    content = message.content
    name = message.name
    toolCallID = message.toolCallID
  }

  enum CodingKeys: String, CodingKey {
    case role
    case content
    case name
    case toolCallID = "tool_call_id"
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
      throw TurboFieldfareClientError.malformedStreamEvent
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
