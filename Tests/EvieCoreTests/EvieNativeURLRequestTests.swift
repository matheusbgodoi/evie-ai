import Foundation
import Testing

@testable import EvieCore

@Suite("URLs nativas abrem somente interfaces de revisão")
struct EvieNativeURLRequestTests {
  private func parse(_ text: String) throws -> EvieNativeURLRequest {
    try EvieNativeURLRequest.parse(#require(URL(string: text)))
  }

  @Test func opensConversationAndRequestsCaptureConfirmation() throws {
    #expect(try parse("evie://open") == .openConversation)
    #expect(try parse("EVIE://OPEN") == .openConversation)
    #expect(try parse("evie://capture") == .requestCaptureConfirmation)
  }

  @Test func preparesDecodedTextWithoutTreatingItAsAnAction() throws {
    #expect(
      try parse("evie://prepare?text=%20Ol%C3%A1%20%26%20voc%C3%AA%3F%0A")
        == .prepareQuestion("Olá & você?"))
    #expect(
      try parse("evie://prepare?text=evie%3A%2F%2Fcapture")
        == .prepareQuestion("evie://capture"))
    #expect(try parse("evie://prepare?text=a%2Bb") == .prepareQuestion("a+b"))
  }

  @Test func rejectsExternalAuthorityAndAdditionalCommands() throws {
    let rejected = [
      "https://open", "evie:open", "evie:///open", "evie://submit", "evie://agent",
      "evie://open/extra", "evie://open/", "evie://open?text=hello", "evie://open#fragment",
      "evie://capture?confirmed=true", "evie://user@open", "evie://user:password@open",
      "evie://open:80", "evie://prepare", "evie://prepare?question=hello",
      "evie://prepare?text=a&text=b", "evie://prepare?text=a&submit=true",
      "evie://prepare?text=a#send", "evie://prepare?text=%00hello",
    ]
    for text in rejected {
      #expect(throws: EvieNativeURLRequest.Problem.invalidURL) { try parse(text) }
    }
  }

  @Test func enforcesUnicodeQuestionLimitAndEmptyInput() throws {
    for text in ["", " ", "\n\t"] {
      var parts = URLComponents(string: "evie://prepare")!
      parts.queryItems = [URLQueryItem(name: "text", value: text)]
      #expect(throws: EvieNativeURLRequest.Problem.emptyQuestion) {
        try EvieNativeURLRequest.parse(#require(parts.url))
      }
    }
    let accepted = String(repeating: "👩🏽‍💻", count: 8_000)
    var parts = URLComponents(string: "evie://prepare")!
    parts.queryItems = [URLQueryItem(name: "text", value: accepted)]
    #expect(try EvieNativeURLRequest.parse(#require(parts.url)) == .prepareQuestion(accepted))
    parts.queryItems = [URLQueryItem(name: "text", value: accepted + "á")]
    #expect(throws: EvieNativeURLRequest.Problem.questionTooLong) {
      try EvieNativeURLRequest.parse(#require(parts.url))
    }
  }

  @Test func boundsEncodedInputBeforeUnicodeParsing() throws {
    let oversized = "evie://prepare?text=" + String(repeating: "%61", count: 350_000)
    #expect(throws: EvieNativeURLRequest.Problem.invalidURL) { try parse(oversized) }
    // Many combining scalars can form one grapheme. The encoded bound still
    // prevents an otherwise tiny character count from admitting a huge input.
    var parts = URLComponents(string: "evie://prepare")!
    parts.queryItems = [
      URLQueryItem(name: "text", value: "a" + String(repeating: "\u{0301}", count: 180_000))
    ]
    #expect(throws: EvieNativeURLRequest.Problem.invalidURL) {
      try EvieNativeURLRequest.parse(#require(parts.url))
    }
  }
}
