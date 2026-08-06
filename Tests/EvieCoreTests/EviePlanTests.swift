import Foundation
import Testing

@testable import EvieCore

@Suite("Evie plans")
struct EviePlanTests {
  // MARK: - Recognising the command

  @Test("the command carries the question")
  func readsTheQuestion() {
    #expect(
      EviePlanCommand.question(in: "/plano compare a Cluemed com a concorrência")
        == "compare a Cluemed com a concorrência"
    )
    #expect(EviePlanCommand.question(in: "  /PLANO   me ajuda  ") == "me ajuda")
  }

  @Test("the command with nothing to plan is still the command")
  func acceptsBareCommand() {
    #expect(EviePlanCommand.question(in: "/plano") == "")
    #expect(EviePlanCommand.question(in: "  /plano  ") == "")
  }

  /// A plan costs minutes on this hardware, so it must never start because a
  /// word happened to appear.
  @Test("ordinary questions are not the command")
  func doesNotFireOnProse() {
    #expect(EviePlanCommand.question(in: "/planos de saúde valem a pena?") == nil)
    #expect(EviePlanCommand.question(in: "meu /plano é esse") == nil)
    #expect(EviePlanCommand.question(in: "qual o plano?") == nil)
    #expect(EviePlanCommand.question(in: "") == nil)
  }

  // MARK: - Reading a plan

  @Test("a numbered list becomes steps")
  func parsesNumberedList() throws {
    let steps = try EviePlanParser.steps(
      in: """
        1. Buscar o que já existe nas anotações sobre a Cluemed
        2. Pesquisar concorrentes na web
        3. Comparar e apontar as diferenças
        """
    )

    #expect(steps.count == 3)
    #expect(steps[0].instruction == "Buscar o que já existe nas anotações sobre a Cluemed")
    #expect(steps[2].instruction == "Comparar e apontar as diferenças")
  }

  /// A local model writes the list a different way every time, and a plan that
  /// fails to parse is a minute of work thrown away.
  @Test("the list is read however the model chose to write it")
  func toleratesFormatting() throws {
    for text in [
      "1) Primeira coisa a fazer\n2) Segunda coisa a fazer",
      "- Primeira coisa a fazer\n- Segunda coisa a fazer",
      "**1.** Primeira coisa a fazer\n**2.** Segunda coisa a fazer",
      "• Primeira coisa a fazer\n• Segunda coisa a fazer",
      "1 - Primeira coisa a fazer\n2 - Segunda coisa a fazer",
    ] {
      let steps = try EviePlanParser.steps(in: text)
      #expect(steps.count == 2, "não leu: \(text)")
      #expect(steps[0].instruction == "Primeira coisa a fazer")
    }
  }

  /// Models introduce their lists, and the introduction is not step one.
  @Test("a preamble is not a step")
  func ignoresPreamble() throws {
    let steps = try EviePlanParser.steps(
      in: """
        Claro! Aqui está o plano:

        1. Levantar os números do trimestre
        2. Comparar com o trimestre anterior

        Posso começar?
        """
    )

    #expect(steps.count == 2)
    #expect(steps[0].instruction == "Levantar os números do trimestre")
  }

  /// One step is a question. Answering it directly costs one model call instead
  /// of four.
  @Test("a plan with one step is refused rather than run")
  func refusesSingleStep() {
    #expect(throws: (any Error).self) {
      try EviePlanParser.steps(in: "1. Só responder a pergunta")
    }
    #expect(throws: (any Error).self) {
      try EviePlanParser.steps(in: "não sei como dividir isso")
    }
  }

  /// Each step is a full turn, so the ceiling is about the person's evening.
  @Test("a rambling plan is cut to a length worth waiting for")
  func capsSteps() throws {
    let text = (1...20).map { "\($0). Etapa número \($0) do plano" }.joined(separator: "\n")

    #expect(try EviePlanParser.steps(in: text).count == EviePlanParser.maximumSteps)
  }

  @Test("prose that escaped the list is not a step")
  func rejectsRunawayLines() {
    #expect(EviePlanParser.instruction(in: "1. \(String(repeating: "palavra ", count: 60))") == nil)
    #expect(EviePlanParser.instruction(in: "1.") == nil)
    #expect(EviePlanParser.instruction(in: "Plano:") == nil)
    #expect(EviePlanParser.instruction(in: "2024. Foi um ano difícil") == nil)
  }

  // MARK: - Following a run

  @Test("a plan knows when it has stopped")
  func tracksCompletion() {
    var plan = EviePlan(
      question: "q",
      steps: [EviePlanStep(instruction: "a"), EviePlanStep(instruction: "b")]
    )
    #expect(!plan.isFinished)

    plan.steps[0].state = .done("primeiro achado")
    #expect(!plan.isFinished)

    // Cancelled counts as finished, and stays distinguishable from failed: one
    // is the person changing their mind, the other is something going wrong.
    plan.steps[1].state = .cancelled
    #expect(plan.isFinished)
    #expect(plan.findings.count == 1)
    #expect(plan.findings[0].result == "primeiro achado")
  }
}

@Suite("Evie plan prompts")
struct EviePlanPromptTests {
  private func plan() -> EviePlan {
    EviePlan(
      question: "a Cluemed atende médicos?",
      steps: [
        EviePlanStep(instruction: "Buscar nas anotações", state: .done("Atende pacientes.")),
        EviePlanStep(instruction: "Pesquisar na web", state: .failed("sem rede")),
        EviePlanStep(instruction: "Comparar"),
      ]
    )
  }

