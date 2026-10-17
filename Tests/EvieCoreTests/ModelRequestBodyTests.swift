import Foundation
import Testing

@testable import EvieCore

/// What goes on the wire for one turn, read from `makeRequest` directly: it is
/// synchronous and takes the token as an argument, so the body can be checked
/// without a server, a keychain or a stream.
@Suite("Model request body")
struct ModelRequestBodyTests {
  private let gateway = EvieConfiguration(
    endpoint: URL(string: "https://stub.evie.test/v1")!,
    model: "qwen-daily",
    contextWindowTokens: 135_168,
    maxCompletionTokens: 16_384,
    thinkingStyle: .templateKwargs
  )
  private let persona = ChatMessage(role: .system, content: "Você é a Evie.")
  private let question = ChatMessage(role: .user, content: "Que horas são?")

  @Test("the Bearer header is set when a token is given and absent when not")
  func bearerHeader() throws {
    let with = try request([question], token: "test-token-not-a-secret")
    let without = try request([question], token: nil)

    #expect(with.value(forHTTPHeaderField: "Authorization") == "Bearer test-token-not-a-secret")
    #expect(without.value(forHTTPHeaderField: "Authorization") == nil)
  }

  @Test("max_tokens is sent and max_completion_tokens never is")
  func maxTokensField() throws {
    let body = try json(request([question], options: .chat(gateway)))

    #expect(body["max_tokens"] as? Int == 16_384)
    #expect(body["max_completion_tokens"] == nil)
    let streamOptions = try #require(body["stream_options"] as? [String: Any])
    #expect(streamOptions["include_usage"] as? Bool == true)
  }

  @Test("templateKwargs with thinking off sends enable_thinking false and no effort")
  func templateKwargsOff() throws {
    let body = try json(request([question], options: .chat(gateway)))

    let kwargs = try #require(body["chat_template_kwargs"] as? [String: Any])
    #expect(kwargs.count == 1)
    #expect(kwargs["enable_thinking"] as? Bool == false)
    #expect(body["thinking_budget_tokens"] == nil)
    #expect(body["enable_thinking"] == nil)
  }

  @Test("the built-in PC brain asks for a streamed answer with thinking off, typed or spoken")
  func builtInPCIsFast() throws {
    let pc = EvieModelProfile.builtInPC
    for spoken in [false, true] {
      let options = EvieTurnPlan(profile: pc, readiness: .ready).options(spoken: spoken)
      let body = try json(
        request([question], configuration: pc.configuration, options: options))

      #expect(body["stream"] as? Bool == true)
      let kwargs = try #require(body["chat_template_kwargs"] as? [String: Any])
      #expect(kwargs["enable_thinking"] as? Bool == false)
      #expect(body["thinking_budget_tokens"] == nil)
    }
  }

  @Test("templateKwargs with low thinking sends the effort, no preserved thinking, and a budget")
  func templateKwargsLow() throws {
    var thinking = gateway
    thinking.defaultReasoning = .low
    let body = try json(request([question], options: .chat(thinking)))

    let kwargs = try #require(body["chat_template_kwargs"] as? [String: Any])
    #expect(kwargs["enable_thinking"] as? Bool == true)
    #expect(kwargs["reasoning_effort"] as? String == "low")
    #expect(kwargs["preserve_thinking"] as? Bool == false)
    #expect(body["max_tokens"] as? Int == 8_192)
    #expect(body["thinking_budget_tokens"] as? Int == 6_144)
  }

  @Test("xhigh thinking gets the measured 16384 / 12288 pairing")
  func templateKwargsMaximum() throws {
    var thinking = gateway
    thinking.defaultReasoning = .xhigh
    let body = try json(request([question], options: .chat(thinking)))

    let kwargs = try #require(body["chat_template_kwargs"] as? [String: Any])
    #expect(kwargs["reasoning_effort"] as? String == "xhigh")
    #expect(body["max_tokens"] as? Int == 16_384)
    #expect(body["thinking_budget_tokens"] as? Int == 12_288)
  }

