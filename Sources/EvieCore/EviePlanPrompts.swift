import Foundation

/// What she is asked at each stage of a plan.
///
/// Every one of these is a **user** turn, not a system or developer one, and
/// that is not a style choice. Measured against the server this project runs:
/// guidance sent with the `developer` role after a conversation has started is
/// refused outright. The instruction has to arrive the same way a person's words
/// arrive or it does not arrive at all.
public enum EviePlanPrompts {
  /// Asks for the plan itself.
  ///
  /// The format is spelled out rather than left to the model, because the parser
  /// has to read it back and a plan that fails to parse costs the whole call.
  /// The step count is bounded in the prompt *and* in the parser: the prompt is
  /// a request, and a request is not a guarantee.
  public static func planning(for question: String) -> String {
    """
    Antes de responder, divida esta tarefa em etapas:

    \(question)

    Responda APENAS com uma lista numerada de \(EviePlanParser.minimumSteps) a \
    \(EviePlanParser.maximumSteps) etapas, uma por linha, no formato "1. ...". \
    Sem introdução, sem conclusão, sem explicação.

    Cada etapa deve ser uma ação concreta e verificável — buscar algo específico \
    nas anotações, pesquisar algo específico na web, comparar dois resultados. \
    Não escreva etapas como "entender o problema" ou "pensar sobre o assunto", \
    que não produzem nada que a etapa seguinte possa usar.
    """
  }

  /// Asks for one step to be carried out.
  ///
  /// The findings so far are included as text rather than left in the
  /// conversation, so a step cannot quietly depend on something further back
  /// that later got trimmed to fit the context window.
  public static func step(
    _ index: Int,
    of plan: EviePlan
  ) -> String {
    let step = plan.steps[index]
    var prompt = """
      Estamos executando um plano para responder: \(plan.question)

      Etapa \(index + 1) de \(plan.steps.count): \(step.instruction)
      """

    let findings = plan.findings
    if !findings.isEmpty {
      prompt += "\n\nO que as etapas anteriores acharam:\n"
      for (position, finding) in findings.enumerated() {
        prompt += "\n\(position + 1). \(finding.instruction)\n\(finding.result)\n"
      }
    }

    prompt += """


      Faça só esta etapa. Responda com o que você achou, direto, sem introdução \
      e sem repetir o que já foi achado antes. Se não achar nada, diga que não \
      achou — uma etapa vazia é um resultado, e inventar para preencher \
      estraga as etapas seguintes.
      """
    return prompt
  }

  /// Asks for the answer the person actually reads.
  ///
  /// Separate from the last step on purpose. A step that both does its own work
  /// and writes the final answer does neither well, and the person would be
  /// reading the tail of a research note instead of a reply.
  public static func synthesis(for plan: EviePlan) -> String {
    var prompt = """
      Agora responda à pergunta original usando só o que as etapas acharam.

      Pergunta: \(plan.question)

      """

    for (position, finding) in plan.findings.enumerated() {
      prompt += "\n\(position + 1). \(finding.instruction)\n\(finding.result)\n"
    }

    let unfinished = plan.steps.filter {
      if case .failed = $0.state { return true }
      if case .cancelled = $0.state { return true }
      return false
    }
    if !unfinished.isEmpty {
      // Named rather than hidden. An answer built on half a plan is still worth
      // having; one that does not say it was built on half a plan is not.
      prompt += "\n\nEstas etapas não foram concluídas:\n"
      for step in unfinished {
        prompt += "- \(step.instruction)\n"
      }
      prompt += "\nDiga no final que a resposta está incompleta por causa delas."
    }

    prompt += """


      Responda direto, como se estivesse conversando. Não descreva o plano nem \
      numere as etapas — ele já apareceu na tela e repetir só faz a resposta \
      ficar mais longa do que precisa.
      """
    return prompt
  }
}
