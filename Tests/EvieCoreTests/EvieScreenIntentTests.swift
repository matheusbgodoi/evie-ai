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
      // Second review: clear asks the tightened rules must keep.
      "O que está escrito na tela?",
      "oq tem na minha tela?",
      "Você consegue ver minha tela?",
      "Pode ler a tela pra mim?",
      "Confere essa tela e me diz se o formulário está certo",
      "O que aparece nessa janela?",
      "Tá vendo a minha tela?",
      "Olha na tela e me fala qual botão eu aperto",
      "Analisa a minha tela",
      "o que você vê na tela?",
      "Evie, dá uma olhada na minha tela",
      "o que é isso aí na tela?",
      "what do you see on my screen?",
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
      // Second review, measured: each of these used to capture the screen.
      "O que fazer com uma mancha na tela do iPhone?",
      "Qual o preço de trocar o vidro, tenho um risco na tela",
      "Que filme tá passando hoje? Quero ver em tela grande",
      // A screen as a topic, another device's screen, or a statement.
      "Olha, a tela do meu celular quebrou",
      "É ruim ler na tela por muito tempo?",
      "Passo o dia todo olhando a tela do computador, isso faz mal?",
      "Quanto custa trocar a tela do iPad?",
      "Qual a melhor película pra tela do celular?",
      "Vou ver o jogo na tela da TV",
      "Como deixar o vídeo em tela cheia?",
      "Meu filho fica muito tempo na tela, o que eu faço?",
      "Você consegue ver o filme em tela cheia?",
      "Esqueci a senha da tela de bloqueio",
      "Tem um risco na tela do meu celular, o que faço?",
      "Dei uma olhada na tela e não entendi nada",
      "A criança olha a tela o dia inteiro",
      "I can't see my screen, it's too dark",
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