  @Test("the budget never exceeds three quarters of a turn's output cap")
  func budgetFitsTheCap() throws {
    var small = gateway
    small.maxCompletionTokens = 4_096
    small.defaultReasoning = .xhigh
    let body = try json(request([question], configuration: small, options: .chat(small)))

    #expect(body["max_tokens"] as? Int == 4_096)
    #expect(body["thinking_budget_tokens"] as? Int == 3_072)
  }

  @Test("topLevel sends a top-level enable_thinking and no chat_template_kwargs")
  func topLevelStyle() throws {
    var mac = gateway
    mac.thinkingStyle = .topLevel
    let body = try json(request([question], configuration: mac, options: .chat(mac)))

    #expect(body["enable_thinking"] as? Bool == false)
    #expect(body["chat_template_kwargs"] == nil)
    #expect(body["thinking_budget_tokens"] == nil)
  }

  @Test(
    "topLevel turns off the Mac server's automatic context compaction; other styles send nothing")
  func topLevelOptsOutOfCompaction() throws {
    var mac = gateway
    mac.thinkingStyle = .topLevel
    let macBody = try json(request([question], configuration: mac, options: .chat(mac)))
    let gatewayBody = try json(request([question], options: .chat(gateway)))

    // mlx-vlm 0.7.8 otherwise summarizes older messages itself, with the model,
    // whenever a prompt would not fit under --max-kv-size.
    #expect((macBody["context_management"] as? [Any])?.isEmpty == true)
    #expect(gatewayBody["context_management"] == nil)
  }

  @Test("style none sends no thinking parameter at all")
  func noThinkingStyle() throws {
    var plain = gateway
    plain.thinkingStyle = .none
    plain.defaultReasoning = .medium
    let body = try json(request([question], configuration: plain, options: .chat(plain)))

    #expect(body["enable_thinking"] == nil)
    #expect(body["chat_template_kwargs"] == nil)
    #expect(body["thinking_budget_tokens"] == nil)
    // A text answer uses the configured cap regardless of unsupported reasoning.
    #expect(body["max_tokens"] as? Int == plain.maxCompletionTokens)
  }

  @Test("a text-only message keeps content as a String")
  func textContentIsAString() throws {
    let messages = try wireMessages(request([persona, question]))

    #expect(messages[1]["content"] as? String == "Que horas são?")
  }

  @Test("a message with an image becomes a text part and a data-URL part")
  func imageContentParts() throws {
    let image = EvieImagePart(
      mimeType: "image/jpeg",
      data: Data([0xFF, 0xD8, 0xFF]),
      pixelSize: CGSize(width: 32, height: 32),
      origin: .screenshot
    )
    var looking = ChatMessage(role: .user, content: "Que cor é esta?")
    looking.images = [image]
    let messages = try wireMessages(request([persona, looking]))

    let parts = try #require(messages[1]["content"] as? [[String: Any]])
    #expect(parts.count == 2)
    #expect(parts[0]["type"] as? String == "text")
    #expect(parts[0]["text"] as? String == "Que cor é esta?")
    #expect(parts[1]["type"] as? String == "image_url")
    let imageURL = try #require(parts[1]["image_url"] as? [String: Any])
    #expect(imageURL["url"] as? String == "data:image/jpeg;base64,/9j/")
  }

