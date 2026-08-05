import Foundation
import Testing

@testable import EvieCore

@Suite("Evie vault retrieval")
struct EvieVaultRetrievalTests {
  // MARK: - Reading a question

  /// The failure this exists for, measured on the real vault before it was
  /// written. "tenho" survived the stopword list, and because a vault of
  /// technical notes rarely contains first-person verbs, inverse document
  /// frequency gave it a *high* weight — chemistry lessons outranked the note
  /// actually called Cluemed.
  @Test("a question keeps only what it is about")
  func dropsFunctionWords() {
    let terms = EvieQueryTerms.extract(from: "o que eu tenho sobre a Cluemed")

    #expect(terms.contains("cluemed"))
    #expect(!terms.contains("tenho"))
    #expect(!terms.contains("sobre"))
    #expect(!terms.contains("que"))
  }

  /// Portuguese inflects heavily, and matching "cobro" against a note that says
  /// "cobrar" is the difference between finding it and not.
  @Test("verbs are matched by their lemma as well as as written")
  func lemmatises() {
    let terms = EvieQueryTerms.extract(from: "quanto eu cobro pela consultoria")

    #expect(terms.contains("cobrar") || terms.contains("cobro"))
    #expect(terms.contains("consultoria"))
    #expect(!terms.contains("quanto"))
  }

  @Test("plurals reach the singular the note used")
  func normalisesNumber() {
    let terms = EvieQueryTerms.extract(from: "as reuniões com investidores")

    #expect(terms.contains("reuniao") || terms.contains("reunioes"))
    #expect(terms.contains("investidor") || terms.contains("investidores"))
  }

  /// Auxiliaries are grammar however they are conjugated, and the lemma is what
  /// decides.
  @Test("common verbs that carry no subject are dropped")
  func dropsAuxiliaries() {
    let terms = EvieQueryTerms.extract(from: "o que eu preciso fazer para poder ir")

    #expect(!terms.contains("precisar"))
    #expect(!terms.contains("fazer"))
    #expect(!terms.contains("poder"))
  }

  @Test("a question with nothing to search for yields nothing")
  func emptyQuestion() {
    #expect(EvieQueryTerms.extract(from: "").isEmpty)
    #expect(EvieQueryTerms.extract(from: "   ").isEmpty)
  }

  // MARK: - Cutting a note

  @Test("a note keeps the section a passage came from")
  func carriesHeadings() throws {
    let note = """
      # Cluemed

      Uma healthtech.

      ## Captação

      ### Eurofarma

      \(String(repeating: "Conversa sobre aporte. ", count: 24))
      """

    let passages = EvieVaultChunker.chunk(markdown: note, path: "Cluemed.md", rootID: "r")
    let deep = try #require(passages.last)

    #expect(deep.noteTitle == "Cluemed")
    #expect(deep.headingPath.contains("Eurofarma"))
    #expect(deep.breadcrumb.contains("Cluemed › Cluemed › Captação › Eurofarma"))
  }

  /// The breadcrumb is in the searchable text on purpose: a paragraph deep in a
  /// note says "eles" and matches nothing on its own.
  @Test("a passage is searched together with where it sits")
  func searchesWithContext() throws {
    let note = """
      # Cluemed
      ## Captação
      \(String(repeating: "Eles pediram mais informações sobre o valuation. ", count: 12))
      """

    let passage = try #require(
      EvieVaultChunker.chunk(markdown: note, path: "Cluemed.md", rootID: "r").first
    )

