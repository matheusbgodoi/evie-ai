import Foundation
import Testing

@testable import EvieCore

/// The calculator is pure logic with no I/O, so every branch is reachable from
/// a test and there is no reason for any of them not to be covered.
@Suite("Evie calculator")
struct EvieCalculatorTests {
  private func value(_ expression: String) throws -> Double {
    try EvieCalculator.evaluate(expression).value
  }

  private func understood(_ expression: String) throws -> String {
    try EvieCalculator.evaluate(expression).understood
  }

  private func formatted(_ expression: String) throws -> String {
    try EvieCalculator.evaluate(expression).formattedValue
  }

  private func error(_ expression: String) -> EvieCalculatorError? {
    do {
      _ = try EvieCalculator.evaluate(expression)
      return nil
    } catch let error as EvieCalculatorError {
      return error
    } catch {
      return nil
    }
  }

  // MARK: Precedence and associativity

  @Test("multiplication binds tighter than addition")
  func respectsPrecedence() throws {
    #expect(try value("2 + 3 * 4") == 14)
    #expect(try value("(2 + 3) * 4") == 20)
    #expect(try value("2 * 3 + 4 * 5") == 26)
  }

  @Test("subtraction and division are left associative")
  func subtractionIsLeftAssociative() throws {
    #expect(try value("10 - 3 - 2") == 5)
    #expect(try value("100 / 5 / 2") == 10)
  }

  @Test("exponent is right associative and outranks unary minus")
  func exponentIsRightAssociative() throws {
    #expect(try value("2 ^ 3 ^ 2") == 512)
    #expect(try value("-2 ^ 2") == -4)
    #expect(try value("(-2) ^ 2") == 4)
    #expect(try value("2 ^ -1") == 0.5)
  }

  @Test("unary minus stacks and parentheses nest")
  func handlesUnaryAndNesting() throws {
    #expect(try value("--5") == 5)
    #expect(try value("-(3 + 4)") == -7)
    #expect(try value("((((1 + 1))))") == 2)
  }

  // MARK: Both number formats

  @Test("Brazilian and English thousands both read as the same number")
  func readsBothNumberFormats() throws {
    #expect(try value("1.234,56") == 1234.56)
    #expect(try value("1,234.56") == 1234.56)
    #expect(try value("1.234.567,89") == 1234567.89)
    #expect(try value("1,234,567.89") == 1234567.89)
  }

  @Test("a lone comma is always the decimal separator")
  func commaIsDecimal() throws {
    #expect(try value("1,5") == 1.5)
    #expect(try value("0,25 * 4") == 1)
  }

  @Test("a lone dot with three digits after it is grouping, and says so")
  func dotWithThreeDigitsIsGrouping() throws {
    #expect(try value("1.234") == 1234)
    // The reading is echoed back precisely because this is the one case that
    // reads against the foreign convention.
    #expect(try understood("1.234") == "1234")
  }

  @Test("every other lone dot is decimal")
  func otherDotsAreDecimal() throws {
    #expect(try value("1.5") == 1.5)
    #expect(try value("3.14159") == 3.14159)
    // A leading zero cannot start a grouped number, so this is half.
    #expect(try value("0.500") == 0.5)
    #expect(try value("12.34") == 12.34)
  }

  @Test("a number nobody could have written is refused, not rounded")
  func refusesMalformedGrouping() {
    #expect(error("1.2345,6") == .ambiguousNumber("1.2345,6"))
    #expect(error("1.23.456") == .ambiguousNumber("1.23.456"))
  }

  // MARK: Percentages

  @Test("percent of a number")
  func percentOf() throws {
    #expect(try value("15% * 240") == 36)
    #expect(try value("15% de 240") == 36)
    #expect(try value("15 por cento de 240") == 36)
  }

  @Test("percent added to and taken from a number is relative to that number")
  func percentRelativeToLeftOperand() throws {
    #expect(try value("240 + 15%") == 276)
    #expect(try value("240 - 15%") == 204)
    #expect(try value("100 + 10% + 10%") == 121)
  }