  @Test("the first system message is byte-stable and late guidance rides with the question")
  func lateSystemMessages() throws {
    let earlier = [
      persona,
      ChatMessage(role: .user, content: "Oi"),
      ChatMessage(role: .assistant, content: "Olá!"),
    ]
    let guidance = ChatMessage(role: .system, content: "Siga a skill de resumo.")
    let plain = try wireMessages(request(earlier + [question]))
    let guided = try wireMessages(request(earlier + [guidance, question]))

    #expect(plain.count == guided.count)
    for index in 0..<3 {
      #expect(NSDictionary(dictionary: plain[index]) == NSDictionary(dictionary: guided[index]))
    }
    #expect(guided[0]["role"] as? String == "system")
    #expect(guided[0]["content"] as? String == "Você é a Evie.")
    #expect(!guided.dropFirst().contains { $0["role"] as? String == "system" })
    #expect(guided[3]["role"] as? String == "user")
    #expect(
      guided[3]["content"] as? String
        == "<system-context>\nSiga a skill de resumo.\n</system-context>\n\nQue horas são?"
    )
  }

  @Test("a developer message after the first is treated like a late system message")
  func lateDeveloperMessage() throws {
    let messages = try wireMessages(
      request([
        persona,
        ChatMessage(role: .developer, content: "Responda curto."),
        question,
      ])
    )

    #expect(messages.count == 2)
    #expect(
      messages[1]["content"] as? String
        == "<system-context>\nResponda curto.\n</system-context>\n\nQue horas são?"
    )
  }

  @Test("late guidance with no user message after it still reaches the model")
  func trailingLateSystemMessage() throws {
    let messages = try wireMessages(
      request([persona, question, ChatMessage(role: .system, content: "Seja breve.")])
    )

    #expect(messages.count == 3)
    #expect(messages[2]["role"] as? String == "user")
    #expect(messages[2]["content"] as? String == "<system-context>\nSeja breve.\n</system-context>")
  }

  @Test("an empty toolset means no tools key and no parallel_tool_calls")
  func emptyToolset() throws {
    let body = try json(request([question]))

    #expect(body["tools"] == nil)
    #expect(body["parallel_tool_calls"] == nil)
  }

  @Test("a toolset is declared with parallel_tool_calls false")
  func declaredToolset() throws {
    let body = try json(request([question], tools: [EvieCalculatorTool.definition]))

    let tools = try #require(body["tools"] as? [[String: Any]])
    #expect(tools.count == 1)
    #expect(body["parallel_tool_calls"] as? Bool == false)
  }

  @Test("a body over 60 MB is refused before it is sent")
  func requestTooLarge() {
    var huge = ChatMessage(role: .user, content: "Olha isso")
    huge.images = [
      EvieImagePart(
        mimeType: "image/png",
        data: Data(count: 48_000_000),
        pixelSize: CGSize(width: 8_000, height: 6_000),
        origin: .attachment
      )
    ]

    #expect(throws: ModelClientError.requestTooLarge) {
      try request([huge])
    }
  }

  @Test("the idle gap follows the model's readiness")
  func idleGapFollowsReadiness() throws {
    var cold = TurnOptions.chat(gateway)
    cold.readiness = .modelCold
    var ready = TurnOptions.chat(gateway)
    ready.readiness = .ready

    #expect(try request([question], options: cold).timeoutInterval == 600)
    #expect(try request([question], options: ready).timeoutInterval == 120)
    // Unprobed — every turn until the readiness probe exists — keeps the
    // configured request timeout, so nothing that worked before times out now.
    #expect(try request([question], options: .chat(gateway)).timeoutInterval == 300)
  }
}

extension ModelRequestBodyTests {
  fileprivate func request(
    _ messages: [ChatMessage],
    tools: [EvieToolDefinition] = [],
    configuration: EvieConfiguration? = nil,
    options: TurnOptions? = nil,
    token: String? = nil
  ) throws -> URLRequest {
    let configuration = configuration ?? gateway
    return try OpenAICompatibleClient.makeRequest(
      messages: messages,
      tools: tools,
      options: options ?? .chat(configuration),
      configuration: configuration,
      bearerToken: token
    )
  }

  fileprivate func json(_ request: URLRequest) throws -> [String: Any] {
    let body = try #require(request.httpBody)
    return try #require(try JSONSerialization.jsonObject(with: body) as? [String: Any])
  }

  fileprivate func wireMessages(_ request: URLRequest) throws -> [[String: Any]] {
    try #require(try json(request)["messages"] as? [[String: Any]])
  }
}
