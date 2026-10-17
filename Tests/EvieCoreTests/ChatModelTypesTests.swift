import Foundation
import Testing

@testable import EvieCore

@Suite("Chat model types")
struct ChatModelTypesTests {
  @Test("reasoning shows that she is thinking and never becomes the answer")
  func reasoningDeltaReducer() {
    var state = EvieInteractionState(phase: .thinking)

    state.apply(.reasoningDelta("pensando no que dizer"))
    #expect(state.isReasoning)
    #expect(state.responseText.isEmpty)

    state.apply(.responseTextDelta("Oi"))
    #expect(!state.isReasoning)
    #expect(state.responseText == "Oi")

    state.apply(.reasoningDelta("mais um pouco"))
    state.apply(
      .completed(message: ChatMessage(role: .assistant, content: "Oi!"), finishReason: "stop"))
    #expect(!state.isReasoning)
    #expect(state.responseText == "Oi!")
  }

  @Test("a message with images encodes without them")
  func imagesNeverEncode() throws {
    var message = ChatMessage(role: .user, content: "Olha a tela")
    message.images = [
      EvieImagePart(
        mimeType: "image/jpeg",
        data: Data(repeating: 0xAB, count: 64),
        pixelSize: CGSize(width: 8, height: 8),
        origin: .screenshot
      )
    ]

    let encoded = try JSONEncoder().encode(message)
    let object = try #require(try JSONSerialization.jsonObject(with: encoded) as? [String: Any])
    #expect(object["images"] == nil)
    #expect(Set(object.keys) == ["id", "role", "content", "createdAt"])

    let decoded = try JSONDecoder().decode(ChatMessage.self, from: encoded)
    #expect(decoded.images == nil)
    #expect(decoded.content == "Olha a tela")
  }

  @Test("a message saved before images existed decodes unchanged")
  func versionOneMessageDecodes() throws {
    let saved = Data(
      """
      {"id":"6B1C6F8A-2D7E-4C1B-9E55-0F3A2B1C4D5E","role":"assistant","content":"Olá",\
      "toolCalls":[{"id":"call-1","name":"calculate","argumentsJSON":"{}"}],\
      "createdAt":800000000}
      """.utf8
    )

    let message = try JSONDecoder().decode(ChatMessage.self, from: saved)

    #expect(message.id == UUID(uuidString: "6B1C6F8A-2D7E-4C1B-9E55-0F3A2B1C4D5E"))
    #expect(message.role == .assistant)
    #expect(message.content == "Olá")
    #expect(message.toolCalls?.first?.id == "call-1")
    #expect(message.images == nil)
    #expect(message.createdAt == Date(timeIntervalSinceReferenceDate: 800_000_000))
  }

  @Test("image parts are equal by identifier, never by their bytes")
  func imagePartIdentity() {
    let id = UUID()
    let first = EvieImagePart(
      id: id,
      mimeType: "image/jpeg",
      data: Data([1, 2, 3]),
      pixelSize: CGSize(width: 1, height: 1),
      origin: .screenshot
    )
    let sameIDOtherBytes = EvieImagePart(
      id: id,
      mimeType: "image/png",
      data: Data([9]),
      pixelSize: CGSize(width: 2, height: 2),
      origin: .attachment
    )
    let otherIDSameBytes = EvieImagePart(
      mimeType: "image/jpeg",
      data: Data([1, 2, 3]),
      pixelSize: CGSize(width: 1, height: 1),
      origin: .screenshot
    )

    #expect(first == sameIDOtherBytes)
    #expect(first.hashValue == sameIDOtherBytes.hashValue)
    #expect(first != otherIDSameBytes)
  }

  @Test("voice and chat turns have their own output caps and default to no thinking")
  func turnOptionCaps() {
    let gateway = EvieConfiguration(maxCompletionTokens: 16_384, thinkingStyle: .templateKwargs)

    #expect(TurnOptions.voice(gateway) == TurnOptions(reasoning: .off, maxTokens: 1_024))
    #expect(TurnOptions.chat(gateway) == TurnOptions(reasoning: .off, maxTokens: 16_384))
  }

  @Test("a computer-use step thinks a little on the PC and not elsewhere")
  func computerStepOptions() {
    let gateway = EvieConfiguration(thinkingStyle: .templateKwargs)
    let mac = EvieConfiguration(thinkingStyle: .topLevel)

    #expect(
      TurnOptions.computerStep(gateway)
        == TurnOptions(reasoning: .low, maxTokens: 1_024, thinkingBudgetTokens: 768)
    )
    #expect(TurnOptions.computerStep(mac) == TurnOptions(reasoning: .off, maxTokens: 1_024))
  }
}