  @Test("a bare percent is a hundredth")
  func barePercent() throws {
    #expect(try value("15%") == 0.15)
    #expect(try value("50% ^ 2") == 0.25)
  }

  @Test("change between two numbers, in percent")
  func percentageChange() throws {
    let change = try EvieCalculator.evaluate("de 80 para 100 é quantos %")
    #expect(change.value == 25)
    #expect(change.formattedValue == "25%")
    #expect(change.understood == "variação percentual de 80 para 100")

    #expect(try value("de 100 para 80") == -20)
    #expect(try value("de 200 pra 250") == 25)
  }

  @Test("a change from zero has no percentage")
  func refusesChangeFromZero() {
    #expect(error("de 0 para 100") == .divisionByZero)
  }

  // MARK: Functions

  @Test("the named functions do what they are named after")
  func evaluatesFunctions() throws {
    #expect(try value("sqrt(144)") == 12)
    #expect(try value("abs(-7)") == 7)
    #expect(try value("round(2,5)") == 3)
    #expect(try value("floor(2,9)") == 2)
    #expect(try value("ceil(2,1)") == 3)
    #expect(try value("log(1000)") == 3)
    #expect(try value("ln(1)") == 0)
    #expect(try value("sin(0)") == 0)
    #expect(try value("cos(0)") == 1)
    #expect(try value("tan(0)") == 0)
  }

  @Test("min and max take their values separated by a semicolon")
  func evaluatesVariadicFunctions() throws {
    #expect(try value("max(1,5; 2)") == 2)
    #expect(try value("min(3; 1; 2)") == 1)
    // A comma that is not between two digits is a separator, so this works too.
    #expect(try value("max(1, 2)") == 2)
  }

  @Test("min and max refuse a single value rather than inventing a second")
  func refusesSingleArgumentToMax() {
    // "max(1,2)" is one argument of one and two tenths: the comma sits between
    // digits, so it is decimal. Refusing beats reading it as two numbers.
    #expect(error("max(1,2)") == .wrongArgumentCount("max"))
  }

  // MARK: Refusals

  @Test("division by zero is a sentence, not an infinity")
  func refusesDivisionByZero() {
    #expect(error("1 / 0") == .divisionByZero)
    #expect(error("0 / 0") == .divisionByZero)
    #expect(error("10 / (5 - 5)") == .divisionByZero)
  }

  @Test("overflow is refused rather than reported as infinity")
  func refusesOverflow() {
    #expect(error("9 ^ 9 ^ 9") == .overflow)
  }

  @Test("unbalanced parentheses are refused")
  func refusesUnbalancedParentheses() {
    #expect(error("(1 + 2") == .unbalancedParenthesis)
    #expect(error("1 + 2)") == .unbalancedParenthesis)
    #expect(error("sqrt(4") == .unbalancedParenthesis)
  }

  @Test("an unknown name is refused with the list of known ones")
  func refusesUnknownName() {
    #expect(error("mod(7; 2)") == .unknownName("mod"))
    #expect(error("pi * 2") == .unknownName("pi"))
    // The thing NSExpression would have been happy to look up.
    #expect(error("system(2)") == .unknownName("system"))
    #expect(error("self") == .unknownName("self"))
    // A key path is not arithmetic and never becomes any.
    #expect(error("self.description") == .unexpectedCharacter("."))
  }

  @Test("nothing outside the grammar evaluates")
  func refusesGarbage() {
    #expect(error("") == .empty)
    #expect(error("   ") == .empty)
    #expect(error("1 + ") == .unexpectedToken(""))
    #expect(error("1 @ 2") == .unexpectedCharacter("@"))
    #expect(error("2(3 + 4)") == .unexpectedToken("("))
    #expect(error(String(repeating: "1+", count: 400) + "1") == .tooLong)
    #expect(error(String(repeating: "(", count: 60) + "1") == .tooDeep)
  }

  @Test("impossible functions refuse instead of returning a non-number")
  func refusesOutsideDomain() {
    #expect(error("sqrt(-1)") != nil)
    #expect(error("log(0)") != nil)
    #expect(error("ln(-2)") != nil)
    #expect(error("(-8) ^ 0,5") != nil)
  }

