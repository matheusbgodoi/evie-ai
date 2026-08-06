import Foundation

/// What she is asked at each stage of a plan.
///
/// Every one of these is a **user** turn, not a system or developer one, and
/// that is not a style choice. Measured against the server this project runs:
/// guidance sent with the `developer` role after a conversation has started is
/// refused outright. The instruction has to arrive the same way a person's words
/// arrive or it does not arrive at all.
public enum EviePlanPrompts {
  /// How much of an earlier finding a later step is given.
  ///
  /// The reason there is a budget at all is a shape in the measurements rather
  /// than a worry: across one five-step run the steps took 42.5, 49.6, 65.0,
  /// 72.7 and 75.4 seconds. They slow down because each one carries every
  /// earlier finding in full, so the prompt grows and generation with it.
  ///
  /// A later step does not need the earlier answer, it needs to know what ground
  /// was already covered — so it gets the opening of it, which is where a model
  /// puts its substance. The synthesis pass, which actually writes from the
  /// findings, still receives every one of them whole.
  ///
  /// Re-measured on the same question afterwards: 34.7, 40.2 and 51.2 seconds
  /// against 42.5, 49.6 and 65.0 for the same work — 126.1 s of steps against
  /// 157.1 s. The curve still rises, because 400 characters is still something,
  /// but the step-to-step growth roughly halved. If it ever matters again, the
  /// next cut is carrying only the most recent finding rather than all of them.
  public static let maximumCarriedCharacters = 400

  /// The opening of a finding, cut at a sentence rather than mid-word.
  static func condensed(_ text: String, to budget: Int = maximumCarriedCharacters) -> String {
    guard text.count > budget else {
      return text
    }
    let head = text.prefix(budget)
    // Only honoured when it lands past the halfway mark; an early full stop —
    // "1." at the top of a list — would otherwise cut the finding to nothing.
    if let stop = head.lastIndex(where: { ".!?\n".contains($0) }),
      head.distance(from: head.startIndex, to: stop) > budget / 2
    {
      return String(head[head.startIndex...stop]) + " […]"
    }
    return String(head) + "…"
  }

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

    A última etapa NÃO pode ser "concluir", "recomendar" ou "responder": a \
    resposta final é escrita depois, a partir do que as etapas acharem. Uma \
    etapa que só conclui gasta um minuto refazendo o que vem em seguida.

    Use o menor número de etapas que resolva. Cada etapa custa quase um minuto.
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
        // Condensed, not whole: this is orientation, and the pass that writes
        // from the findings gets them in full.
        prompt += "\n\(position + 1). \(finding.instruction)\n\(condensed(finding.result))\n"
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
