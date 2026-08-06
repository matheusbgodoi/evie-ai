import Foundation
import Testing

@testable import EvieCore

@Suite("Evie search commands")
struct EvieSearchCommandsTests {
  // MARK: - Recognising the commands

  @Test("the command carries what to search for")
  func readsTheTerm() {
    #expect(EvieVaultSearchCommand.query(in: "/buscar cluemed") == "cluemed")
    #expect(EvieVaultSearchCommand.query(in: "  /BUSCAR   valor da hora  ") == "valor da hora")
    #expect(EvieWebCommand.question(in: "/web quanto custa um M4 Pro") == "quanto custa um M4 Pro")
    #expect(EvieWebCommand.question(in: " /WEB  o que mudou no Swift 6.2 ") == "o que mudou no Swift 6.2")
  }

  @Test("the command with nothing after it is still the command")
  func acceptsBareCommand() {
    #expect(EvieVaultSearchCommand.query(in: "/buscar") == "")
    #expect(EvieWebCommand.question(in: "  /web  ") == "")
  }

  /// The test that matters most. A command that fires on ordinary writing is
  /// worse than one nobody finds: `/buscar` silently answers a different
  /// question, and `/web` sends what he typed to a search engine.
  @Test("ordinary writing is not a command")
  func doesNotFireOnProse() {
    for prose in [
      "/buscarei um jeito de resolver",
      "buscar o quê?",
      "me ajuda a /buscar isso",
      "/webhook do Stripe parou",
      "/website caiu de novo",
      "vale a pena usar /web components?",
      "",
    ] {
      #expect(EvieVaultSearchCommand.query(in: prose) == nil, "buscou em \"\(prose)\"")
      #expect(EvieWebCommand.question(in: prose) == nil, "foi pra web em \"\(prose)\"")
    }
  }

  /// `/web` is a prefix of nothing else here, but `/buscar` and `/plano` share a
  /// parser and each has to keep to itself.
  @Test("one command is not another")
  func commandsDoNotOverlap() {
    #expect(EvieWebCommand.question(in: "/buscar cluemed") == nil)
    #expect(EvieVaultSearchCommand.query(in: "/web cluemed") == nil)
    #expect(EvieVaultSearchCommand.query(in: "/plano compare X e Y") == nil)
  }

  // MARK: - Being discoverable

  /// A command nobody can find is a command that does not exist, which is
  /// exactly how `/plano` shipped.
  @Test("both commands are in the menu")
  func bothAreOffered() {
    let names = EvieCommandCatalogue.all.map(\.name)

    #expect(names.contains(EvieVaultSearchCommand.name))
    #expect(names.contains(EvieWebCommand.name))
    #expect(EvieCommandCatalogue.suggestions(for: "/bu").map(\.name) == ["/buscar"])
    #expect(EvieCommandCatalogue.suggestions(for: "/we").map(\.name) == ["/web"])
    #expect(EvieCommandCatalogue.isComplete("/buscar"))
    #expect(EvieCommandCatalogue.isComplete(" /WEB "))
  }

  // MARK: - What the card says

  @Test("each passage is shown with the note it came from")
  func namesThePlace() {
    let report = EvieVaultSearchReport.text(
      for: [
        EvieRetrievedPassage(
          passage: EvieVaultPassage(
            noteTitle: "Cluemed",
            headingPath: ["Preços"],
            text: "O valor da minha hora é R$ 300.",
            path: "Cluemed.md",
            rootID: "vault"
          ),
          score: 1
        )
      ],
      query: "quanto eu cobro"
    )

    #expect(report.contains("Cluemed › Preços"))
    #expect(report.contains("R$ 300"))
    #expect(report.contains("1 trecho"))
  }

  /// Finding nothing is a real result and is said plainly. Falling back to the
  /// model here would put an answer where a search result belongs, which is a
  /// lie about where it came from.
  @Test("finding nothing says so")
  func saysWhenEmpty() {
    let report = EvieVaultSearchReport.text(for: [], query: "orçamento de 2019")

    #expect(report.contains("Não achei nada"))
    #expect(report.contains("orçamento de 2019"))
  }

  @Test("a long passage is cut at a word")
  func cutsAtAWord() {
    let long = String(repeating: "palavra ", count: 200)

    let condensed = EvieVaultSearchReport.condensed(long)

    #expect(condensed.count <= EvieVaultSearchReport.maximumPassageCharacters + 1)
    #expect(condensed.hasSuffix("palavra…"))
  }
}
