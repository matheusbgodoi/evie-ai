import Foundation
import Testing

@testable import EvieCore

/// She used to have no clock at all, so "esta semana" was whatever the model
/// guessed. These pin the date into the prompt and pin down its shape.
@Suite("Evie persona clock")
struct EviePersonaClockTests {
  /// Friday, 7 August 2026, 14:32 in São Paulo.
  private let moment = Date(timeIntervalSince1970: 1_786_123_920)
  private let saoPaulo = TimeZone(identifier: "America/Sao_Paulo")!

  @Test("the prompt carries the weekday, the date and the time")
  func statesTheDate() {
    let prompt = EviePersona.evie.systemPrompt(
      capabilities: .textOnly,
      now: moment,
      timeZone: saoPaulo
    )

    #expect(prompt.contains("sexta-feira"))
    #expect(prompt.contains("7 de agosto de 2026"))
    // Deliberately not the minute. The system prompt is the cached prefix of
    // every request — 42% of prompt tokens are served from that cache on this
    // Mac — and a prompt that changes every minute never matches it. The exact
    // time rides with the question instead; see `OverlayViewModel.timestamp`.
    #expect(!prompt.contains("14:32"))
  }

  @Test("the timezone is named, because a deadline without one is approximate")
  func namesTheTimeZone() {
    let prompt = EviePersona.evie.systemPrompt(
      capabilities: .textOnly,
      now: moment,
      timeZone: saoPaulo
    )

    #expect(prompt.localizedCaseInsensitiveContains("Brasília"))
  }

  @Test("the date follows the timezone it is asked for")
  func followsTheTimeZone() {
    // 14:32 in São Paulo is already the 7th in Tokyo, at 02:32 on the 8th.
    let tokyo = EviePersona.evie.systemPrompt(
      capabilities: .textOnly,
      now: moment,
      timeZone: TimeZone(identifier: "Asia/Tokyo")!
    )

    #expect(tokyo.contains("8 de agosto de 2026"))
    // The date, not the time, for the reason above. Tokyo is a day ahead, which
    // is what this is really checking.
    #expect(!tokyo.contains("02:32"))
  }

  @Test("a prompt built a day later says the next day")
  func movesWithTheClock() {
    let today = EviePersona.evie.systemPrompt(
      capabilities: .textOnly,
      now: moment,
      timeZone: saoPaulo
    )
    let tomorrow = EviePersona.evie.systemPrompt(
      capabilities: .textOnly,
      now: moment.addingTimeInterval(86_400),
      timeZone: saoPaulo
    )

    #expect(today != tomorrow)
    #expect(tomorrow.contains("sábado"))
    #expect(tomorrow.contains("8 de agosto de 2026"))
  }

  @Test("she is told not to guess the date")
  func forbidsGuessing() {
    let prompt = EviePersona.evie.systemPrompt(
      capabilities: .textOnly,
      now: moment,
      timeZone: saoPaulo
    )

    #expect(prompt.contains("hoje"))
    #expect(prompt.contains("Nunca chute a data"))
  }

  @Test("the calculator instruction appears only once the tool is offered")
  func tiesArithmeticRuleToTheTool() {
    var capabilities = EvieCapabilitySnapshot.textOnly
    #expect(!EviePersona.evie.systemPrompt(capabilities: capabilities).contains("calculate"))

    capabilities.calculates = true
    let prompt = EviePersona.evie.systemPrompt(capabilities: capabilities)
    #expect(prompt.contains("TODA CONTA VAI PARA A FERRAMENTA calculate"))
    #expect(prompt.contains("inclusive as fáceis"))
  }

  /// The source-order block was put last on purpose, and the arithmetic rule
  /// must not have displaced it.
  @Test("the source-order rule is still the last thing she reads")
  func keepsSourceOrderLast() {
    let prompt = EviePersona.evie.systemPrompt(capabilities: .allEnabled)

    guard
      let arithmetic = prompt.range(of: "TODA CONTA VAI PARA A FERRAMENTA"),
      let sources = prompt.range(of: "ANTES DE RESPONDER QUALQUER PERGUNTA DE FATO")
    else {
      Issue.record("uma das duas regras sumiu do prompt")
      return
    }

    #expect(arithmetic.lowerBound < sources.lowerBound)
  }
}
