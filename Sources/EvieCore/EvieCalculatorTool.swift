import Foundation

/// The calculator, as the model is allowed to call it.
///
/// It touches nothing: no disk, no network, no state. That is why it is offered
/// unconditionally rather than behind a switch — a calculator somebody has to
/// turn on is a calculator nobody uses, and there is no privacy question in
/// adding two numbers.
///
/// The description is written the way the file tools' descriptions are: it says
/// *when* to call, not only what it does, and it says the thing the model gets
/// wrong unprompted — that an easy sum is still a sum for the tool.
public enum EvieCalculatorTool {
  public static let name = "calculate"

  public static var definition: EvieToolDefinition {
    EvieToolDefinition(
      name: name,
      summary: """
        Faz contas. Use SEMPRE que a resposta depender de um número calculado — \
        soma, subtração, multiplicação, divisão, porcentagem, média, diferença \
        entre valores, regra de três — inclusive quando a conta parecer fácil. \
        Nunca faça a conta de cabeça: mande a expressão para cá e use o resultado \
        que voltar. Devolve a expressão como foi lida e o resultado; quando a \
        conta não tem resultado, devolve o motivo em vez de um número.
        """,
      parameters: [
        EvieToolParameter(
          name: "expression",
          type: .string,
          summary: """
            Só a conta, sem texto em volta. Vírgula ou ponto decimal (1234,56 ou \
            1234.56). Operadores + - * / ^ e %, parênteses, e as funções sqrt, \
            abs, round, floor, ceil, log, ln, sin, cos, tan, min e max — min e \
            max separam os valores com ponto e vírgula: max(1,5; 2). \
            Porcentagem: "15% * 240", "240 + 15%", "240 - 15%".
            """,
          isRequired: true
        )
      ]
    )
  }

  /// Runs one call. Never throws: a refusal the model can read is worth more
  /// than an exception, exactly as with the file tools.
  public static func execute(_ call: EvieToolCall) -> EvieToolResult {
    let arguments: [String: String]
    do {
      arguments = try call.arguments()
    } catch {
      return failure(call, "Os argumentos vieram malformados. Tente de novo, com JSON válido.")
    }

    guard let expression = arguments["expression"], !expression.isEmpty else {
      return failure(call, "Faltou a expressão. Mande a conta em `expression`.")
    }

    do {
      let calculation = try EvieCalculator.evaluate(expression)
      return EvieToolResult(
        callID: call.id,
        name: call.name,
        // The reading comes first because it is what has to be checked. If
        // "1.234" was read as 1234 and that is wrong, the result below it is
        // wrong too, and a result on its own would hide the reason.
        content: """
          Expressão lida: \(calculation.understood)
          Resultado: \(calculation.formattedValue)
          """
      )
    } catch let error as EvieCalculatorError {
      return failure(
        call,
        (error.errorDescription ?? "Essa conta não pôde ser feita.")
          + " Corrija a expressão e chame de novo, ou diga ao Matheus por que a conta não sai."
      )
    } catch {
      return failure(call, "Essa conta não pôde ser feita.")
    }
  }

  static func failure(_ call: EvieToolCall, _ message: String) -> EvieToolResult {
    EvieToolResult(callID: call.id, name: call.name, content: message, isFailure: true)
  }
}
