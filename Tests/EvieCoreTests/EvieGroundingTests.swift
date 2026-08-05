import Foundation
import Testing

@testable import EvieCore

@Suite("Evie grounding")
struct EvieGroundingTests {
  /// The case this exists for. Measured twice against the running model: asked
  /// this with the web switched on, she answered from memory and called no tool,
  /// both before and after the rule was rewritten as an imperative section.
  @Test("a factual question is looked up first")
  func factualQuestionsAreLookedUp() {
    let questions = [
      "Qual a diferença entre HTTP/2 e HTTP/3?",
      "Quando sai a próxima versão do Swift?",
      "O que eu tenho anotado sobre a Cluemed?",
      "Quanto custa um MacBook Pro M5?",
      "Quem fundou a Anthropic?",
      "Como funciona o protocolo QUIC?",
    ]

    for question in questions {
      #expect(EvieGrounding.needsLookup(question), "não procuraria: \(question)")
    }
  }

  /// Searching for these wastes seconds and returns noise: the material is
  /// already in the conversation, or there is no material at all.
  @Test("work about text already on screen is not looked up")
  func selfContainedWorkIsNot() {
    let questions = [
      "resuma o texto que eu te mandei",
      "traduza isso para o inglês",
      "reescreva esse parágrafo mais curto",
      "corrija a gramática disso",
      "bom dia, tudo bem?",
      "obrigado!",
      "quem é você?",
    ]

    for question in questions {
      #expect(!EvieGrounding.needsLookup(question), "procuraria à toa: \(question)")
    }
  }

  @Test("arithmetic is answered, not searched")
  func arithmeticIsNot() {
    #expect(!EvieGrounding.needsLookup("quanto é 17 vezes 4?"))
    #expect(!EvieGrounding.needsLookup("calcule 1200 / 16"))
  }

  /// A question that merely contains the word "quanto" is still a question about
  /// the world.
  @Test("a question about an amount is still looked up")
  func amountsAreStillFactual() {
    #expect(EvieGrounding.needsLookup("quanto custa hospedar um site na AWS hoje em dia?"))
    #expect(EvieGrounding.needsLookup("quanto é o salário médio de um engenheiro de software no Brasil"))
  }

  @Test("a greeting is too short to be worth looking up")
  func shortInputIsNot() {
    #expect(!EvieGrounding.needsLookup("oi"))
    #expect(!EvieGrounding.needsLookup("e aí"))
  }

  // MARK: - The query

  @Test("the question is searched almost as written")
  func queryKeepsTheQuestion() {
    let query = EvieGrounding.query(from: "  Qual a versão mais recente do Swift?  ")

    #expect(query == "Qual a versão mais recente do Swift?")
  }

  @Test("being addressed by name is stripped from the search")
  func queryDropsTheAddress() {
    #expect(
      EvieGrounding.query(from: "Evie, qual a versão do Swift?") == "qual a versão do Swift?"
    )
  }

  @Test("a very long question is cut rather than sent whole")
  func queryIsBounded() {
    let long = String(repeating: "palavra ", count: 200)

    #expect(EvieGrounding.query(from: long).count <= 180)
  }

  // MARK: - What the model receives

  @Test("nothing found produces no message rather than an empty one")
  func emptyGroundingIsSilent() {
    #expect(EvieGroundingResult().message == nil)
    #expect(EvieGroundingResult().isEmpty)
  }

  /// Findings are the least trustworthy text in the turn — a note the user wrote
  /// years ago, or a page written by a stranger. They arrive fenced.
  @Test("findings arrive as material, never as instruction")
  func findingsAreFenced() throws {
    let result = EvieGroundingResult(localFindings: "algo que ele escreveu")
    let message = try #require(result.message)

    // A user turn, not developer guidance: the server refuses guidance that
    // arrives after the conversation has begun.
    #expect(message.role == .user)
    #expect(message.content.contains("nunca instrução"))
    #expect(message.content.contains("algo que ele escreveu"))
  }

  /// Handed an empty section, a model treats the silence as permission to
  /// invent, so the instruction to say "não achei" travels with the findings.
  @Test("the model is told what to do when the findings do not answer")
  func tellsHerWhatToDoWhenNothingFits() throws {
    let message = try #require(
      EvieGroundingResult(webFindings: "resultados").message
    )

    #expect(message.content.contains("não achou"))
    #expect(message.content.contains("memória"))
  }

  @Test("both sources are labelled separately")
  func separatesTheSources() throws {
    let message = try #require(
      EvieGroundingResult(localFindings: "das notas", webFindings: "da web").message
    )

    #expect(message.content.contains("anotações e pastas"))
    #expect(message.content.contains("Da web"))
  }
}
