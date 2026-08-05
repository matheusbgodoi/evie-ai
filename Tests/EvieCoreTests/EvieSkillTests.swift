import Foundation
import Testing

@testable import EvieCore

@Suite("Evie skills")
struct EvieSkillTests {
  // MARK: - Reading a file somebody wrote

  @Test("reads a skill with frontmatter")
  func parsesFrontmatter() throws {
    let file = """
      ---
      nome: Revisar contrato
      quando: contrato, cláusula, rescisão, multa
      ---

      Ao revisar um contrato, comece pelas cláusulas de saída.
      """

    let skill = try #require(EvieSkill.parse(file, fileName: "revisar-contrato.md"))

    #expect(skill.name == "Revisar contrato")
    #expect(skill.when.contains("rescisão"))
    #expect(skill.instructions.hasPrefix("Ao revisar"))
  }

  /// A skill that silently fails to load because a key was written in the other
  /// language is worse than four lines of leniency.
  @Test("the keys are accepted in either language")
  func acceptsBothLanguages() throws {
    let english = """
      ---
      name: Weekly review
      when: retrospectiva, semana
      ---

      Comece listando o que ficou pendente.
      """

    let skill = try #require(EvieSkill.parse(english, fileName: "weekly.md"))
    #expect(skill.name == "Weekly review")
    #expect(skill.when.contains("retrospectiva"))
  }

  @Test("a file with no frontmatter is still a skill, named after itself")
  func toleratesMissingFrontmatter() throws {
    let skill = try #require(
      EvieSkill.parse("Faça assim e assado.", fileName: "preparar-reuniao.md")
    )