    #expect(passage.text.contains("Eles pediram"))
    #expect(passage.searchableText.contains("Cluemed"))
  }

  @Test("a heading closes the passage before it")
  func headingsSplitPassages() {
    let note = """
      ## Primeira
      \(String(repeating: "Texto da primeira seção. ", count: 8))
      ## Segunda
      \(String(repeating: "Texto da segunda seção. ", count: 8))
      """

    let passages = EvieVaultChunker.chunk(markdown: note, path: "n.md", rootID: "r")

    #expect(passages.count >= 2)
    #expect(!passages.contains { $0.text.contains("primeira") && $0.text.contains("segunda") })
  }

  @Test("a heading with nothing under it is not a passage")
  func skipsEmptySections() {
    let passages = EvieVaultChunker.chunk(
      markdown: "# Título\n## Vazia\n## Outra\n",
      path: "n.md",
      rootID: "r"
    )

    #expect(passages.isEmpty)
  }

  /// The links were drawn by the person who wrote the vault, which makes them a
  /// better signal than anything that can be inferred.
  @Test("wikilinks are found, however they were written")
  func readsWikilinks() {
    let links = EvieVaultChunker.links(
      in: "Ver [[Cluemed]], [[Keymatic|a outra empresa]] e [[EU#Objetivos]]."
    )

    #expect(links == ["Cluemed", "Keymatic", "EU"])
  }

  // MARK: - Choosing passages

  /// The fix for the measured failure: a note the person titled after the thing
  /// asked about is about that thing on every line.
  @Test("the note named after the question wins")
  func titleOutranksAMention() {
    let passages = [
      EvieVaultPassage(
        noteTitle: "Aula de química",
        text: "Um exercício qualquer que menciona a Cluemed de passagem.",
        path: "a.md",
        rootID: "r"
      ),
      EvieVaultPassage(
        noteTitle: "Cluemed",
        headingPath: ["Produto"],
        text: "O aplicativo organiza exames por paciente.",
        path: "b.md",
        rootID: "r"
      ),
    ]

    let found = EvieVaultRetriever().retrieve(
      "o que eu tenho sobre a Cluemed",
      from: passages,
      vectors: [],
      limit: 2
    )

    #expect(found.first?.passage.noteTitle == "Cluemed")
  }

  @Test("nothing relevant returns nothing rather than the least bad passage")
  func returnsNothingWhenNothingFits() {
    let passages = [
      EvieVaultPassage(noteTitle: "Química", text: "Estequiometria.", path: "a.md", rootID: "r")
    ]

    #expect(
      EvieVaultRetriever().retrieve("cronograma da obra", from: passages).isEmpty
    )
  }

  @Test("an empty vault is not an error")
  func handlesEmptyVault() {
    #expect(EvieVaultRetriever().retrieve("qualquer coisa", from: []).isEmpty)
  }

  /// Without an embedder it must still work, on words alone.
  @Test("it degrades to word matching rather than failing")
  func worksWithoutEmbeddings() {
    let passages = [
      EvieVaultPassage(noteTitle: "Cluemed", text: "Healthtech.", path: "a.md", rootID: "r")
    ]

    let found = EvieVaultRetriever(embedder: nil).retrieve("Cluemed", from: passages)

    #expect(found.count == 1)
    #expect(found[0].matchedByWords)
    #expect(!found[0].matchedByMeaning)
  }

  /// Fusion has to use ranks rather than scores, because the two rankers are not
  /// on the same scale and never will be.
  @Test("a passage both rankers found beats one only either found")
  func fusionPrefersAgreement() {
    let passages = [
      EvieVaultPassage(noteTitle: "A", text: "contrato de prestação", path: "a.md", rootID: "r"),
      EvieVaultPassage(noteTitle: "B", text: "acordo de serviço", path: "b.md", rootID: "r"),
      EvieVaultPassage(noteTitle: "C", text: "receita de bolo", path: "c.md", rootID: "r"),
    ]
    // An embedder that finds A and B related and C not.
    let found = EvieVaultRetriever(embedder: StubEmbedder()).retrieve(
      "contrato",
      from: passages,
      vectors: [[1, 0], [0.9, 0.1], [0, 1]],
      limit: 2
    )

    #expect(found.first?.passage.noteTitle == "A")
    #expect(found.first?.matchedByWords == true)
  }

  @Test("what she receives names the note each passage came from")
  func describesWithProvenance() {
    let described = EvieVaultRetriever.describe(
      [
        EvieRetrievedPassage(
          passage: EvieVaultPassage(
            noteTitle: "Cluemed",
            headingPath: ["Captação"],
            text: "Conversa com a Eurofarma.",
            path: "Cluemed.md",
            rootID: "r"
          ),
          score: 1
        )
      ],
      query: "cluemed"
    )

    #expect(described.contains("Cluemed › Captação"))
    #expect(described.contains("Eurofarma"))
    // Notes go stale, and a note contradicting what she knows is worth saying
    // out loud rather than resolving silently.
    #expect(described.contains("contradisser"))
  }

  @Test("finding nothing says so")
  func describesEmptiness() {
    #expect(EvieVaultRetriever.describe([], query: "xyz").contains("Não achei"))
  }
}

/// A vector for a question that points the same way as the first passage.
private struct StubEmbedder: EvieSemanticEmbedder {
  func vector(for text: String) -> [Float]? {
    [1, 0]
  }
}
