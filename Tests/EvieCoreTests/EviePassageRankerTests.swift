import Foundation
import Testing

@testable import EvieCore

@Suite("Evie passage ranking")
struct EviePassageRankerTests {
  /// The case this replaces: the answer is not at the top of the page.
  @Test("the passage that answers wins, wherever it sits in the page")
  func findsTheAnswerDeepInThePage() {
    let passages = [
      passage("Início Sobre Contato Assine nossa newsletter e receba novidades."),
      passage("Este site usa cookies para melhorar sua experiência de navegação."),
      passage("Sobre o autor: escreve sobre tecnologia desde 2010 e adora café."),
      passage(
        "O HTTP/3 abandona o TCP e passa a usar o QUIC, que roda sobre UDP. "
          + "Isso elimina o bloqueio de cabeça de fila que o TCP impõe ao HTTP/2."
      ),
      passage("Leia também: os dez melhores frameworks de 2026."),
    ]

    let ranked = EviePassageRanker.rank(passages, for: "diferença entre HTTP/2 e HTTP/3", limit: 2)

    #expect(ranked.first?.text.contains("QUIC") == true)
  }

  /// Plain BM25 prefers a passage that repeats one query word many times. For
  /// answering a question, one that contains all of them is almost always better.
  @Test("covering more of the question beats repeating one word of it")
  func coverageBeatsRepetition() {
    let repetitive = passage(
      "QUIC QUIC QUIC. O QUIC é QUIC e o QUIC faz QUIC com QUIC sempre QUIC."
    )
    let complete = passage(
      "O QUIC substitui o TCP no HTTP/3 e resolve o bloqueio de cabeça de fila."
    )

    let ranked = EviePassageRanker.rank(
      [repetitive, complete],
      for: "QUIC TCP HTTP/3 bloqueio",
      limit: 2
    )

    #expect(ranked.first?.text == complete.text)
  }

  /// Search results copy each other. Three paraphrases look like three sources
  /// agreeing and are one, and they crowd out whatever would have added
  /// something.
  @Test("the same paragraph from three sites is kept once")
  func removesNearDuplicates() {
    let text = "O HTTP/3 usa QUIC sobre UDP em vez do TCP usado pelo HTTP/2."
    let passages = [
      EvieWebPassage(text: text, source: "https://a.com"),
      EvieWebPassage(text: text + " Isso melhora a latência.", source: "https://b.com"),
      EvieWebPassage(text: text, source: "https://c.com"),
      EvieWebPassage(
        text: "A migração de conexão permite trocar de rede sem derrubar a sessão QUIC.",
        source: "https://d.com"
      ),
    ]

    let ranked = EviePassageRanker.rank(passages, for: "HTTP/3 QUIC TCP rede", limit: 4)

    #expect(ranked.count <= 3)
    #expect(ranked.contains { $0.text.contains("migração") })
  }

  @Test("a passage that matches nothing is dropped rather than padded in")
  func dropsIrrelevantPassages() {
    let passages = [
      passage("O QUIC roda sobre UDP."),
      passage("Receita de bolo de cenoura com cobertura de chocolate."),
    ]

    let ranked = EviePassageRanker.rank(passages, for: "QUIC UDP", limit: 6)

    #expect(ranked.count == 1)
  }

  @Test("words that appear in every sentence do not decide the ranking")
  func ignoresStopWords() {
    let terms = EviePassageRanker.terms(in: "Qual é a diferença entre o HTTP e o QUIC?")

    #expect(terms.contains("diferenca"))
    #expect(terms.contains("http"))
    #expect(terms.contains("quic"))
    #expect(!terms.contains("qual"))
    #expect(!terms.contains("entre"))
  }

  @Test("accents in the question still match text without them")
  func foldsAccents() {
    let ranked = EviePassageRanker.rank(
      [passage("A latência do protocolo caiu pela metade na migração.")],
      for: "latencia migracao",
      limit: 1
    )

    #expect(ranked.count == 1)
  }

  @Test("nothing to rank returns nothing rather than failing")
  func handlesEmptyInput() {
    #expect(EviePassageRanker.rank([], for: "algo").isEmpty)
    #expect(EviePassageRanker.rank([passage("texto")], for: "").count == 1)
  }

  @Test("never returns more than asked for")
  func respectsTheLimit() {
    let many = (0..<40).map { passage("O QUIC e o TCP diferem no ponto número \($0).") }

    #expect(EviePassageRanker.rank(many, for: "QUIC TCP", limit: 5).count <= 5)
  }

  // MARK: - What the model receives

  /// A citation next to the claim is checkable; a list of sites at the bottom is
  /// not.
  @Test("every passage carries the address it came from")
  func describesWithSources() {
    let described = EvieWebPassages.describe(
      [
        EvieWebPassage(text: "primeiro trecho", source: "https://a.com/x"),
        EvieWebPassage(text: "segundo trecho", source: "https://b.org/y"),
      ],
      query: "algo"
    )

    #expect(described.contains("https://a.com/x"))
    #expect(described.contains("https://b.org/y"))
    #expect(described.contains("primeiro trecho"))
  }

  /// Two sources disagreeing is information, not a problem to hide by picking
  /// one.
  @Test("she is told to report a contradiction rather than choose")
  func tellsHerAboutContradictions() {
    let described = EvieWebPassages.describe(
      [EvieWebPassage(text: "x", source: "https://a.com")],
      query: "algo"
    )

    #expect(described.contains("contradisserem"))
    #expect(described.contains("não o que é verdade"))
  }

  @Test("finding nothing says so")
  func describesEmptiness() {
    #expect(EvieWebPassages.describe([], query: "xyzzy").contains("não trouxe nada"))
  }
}

extension EviePassageRankerTests {
  fileprivate func passage(_ text: String) -> EvieWebPassage {
    EvieWebPassage(text: text, source: "https://exemplo.com")
  }
}
