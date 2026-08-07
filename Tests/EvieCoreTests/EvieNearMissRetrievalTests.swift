import Testing

@testable import EvieCore

/// Two defects measured on 2026-08-07, both of which made her answer "não
/// encontrei nenhuma menção" about a company the vault has a folder for.
@Suite("Near-miss retrieval and brevity preambles")
struct EvieNearMissRetrievalTests {
  private func passage(_ title: String, _ text: String) -> EvieVaultPassage {
    EvieVaultPassage(
      noteTitle: title,
      headingPath: [],
      text: text,
      path: "/\(title).md",
      rootID: "root"
    )
  }

  // MARK: - The near miss

  @Test("a term one letter wrong still finds the notes")
  func recoversFromASingleWrongLetter() {
    let passages = [
      passage("Cluemed", "A Cluemed é o cofre de saúde do paciente."),
      passage("Keymatic", "A Keymatic é uma plataforma de atendimento."),
    ]
    // `cluumed` is not a typo anybody made: it is what the model returns when
    // asked to repeat `cluemed`, and what it sent to the search tool.
    let found = EvieVaultRetriever().retrieve("cluumed", from: passages)

    #expect(found.contains { $0.passage.noteTitle == "Cluemed" })
  }

  @Test("a search that already works is not second-guessed")
  func leavesASuccessfulSearchAlone() {
    let passages = [
      passage("Cluemed", "A Cluemed é o cofre de saúde do paciente."),
      passage("Cluemed Paciente", "O app do paciente."),
    ]
    let found = EvieVaultRetriever().retrieve("cluemed", from: passages)

    #expect(found.allSatisfy { $0.passage.noteTitle.contains("Cluemed") })
  }

  @Test("a genuinely absent term stays absent")
  func doesNotInventAMatch() {
    let passages = [passage("Cluemed", "A Cluemed é o cofre de saúde do paciente.")]

    #expect(EvieVaultRetriever().retrieve("helicóptero", from: passages).isEmpty)
  }

  @Test("short words are not corrected, because one edit is most of them")
  func leavesShortWordsAlone() {
    // "casa" and "cara" differ by one letter and are different words. Correcting
    // between them would be worse than finding nothing.
    #expect(EvieNearestTerm.nearest(to: "casa", in: ["a cara dele"]) == nil)
  }

  @Test("the most common near neighbour wins")
  func prefersTheCommonestNeighbour() {
    let corpus = ["cluemed cluemed cluemed", "cluemedx apareceu uma vez"]

    #expect(EvieNearestTerm.nearest(to: "cluumed", in: corpus) == "cluemed")
  }

  @Test("one insertion, one deletion and one substitution all count as near")
  func recognisesTheThreeEdits() {
    #expect(EvieNearestTerm.isWithinOneEdit(Array("cluumed"), Array("cluemed")))
    #expect(EvieNearestTerm.isWithinOneEdit(Array("cluemd"), Array("cluemed")))
    #expect(EvieNearestTerm.isWithinOneEdit(Array("cluemedd"), Array("cluemed")))
    #expect(!EvieNearestTerm.isWithinOneEdit(Array("cluemed"), Array("cluemed")))
    #expect(!EvieNearestTerm.isWithinOneEdit(Array("cluuumd"), Array("cluemed")))
  }

  // MARK: - The brevity preamble

  @Test("asking for a short answer is recognised, wherever it is punctuated")
  func recognisesBrevityOpenings() {
    #expect(EvieBrevityPreamble.opening(of: "em uma frase, o que é a cluemed?") != nil)
    #expect(EvieBrevityPreamble.opening(of: "Em Uma Frase: o que é isso") != nil)
    #expect(EvieBrevityPreamble.opening(of: "  — resumidamente, me explica") != nil)
    #expect(EvieBrevityPreamble.opening(of: "Rapidamente: quanto é 2+2") != nil)
  }

  @Test("it is only an opening, never a phrase in the middle")
  func doesNotMatchMidSentence() {
    // A statement about something else, not an instruction about this answer.
    #expect(EvieBrevityPreamble.opening(of: "a resposta cabe em uma frase?") == nil)
    #expect(EvieBrevityPreamble.opening(of: "o que é a cluemed?") == nil)
  }

  @Test("the question itself is never rewritten")
  func leavesTheQuestionIntact() {
    let question = "em uma frase, o que é a cluemed?"
    let annotated = EvieBrevityPreamble.annotated(question)

    #expect(annotated.hasPrefix(question))
    #expect(annotated.contains("Procure primeiro"))
  }

  @Test("a question with no preamble is passed through untouched")
  func addsNothingWhenNotAsked() {
    let question = "o que é a cluemed?"

    #expect(EvieBrevityPreamble.annotated(question) == question)
  }
}