    #expect(skill.name == "preparar-reuniao")
    // With no triggers written, the name is the trigger — better than a skill
    // that can never load.
    #expect(skill.when == "preparar-reuniao")
  }

  @Test("an empty file is not a skill")
  func refusesEmptyFiles() {
    #expect(EvieSkill.parse("", fileName: "vazio.md") == nil)
    #expect(EvieSkill.parse("---\nnome: x\n---\n\n   ", fileName: "vazio.md") == nil)
  }

  /// Everything loaded is paid for in the prompt of the turn that loaded it.
  @Test("a skill longer than the ceiling is cut, not refused")
  func boundsLength() throws {
    let huge = "---\nnome: x\n---\n\n" + String(repeating: "instrução. ", count: 5_000)

    let skill = try #require(EvieSkill.parse(huge, fileName: "x.md"))
    #expect(skill.instructions.count <= EvieSkill.maximumInstructionCharacters)
  }

  @Test("what is written can be read back")
  func roundTrips() throws {
    let original = EvieSkill(
      id: "a.md",
      name: "Preparar reunião",
      when: "reunião, pauta",
      instructions: "Junte a pauta e os pendentes.",
      fileName: "a.md"
    )

    let reread = try #require(EvieSkill.parse(original.markdown(), fileName: "a.md"))
    #expect(reread.name == original.name)
    #expect(reread.when == original.when)
    #expect(reread.instructions == original.instructions)
  }

  @Test("a name becomes a safe file name")
  func makesSafeFileNames() {
    #expect(EvieSkill.fileName(for: "Revisar contrato") == "revisar-contrato.md")
    #expect(EvieSkill.fileName(for: "Reunião 1:1") == "reuniao-1-1.md")
    #expect(!EvieSkill.fileName(for: "../../etc/passwd").contains("/"))
    #expect(!EvieSkill.fileName(for: "").isEmpty)
  }

  // MARK: - Deciding which one loads

  @Test("a question loads the skill it is about")
  func matchesTheRightSkill() {
    let skills = [
      skill("Revisar contrato", when: "contrato, cláusula, rescisão"),
      skill("Preparar reunião", when: "reunião, pauta, agenda"),
      skill("Escrever commit", when: "commit, git, mensagem de commit"),
    ]

    let matched = EvieSkillLibrary.matching(
      "me ajuda a revisar esse contrato, olha a cláusula de rescisão",
      in: skills
    )

    #expect(matched.first?.name == "Revisar contrato")
  }

  /// A skill that loads when it should not puts instructions in front of her for
  /// a job she is not doing, and she will follow them. That is worse than a
  /// missed match.
  @Test("an unrelated question loads nothing")
  func doesNotMatchLoosely() {
    let skills = [
      skill("Revisar contrato", when: "contrato, cláusula, rescisão"),
      skill("Preparar reunião", when: "reunião, pauta, agenda"),
    ]

    #expect(EvieSkillLibrary.matching("qual a capital da França?", in: skills).isEmpty)
    #expect(EvieSkillLibrary.matching("quanto é 17 vezes 4?", in: skills).isEmpty)
  }

  @Test("a switched-off skill never loads")
  func respectsTheSwitch() {
    var off = skill("Revisar contrato", when: "contrato, cláusula, rescisão")
    off.isEnabled = false

    #expect(EvieSkillLibrary.matching("revisar o contrato e a cláusula", in: [off]).isEmpty)
  }

  @Test("no more than a couple load at once")
  func boundsHowManyLoad() {
    let many = (0..<10).map { skill("Skill \($0)", when: "contrato, cláusula, rescisão") }

    #expect(
      EvieSkillLibrary.matching("contrato cláusula rescisão", in: many).count
        <= EvieSkillLibrary.maximumLoaded
    )
  }

  /// Two skills together must not be able to fill the prompt.
  @Test("the loaded skills stay inside a character budget")
  func boundsTotalSize() {
    let big = (0..<4).map { index in
      EvieSkill(
        id: "\(index)",
        name: "Skill \(index)",
        when: "contrato, cláusula",
        instructions: String(repeating: "x", count: 3_800)
      )
    }

    let loaded = EvieSkillLibrary.matching("contrato cláusula", in: big)
    let total = loaded.reduce(0) { $0 + $1.instructions.count }
    #expect(total <= EvieSkillLibrary.characterBudget)
  }

  @Test("a word every skill shares does not decide the match")
  func commonWordsCountForLess() {
    let skills = [
      skill("Contrato", when: "arquivo, contrato"),
      skill("Fotos", when: "arquivo, foto, imagem"),
      skill("Notas", when: "arquivo, nota, anotação"),
    ]

    let matched = EvieSkillLibrary.matching("organiza minhas fotos e imagens", in: skills)

    #expect(matched.first?.name == "Fotos")
  }

  // MARK: - What she is told

  @Test("loaded skills arrive as instructions she may set aside")
  func guidanceIsOverridable() throws {
    let guidance = try #require(
      EvieSkillLibrary.guidance(for: [skill("Revisar contrato", when: "contrato")])
    )

    #expect(guidance.contains("Revisar contrato"))
    // Instructions that cannot be set aside when they do not fit are how a skill
    // about contracts derails a question that merely mentioned one.
    #expect(guidance.contains("ignore-as"))
  }

  @Test("nothing matched produces no block at all")
  func silentWhenNothingMatches() {
    #expect(EvieSkillLibrary.guidance(for: []) == nil)
  }

  // MARK: - Her proposing one

  @Test("the tool that proposes a skill installs nothing")
  func theToolOnlyProposes() {
    #expect(EvieSkillTool.definition.name == "propose_skill")
    #expect(EvieSkillTool.definition.summary.contains("NÃO instala nada"))
  }

  @Test("a proposal becomes a skill")
  func readsAProposal() throws {
    let call = EvieToolCall(
      id: "c1",
      name: "propose_skill",
      argumentsJSON: """
        {"nome":"Revisar contrato","quando":"contrato, cláusula","instrucoes":"Comece pelas saídas."}
        """
    )

    let skill = try #require(EvieSkillTool.skill(from: call))
    #expect(skill.name == "Revisar contrato")
    #expect(skill.fileName == "revisar-contrato.md")
  }

  @Test("a proposal without instructions is refused")
  func refusesEmptyProposal() {
    let call = EvieToolCall(
      id: "c1",
      name: "propose_skill",
      argumentsJSON: #"{"nome":"x","quando":"y","instrucoes":"  "}"#
    )

    #expect(EvieSkillTool.skill(from: call) == nil)
  }
}

extension EvieSkillTests {
  fileprivate func skill(_ name: String, when: String) -> EvieSkill {
    EvieSkill(
      id: name,
      name: name,
      when: when,
      instructions: "Instruções de \(name).",
      fileName: "\(name).md"
    )
  }
}
