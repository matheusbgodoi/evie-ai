import Foundation
import Testing

@testable import EvieCore

@Suite("Evie screen intent")
struct EvieScreenIntentTests {
  @Test(
    "asking her to look at the screen is recognised, in Portuguese and English",
    arguments: [
      "olha a tela",
      "Olhe minha tela, por favor",
      "o que tem na tela?",
      "o que tem na minha tela?",
      "o que é isso aqui na tela?",
      "vê minha tela e me diz se tem erro",
      "lê a tela pra mim",
      "dá uma olhada na tela",
      "me explica o que está nessa janela",
      "resume o texto desta janela",
      "OLHA A TELA",
      "look at my screen",
      "what's on my screen?",
      "what is on the screen right now",
      "can you read this window?",
    ]
  )
  func recognisesAnAsk(_ ask: String) {
    #expect(EvieScreenIntent.isPresent(in: ask), "não reconheceu: \(ask)")
  }

  @Test("accents and capitals do not matter")
  func foldsAccentsAndCase() {
    #expect(EvieScreenIntent.isPresent(in: "VÊ MINHA TELA"))
    #expect(EvieScreenIntent.isPresent(in: "le a tela"))
    #expect(EvieScreenIntent.isPresent(in: "O que é isso aqui na TELA?"))
  }

  @Test(
    "a sentence about screens that does not ask her to look is not an ask",
    arguments: [
      "telas de pintura são caras?",
      "comprei duas telas novas",
      "minha tela quebrou, o que eu faço?",
      "qual o tamanho da tela do iPhone 17?",
      "como tiro print da tela no Mac?",
      "abre uma janela nova no Safari",
      "a janela da sala está aberta",
      "o que é uma tela de pintura a óleo?",
      "screen time on my phone is too high",
      "olha, eu preciso de ajuda com a planilha",
    ]
  )
  func ignoresOtherSentences(_ sentence: String) {
    #expect(!EvieScreenIntent.isPresent(in: sentence), "achou pedido em: \(sentence)")
  }

  @Test(
    "a negated ask is not an ask",
    arguments: [
      "não olha a tela",
      "nao olhe minha tela agora",
      "não precisa ler a tela",
      "nem olha a tela, só me responde",
      "don't look at my screen",
      "do not read the screen",
    ]
  )
  func refusesNegation(_ sentence: String) {
    #expect(!EvieScreenIntent.isPresent(in: sentence), "ignorou a negação em: \(sentence)")
  }

  @Test("an ask after an unrelated negation still counts")
  func negationOnlyCoversItsOwnPhrase() {
    #expect(EvieScreenIntent.isPresent(in: "não sei o que fazer, olha a tela"))
  }

  @Test("a window is captured on its own when the ask names one")
  func windowAsksForTheFrontWindow() {
    #expect(EvieScreenIntent.asksForWindow(in: "o que tem nessa janela?"))
    #expect(EvieScreenIntent.asksForWindow(in: "can you read this window?"))
    #expect(!EvieScreenIntent.asksForWindow(in: "olha a tela"))
    #expect(!EvieScreenIntent.asksForWindow(in: "o que tem na minha tela?"))
  }
}
