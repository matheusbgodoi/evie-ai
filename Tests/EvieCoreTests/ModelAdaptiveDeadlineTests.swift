import Foundation
import Testing

@testable import EvieCore

@Suite("Long prompt deadlines")
struct ModelAdaptiveDeadlineTests {
  private let configuration = EvieConfiguration(requestTimeout: 900)

  @Test("short inputs keep the existing response deadlines for every readiness state")
  func shortInputsKeepDeadlines() {
    for readiness: ReadinessRung? in [nil, .ready, .modelCold, .unreachable] {
      for carriesImage in [false, true] {
        let original = ModelDeadlinePolicy.standard.deadlines(
          readiness: readiness, carriesImage: carriesImage, configuration: configuration)
        for tokens in [-1, 0, 16_384] {
          #expect(
            ModelDeadlinePolicy.standard.deadlines(
              readiness: readiness, carriesImage: carriesImage, configuration: configuration,
              inputTokens: tokens) == original)
        }
      }
    }
  }

  @Test("a large prompt extends headers, first token and idle together within the resource ceiling")
  func largePromptExtendsEachStage() {
    let deadlines = ModelDeadlinePolicy.standard.deadlines(
      readiness: .ready, carriesImage: false, configuration: configuration, inputTokens: 131_072)
    #expect(deadlines.headers > .seconds(405))
    #expect(deadlines.firstToken == deadlines.headers)
    #expect(deadlines.headers <= .seconds(900))
    #expect(deadlines.idleGap > 405 && deadlines.idleGap <= 900)
    let image = ModelDeadlinePolicy.standard.deadlines(
      readiness: .ready, carriesImage: true, configuration: configuration, inputTokens: 131_072)
    #expect(image == deadlines)
  }

  @Test("very large inputs saturate safely and never extend past fifteen minutes")
  func reserveSaturatesWithoutOverflow() {
    for tokens in [200_704, Int.max] {
      #expect(
        ModelDeadlinePolicy.standard.deadlines(
          readiness: .ready, carriesImage: false, configuration: configuration, inputTokens: tokens)
          == ModelTurnDeadlines(idleGap: 900, headers: .seconds(900), firstToken: .seconds(900)))
    }
  }

  @Test(
    "explicit profile timeout limits the adaptive reserve without shortening cold-load allowance")
  func configuredCapAndColdAllowance() {
    let shortCap = EvieConfiguration(requestTimeout: 300)
    let ready = ModelDeadlinePolicy.standard.deadlines(
      readiness: .ready, carriesImage: false, configuration: shortCap, inputTokens: 131_072)
    #expect(
      ready == ModelTurnDeadlines(idleGap: 300, headers: .seconds(300), firstToken: .seconds(300)))
    let cold = ModelDeadlinePolicy.standard.deadlines(
      readiness: .modelCold, carriesImage: false, configuration: shortCap, inputTokens: 131_072)
    #expect(
      cold == ModelTurnDeadlines(idleGap: 600, headers: .seconds(600), firstToken: .seconds(300)))
    let longCold = ModelDeadlinePolicy.standard.deadlines(
      readiness: .modelCold, carriesImage: false, configuration: configuration, inputTokens: 131_072
    )
    #expect(longCold.headers > .seconds(600))
    #expect(longCold.firstToken == longCold.headers)
  }

  @Test("the request estimator includes all roles and the same picture proxy as context planning")
  func estimatorIncludesHistoryAndPictures() {
    let messages = [
      ChatMessage(role: .system, content: "123"), ChatMessage(role: .user, content: "45"),
    ]
    #expect(OpenAICompatibleClient.estimatedInputTokens(in: messages) == 3)
    #expect(OpenAICompatibleClient.estimatedInputTokens(in: []) == 0)
    var picture = ChatMessage(role: .user, content: "x")
    picture.images = [
      EvieImagePart(
        mimeType: "image/png", data: Data([1]), pixelSize: CGSize(width: 1, height: 1),
        origin: .attachment)
    ]
    #expect(OpenAICompatibleClient.estimatedInputTokens(in: [picture]) == 1_501)
  }

  @Test("the actual request reserves enough idle time for a measured 128K local prefill")
  func longRequestGetsAdaptiveIdleGap() throws {
    let configuration = EvieConfiguration(
      contextWindowTokens: 131_072, maxCompletionTokens: 2_048, requestTimeout: 900)
    var options = TurnOptions.chat(configuration)
    options.readiness = .ready
    let request = try OpenAICompatibleClient.makeRequest(
      messages: [ChatMessage(role: .user, content: String(repeating: "x", count: 262_144))],
      tools: [], options: options, configuration: configuration, bearerToken: nil)
    #expect(request.timeoutInterval > 405)
    #expect(request.timeoutInterval <= 900)
  }
}