  // MARK: What was understood

  @Test("the reading is returned alongside the result")
  func returnsTheReading() throws {
    #expect(try understood("1.234,50*3") == "1234.5 * 3")
    #expect(try understood("240 + 15%") == "240 + 15%")
    #expect(try understood("(2+3)*4") == "(2 + 3) * 4")
    #expect(try understood("2+3*4") == "2 + 3 * 4")
    #expect(try understood("10-(3-2)") == "10 - (3 - 2)")
    #expect(try understood("max(1,5; 2)") == "max(1.5; 2)")
  }

  // MARK: Formatting

  @Test("the result is written the way it is read here")
  func formatsInBrazilianNotation() throws {
    #expect(try formatted("1234,5 + 0,5") == "1.235")
    #expect(try formatted("1000000") == "1.000.000")
    #expect(try formatted("0,1 + 0,2") == "0,3")
    #expect(try formatted("1 / 3") == "0,3333333333")
    #expect(try formatted("0 * 5") == "0")
    #expect(try formatted("0 - 7,5") == "-7,5")
  }

  // MARK: Sums with known answers

  @Test("real sums with answers known in advance")
  func computesRealSums() throws {
    // A 12% tip on a bill of 187,40.
    #expect(try value("187,40 + 12%") == 209.888)
    // Three instalments of 1.234,56.
    #expect(try value("1.234,56 * 3") == 3703.68)
    // Splitting 2.500 between four people.
    #expect(try value("2.500 / 4") == 625)
    // Compound interest: 1% a month for a year.
    let compound = try value("1000 * 1,01 ^ 12")
    #expect(abs(compound - 1126.825030131969) < 1e-9)
    // The average of five marks.
    #expect(try value("(7,5 + 8 + 6,25 + 9 + 5,25) / 5") == 7.2)
    // Rule of three: 3 for 45, how much for 7.
    #expect(try value("45 / 3 * 7") == 105)
  }

  // MARK: The tool wrapper

  @Test("the tool answers with the reading above the result")
  func toolReportsReadingAndResult() {
    let result = EvieCalculatorTool.execute(
      EvieToolCall(
        id: "1",
        name: EvieCalculatorTool.name,
        argumentsJSON: #"{"expression": "1.234 + 15%"}"#
      )
    )

    #expect(!result.isFailure)
    #expect(result.content.contains("Expressão lida: 1234 + 15%"))
    #expect(result.content.contains("Resultado: 1.419,1"))
  }

  @Test("the tool hands back a readable reason instead of a number")
  func toolReportsRefusals() {
    for (expression, fragment) in [
      (#"{"expression": "1/0"}"#, "Divisão por zero"),
      (#"{"expression": "foo(2)"}"#, "Não existe função chamada foo"),
      (#"{"expression": ""}"#, "Faltou a expressão"),
    ] {
      let result = EvieCalculatorTool.execute(
        EvieToolCall(id: "1", name: EvieCalculatorTool.name, argumentsJSON: expression)
      )
      #expect(result.isFailure)
      #expect(result.content.contains(fragment), "faltou \"\(fragment)\" em: \(result.content)")
    }
  }

  @Test("malformed arguments are a refusal rather than a crash")
  func toolSurvivesMalformedArguments() {
    let result = EvieCalculatorTool.execute(
      EvieToolCall(id: "1", name: EvieCalculatorTool.name, argumentsJSON: "not json")
    )

    #expect(result.isFailure)
  }

  @Test("the declared tool matches what the parser accepts")
  func declaresItsOwnGrammar() {
    let definition = EvieCalculatorTool.definition

    #expect(definition.name == "calculate")
    #expect(definition.parameters.map(\.name) == ["expression"])
    let everyParameterIsRequired = definition.parameters.allSatisfy(\.isRequired)
    #expect(everyParameterIsRequired)
    for function in EvieCalculator.unaryFunctions.union(EvieCalculator.variadicFunctions) {
      #expect(
        definition.parameters[0].summary.contains(function),
        "a descrição não cita \(function)"
      )
    }
  }
}