  @Test("the planning prompt states the bounds the parser will enforce")
  func planningStatesBounds() {
    let prompt = EviePlanPrompts.planning(for: "compare X e Y")

    #expect(prompt.contains("compare X e Y"))
    #expect(prompt.contains("\(EviePlanParser.minimumSteps)"))
    #expect(prompt.contains("\(EviePlanParser.maximumSteps)"))
  }

  /// Carried as text rather than left in the conversation, so a step cannot
  /// quietly depend on something that was later trimmed to fit the context.
  @Test("a step carries what the earlier steps found")
  func stepCarriesFindings() {
    let prompt = EviePlanPrompts.step(2, of: plan())

    #expect(prompt.contains("Comparar"))
    #expect(prompt.contains("Atende pacientes."))
    #expect(prompt.contains("Etapa 3 de 3"))
  }

  @Test("the first step carries no findings because there are none")
  func firstStepHasNoFindings() {
    var starting = plan()
    starting.steps[0].state = .pending
    starting.steps[1].state = .pending

    #expect(!EviePlanPrompts.step(0, of: starting).contains("etapas anteriores"))
  }

  /// An answer built on half a plan is worth having. One that does not say it
  /// was built on half a plan is not.
  @Test("an incomplete run is named in the answer, not hidden")
  func synthesisNamesWhatIsMissing() {
    let prompt = EviePlanPrompts.synthesis(for: plan())

    #expect(prompt.contains("Atende pacientes."))
    #expect(prompt.contains("Pesquisar na web"))
    #expect(prompt.contains("incompleta"))
  }

  @Test("a plan that finished says nothing about being incomplete")
  func synthesisStaysQuietWhenWhole() {
    var whole = plan()
    whole.steps[1].state = .done("nada relevante")
    whole.steps[2].state = .done("são diferentes")

    #expect(!EviePlanPrompts.synthesis(for: whole).contains("incompleta"))
  }
}

@Suite("Evie plan progress")
struct EviePlanProgressTests {
  /// The thing a person stares at for minutes, so how far along it is is worth
  /// a test rather than a glance.
  @Test("every state is distinguishable on screen")
  func reportsEachState() {
    let plan = EviePlan(
      question: "q",
      steps: [
        EviePlanStep(instruction: "feita", state: .done("x")),
        EviePlanStep(instruction: "rodando", state: .running),
        EviePlanStep(instruction: "falhou", state: .failed("sem rede")),
        EviePlanStep(instruction: "parada", state: .cancelled),
        EviePlanStep(instruction: "esperando"),
      ]
    )
    let report = plan.progressReport
    let lines = report.split(separator: "\n").map(String.init)

    #expect(lines.count == 5)
    #expect(lines[0].hasPrefix("●"))
    #expect(lines[1].hasPrefix("◐"))
    // A step that failed says so where it failed, rather than at the end.
    #expect(lines[2].contains("sem rede"))
    #expect(lines[3].contains("parado"))
    #expect(lines[4].hasPrefix("○"))
    #expect(lines[0].contains("1."))
    #expect(lines[4].contains("5."))
  }
}

@Suite("Evie plan cost")
struct EviePlanCostTests {
  /// The shape that made this necessary: across one five-step run the steps took
  /// 42.5, 49.6, 65.0, 72.7 and 75.4 seconds, because each carried every earlier
  /// finding whole.
  @Test("a later step gets the opening of an earlier finding, not all of it")
  func condensesCarriedFindings() {
    let long = String(repeating: "Uma frase razoavelmente longa sobre o assunto. ", count: 40)
    let plan = EviePlan(
      question: "q",
      steps: [
        EviePlanStep(instruction: "primeira", state: .done(long)),
        EviePlanStep(instruction: "segunda"),
      ]
    )

    let stepPrompt = EviePlanPrompts.step(1, of: plan)
    #expect(stepPrompt.count < long.count)
    #expect(stepPrompt.contains("Uma frase razoavelmente longa"))
  }

  /// The pass that actually writes from the findings still gets them whole.
  @Test("the answer is written from the findings in full")
  func synthesisKeepsEverything() {
    let long = String(repeating: "Detalhe importante que não pode sumir. ", count: 40)
    let plan = EviePlan(
      question: "q",
      steps: [EviePlanStep(instruction: "primeira", state: .done(long))]
    )

    #expect(EviePlanPrompts.synthesis(for: plan).contains(long))
  }

  @Test("a finding is cut at a sentence, not mid-word")
  func cutsAtASentence() {
    let text = "Primeira frase completa. " + String(repeating: "palavra ", count: 200)
    let cut = EviePlanPrompts.condensed(text, to: 100)

    #expect(cut.count <= 110)
    #expect(cut.contains("Primeira frase completa."))
  }

  /// An early full stop must not cut a finding down to nothing.
  @Test("a finding that opens with a short sentence is not cut to it")
  func doesNotCutToAlmostNothing() {
    let text = "Sim. " + String(repeating: "conteúdo que importa de verdade ", count: 50)
    let cut = EviePlanPrompts.condensed(text, to: 200)

    #expect(cut.count > 100)
    #expect(cut.contains("conteúdo que importa"))
  }

  @Test("something already short is left alone")
  func leavesShortFindingsWhole() {
    #expect(EviePlanPrompts.condensed("Curto.") == "Curto.")
  }

  /// The step that only concludes spent a minute redoing what the synthesis pass
  /// does next.
  @Test("the planner is told not to end with a concluding step")
  func forbidsAConcludingStep() {
    let prompt = EviePlanPrompts.planning(for: "qualquer coisa")

    #expect(prompt.contains("NÃO pode ser"))
    #expect(prompt.contains("concluir"))
  }
}
