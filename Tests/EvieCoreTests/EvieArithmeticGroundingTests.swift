import Foundation
import Testing

@testable import EvieCore

/// The corpus is the deliverable here as much as the code is.
///
/// The rule that decides what counts as arithmetic cannot be reasoned out in the
/// abstract: it is a judgement about the sentences this particular person types,
/// and both failure modes are real. Too eager and "o artigo 5 da lei 8.078" gets
/// a sum bolted onto it; too shy and "quanto é 15% de 3400" — the case that
/// motivated the calculator — still goes to the model's head.
///
/// So both halves are written down, out of his actual life: two companies, an
/// engineering degree, a vault of notes, prices, deadlines, servo currents and
/// image sizes. The rule was tuned against these, not the other way round.
@Suite("Evie arithmetic grounding")
struct EvieArithmeticGroundingTests {
  // MARK: - Must ground

  /// The motivating case and its neighbours. Every one of these is a question
  /// whose answer *is* a number nobody wrote down yet.
  @Test("a question with a sum in it is calculated first")
  func groundsRealArithmetic() {
    let questions = [
      "quanto é 15% de 3400",
      "quanto é 15% de 3400?",
      "quanto é 1200 / 16",
      "calcule 2400 * 0,12",
      "quanto dá 45 + 78 + 132",
      "quanto é 17 vezes 4?",
      "quanto é 1200 dividido por 16",
      "quanto é 100 menos 37",
      // Keymatic: seis servos puxando 1,2 A cada um.
      "quanto é 1,2 * 6",
      // Uma imagem RGB de 2048x1536, em bytes.
      "quanto é 2048 * 1536 * 3",
      // Horas de bolsa de IC no mês.
      "quanto é 4,5 * 8 * 22",
      "quanto é (3400 + 1200) / 2",
      "quanto é 3400 - 15%",
      "quanto é 30% de 15000",
    ]

    for question in questions {
      #expect(
        !EvieArithmeticGrounding.calculations(in: question).isEmpty,
        "não calcularia: \(question)"
      )
    }
  }

  /// A message that is nothing but an expression is asking to be computed and
  /// nothing else, so it needs no word saying so.
  @Test("a bare expression is grounded without any cue")
  func groundsBareExpressions() {
    let questions = ["1200/16", "15% de 3400", "1250 * 3", "(120 + 80) * 1,3", "3400*0,12"]

    for question in questions {
      #expect(
        !EvieArithmeticGrounding.calculations(in: question).isEmpty,
        "não calcularia: \(question)"
      )
    }
  }

  /// The one percentage question the grammar cannot express as an operator.
  @Test("a percentage change is grounded")
  func groundsPercentageChange() throws {
    let calculation = try #require(
      EvieArithmeticGrounding.calculations(in: "de 80 para 100 é quantos %").first
    )

    #expect(calculation.formattedValue == "25%")
  }

  // MARK: - Must not ground

  /// Numbers that are names, dates, article numbers, versions and prices. Each
  /// of these is a real shape from his life, and every one of them would parse.
  @Test("a number that is not a sum is left alone")
  func doesNotGroundNumbersThatAreNotSums() {
    let questions = [
      "quantos anos tem a Cluemed",
      "o artigo 5 da lei 8.078 fala sobre o quê",
      "são 3 caixas de 12",
      "resume a nota da IC 25-26",
      "qual a diferença entre HTTP/2 e HTTP/3",
      "a reunião é 05/08 ou 12/08?",
      "me lembra do prazo do edital dia 30/09",
      "a corrente do servo MG996R é 2,5 A?",
      "o preço ficou em R$ 1.234,56",
      "leva de 10 a 15 minutos",
      "leva de 10 - 15 minutos",
      "roda a 60 fps em 1920x1080",
      "atualizei o firmware pra versão 2.0.1",
      "faturamos 120 mil em 2025 e 180 mil em 2026",
      "quanto custa hospedar um site na AWS hoje em dia?",
      "quanto é o salário médio de um engenheiro biomédico",
      "tem mais de 100 alunos na turma",
      "fui na Cluemed 3 vezes essa semana",
      "trabalhei das 9 às 18",
      "bom dia, tudo bem?",
    ]

    for question in questions {
      #expect(
        EvieArithmeticGrounding.calculations(in: question).isEmpty,
        "calcularia à toa: \(question)"
      )
    }
  }

  /// "são 3 caixas de 12" states a fact; nobody asked for a product. Reading
  /// "de" as multiplication would also compute "3 caixas de 12 reais" and "o
  /// artigo 5 da lei 8.078", so the word is never an operator here. If he wants
  /// the total he writes "3 * 12", and the tool is still declared for the rest.
  @Test("a quantity described in words is not multiplied")
  func doesNotInventMultiplication() {
    #expect(EvieArithmeticGrounding.calculations(in: "são 3 caixas de 12").isEmpty)
    #expect(EvieArithmeticGrounding.calculations(in: "quanto é 3 caixas de 12").isEmpty)
  }

  /// The half-expression case, and the reason a refusal is silent. "20% do
  /// faturamento" is arithmetic-shaped with an operand nobody knows, and the
  /// calculator refuses it. That refusal must vanish, not become an apology
  /// about an expression the user never typed.
  @Test("an expression the calculator refuses is dropped, not reported")
  func refusalIsSilent() {
    #expect(EvieArithmeticGrounding.calculations(in: "quanto é 20% do faturamento").isEmpty)
    #expect(EvieArithmeticGrounding.findings(for: "quanto é 20% do faturamento") == nil)
    #expect(EvieArithmeticGrounding.findings(for: "quanto é 8 / 0") == nil)
    #expect(EvieArithmeticGrounding.findings(for: "quanto é 12 +") == nil)
    #expect(EvieArithmeticGrounding.findings(for: "quanto é ((3 + 4)") == nil)
  }

  // MARK: - Several sums

  /// All of them, not one of them. Grounding the first sum and leaving the
  /// second to her head is the worst of both: the answer is half checked and
  /// nothing says which half.
  @Test("a question with two sums grounds both")
  func groundsEveryExpression() {
    let calculations = EvieArithmeticGrounding.calculations(
      in: "quanto é 15% de 3400 e 20% de 1200"
    )

    #expect(calculations.count == 2)
    #expect(calculations.map(\.formattedValue) == ["510", "240"])
  }

  /// Past the ceiling it is a pasted table, not a question with sums in it.
  @Test("a page of figures grounds nothing")
  func stopsAtTheCeiling() {
    let pasted = "1 * 2, 3 * 4, 5 * 6, 7 * 8, 9 * 10, 11 * 12"

    #expect(EvieArithmeticGrounding.calculations(in: pasted).isEmpty)
  }

  @Test("the same sum written twice is grounded once")
  func deduplicates() {
    let calculations = EvieArithmeticGrounding.calculations(
      in: "quanto é 2 * 3 e depois de novo 2 * 3"
    )

    #expect(calculations.count == 1)
  }

  // MARK: - What she is handed

  /// Both, always. The expression was pulled out of a sentence by code, not
  /// typed by anybody, so the reading is a claim she has to be able to check —
  /// the same reason `EvieCalculatorTool` echoes it back.
  @Test("the evidence says what was calculated and what came out")
  func findingsSayBoth() throws {
    let findings = try #require(EvieArithmeticGrounding.findings(for: "quanto é 15% de 3400"))

    #expect(findings.contains("15% * 3400"))
    #expect(findings.contains("510"))
    #expect(findings.contains("não é o que o Matheus perguntou"))
  }

  @Test("the sum arrives as a user turn, labelled as a calculation")
  func findingsTravelAsAUserTurn() throws {
    var result = EvieGroundingResult()
    result.arithmeticFindings = "17 * 4 = 68"
    let message = try #require(result.message)

    // A user turn, not developer guidance: this server refuses guidance that
    // arrives after the conversation has begun.
    #expect(message.role == .user)
    #expect(message.content.contains("calculou"))
    #expect(message.content.contains("Da calculadora"))
    #expect(message.content.contains("17 * 4 = 68"))
  }

  /// Nothing was searched, so the closing line about citing sources and warning
  /// that she is working from memory has no business being there.
  @Test("a purely arithmetic turn is not told to cite sources")
  func arithmeticAloneDropsTheSearchFraming() throws {
    var arithmetic = EvieGroundingResult()
    arithmetic.arithmeticFindings = "2 + 2 = 4"
    let alone = try #require(arithmetic.message)

    #expect(!alone.content.contains("cite de onde veio"))

    let mixed = try #require(
      EvieGroundingResult(
        localFindings: "das notas",
        arithmeticFindings: "2 + 2 = 4"
      ).message
    )

    #expect(mixed.content.contains("cite de onde veio"))
    #expect(mixed.content.contains("Da calculadora"))
  }
}
