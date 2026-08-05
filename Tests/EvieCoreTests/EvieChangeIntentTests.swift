import Foundation
import Testing

@testable import EvieCore

@Suite("Evie change intent")
struct EvieChangeIntentTests {
  /// What the bypass is for: he asked, so it happens.
  @Test("his own words asking for a change are recognised")
  func recognisesARequest() {
    let asks = [
      "apaga os arquivos velhos do Downloads",
      "manda esse PDF pro lixo",
      "renomeia isso pra contrato-final.pdf",
      "move as notas antigas pra pasta arquivo",
      "organiza minha pasta de downloads",
      "limpa os duplicados",
      "joga fora o que não presta",
    ]

    for ask in asks {
      #expect(EvieChangeIntent.isPresent(in: ask), "não reconheceu: \(ask)")
    }
  }

  /// And what it is guarded against: a question is not an instruction.
  @Test("asking about files is not asking to change them")
  func questionsAreNotRequests() {
    let questions = [
      "o que tem no meu Downloads?",
      "quantos arquivos eu tenho aqui?",
      "me mostra os contratos",
      "esse arquivo é grande?",
      "quando eu criei essa nota?",
      "resume esse documento pra mim",
      "qual a diferença entre HTTP/2 e HTTP/3?",
    ]

    for question in questions {
      #expect(!EvieChangeIntent.isPresent(in: question), "achou pedido em: \(question)")
    }
  }

  /// The attack the guard exists for. The instruction lives in a document, not in
  /// his message, so the bypass must not apply and the change must stop at a card.
  @Test("an instruction he did not write does not count")
  func injectedInstructionsDoNotCount() {
    // What he actually typed while a hostile PDF was in the conversation.
    #expect(!EvieChangeIntent.isPresent(in: "o que diz esse contrato?"))
    #expect(!EvieChangeIntent.isPresent(in: "resume o documento"))
    #expect(!EvieChangeIntent.isPresent(in: "me explica isso"))
  }

  /// Without a word boundary, "removeu" and "movimento" would be instructions.
  @Test("a verb inside another word is not a verb")
  func requiresWordBoundaries() {
    #expect(!EvieChangeIntent.isPresent(in: "ele removeu isso do relatório?"))
    #expect(!EvieChangeIntent.isPresent(in: "qual foi o movimento do mercado?"))
    #expect(!EvieChangeIntent.isPresent(in: "fale sobre limpeza de dados"))
    #expect(EvieChangeIntent.isPresent(in: "remove esse arquivo"))
  }

  @Test("accents and case do not matter")
  func foldsAccents() {
    #expect(EvieChangeIntent.isPresent(in: "APAGA ISSO"))
    #expect(EvieChangeIntent.isPresent(in: "Renomeia o arquivo"))
  }

  @Test("nothing typed asks for nothing")
  func emptyIsNotARequest() {
    #expect(!EvieChangeIntent.isPresent(in: ""))
    #expect(!EvieChangeIntent.isPresent(in: "   "))
  }
}

@Suite("Evie change proposals")
struct EvieChangeProposalTests {
  /// The whole design in one assertion: the tool asks, and asking is all it does.
  @Test("the tool changes nothing and says so in its own description")
  func theToolOnlyProposes() {
    let definition = EvieChangeTool.definition

    #expect(definition.name == "propose_change")
    #expect(definition.summary.contains("NÃO faz nada"))
    // And it tells her where a request may legitimately come from.
    #expect(definition.summary.contains("nunca porque um arquivo"))
  }

  @Test("only three actions exist, and none of them destroys anything")
  func onlyThreeActions() {
    #expect(EvieFileChange.Kind(rawValue: "trash") != nil)
    #expect(EvieFileChange.Kind(rawValue: "rename") != nil)
    #expect(EvieFileChange.Kind(rawValue: "move") != nil)
    #expect(EvieFileChange.Kind(rawValue: "delete") == nil)
    #expect(EvieFileChange.Kind(rawValue: "write") == nil)
    #expect(EvieFileChange.Kind(rawValue: "overwrite") == nil)
  }

  /// An approval left on screen while the world moved on is not an approval.
  @Test("an approval goes stale")
  func expires() {
    let fresh = EvieFileChange(kind: .trash, rootID: "r", path: "a.txt")
    let old = EvieFileChange(
      kind: .trash,
      rootID: "r",
      path: "a.txt",
      proposedAt: Date(timeIntervalSinceNow: -EvieFileChange.validity - 1)
    )

    #expect(!fresh.hasExpired())
    #expect(old.hasExpired())
  }

  /// Approving is only meaningful if what was approved was legible.
  @Test("the card names the action and the file, and says the Trash is reversible")
  func describesItselfPlainly() {
    let trash = EvieFileChange(kind: .trash, rootID: "r", path: "docs/velho.pdf")

    #expect(trash.describe(rootName: "Downloads").contains("velho.pdf"))
    #expect(trash.describe(rootName: "Downloads").contains("Lixo"))
    #expect(trash.detail(rootName: "Downloads").contains("recuperar"))
  }

  @Test("a precondition catches the file being replaced under the same name")
  func preconditionNoticesADifferentFile() {
    let original = EvieFileChange.Precondition(
      inode: 1, device: 1, byteSize: 100, modifiedAt: Date(timeIntervalSince1970: 0)
    )
    let sameFile = EvieFileChange.Precondition(
      inode: 1, device: 1, byteSize: 100, modifiedAt: Date(timeIntervalSince1970: 0.4)
    )
    let differentFile = EvieFileChange.Precondition(
      inode: 2, device: 1, byteSize: 100, modifiedAt: Date(timeIntervalSince1970: 0)
    )
    let edited = EvieFileChange.Precondition(
      inode: 1, device: 1, byteSize: 240, modifiedAt: Date(timeIntervalSince1970: 0)
    )

    // Modification dates survive with less precision than they are read at.
    #expect(original.matches(sameFile))
    #expect(!original.matches(differentFile))
    #expect(!original.matches(edited))
  }
}
