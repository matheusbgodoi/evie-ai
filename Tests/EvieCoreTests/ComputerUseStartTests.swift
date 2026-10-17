import Foundation
import Testing

@testable import EvieCore

@Suite("Computer use start")
struct ComputerUseStartTests {
  static let apps = StubAppResolver()
  static let pc = EvieModelProfile.builtInPC
  static let mac = EvieModelProfile.builtInMac

  // MARK: - The request in his own words

  @Test(
    "an instruction to act on the Mac is recognised",
    arguments: [
      "abre o Notas e escreve 'teste de pesquisa' numa nota nova",
      "Evie, clica em Salvar",
      "clique no botão Enviar",
      "cola isso no Notas",
      "Cole o texto no campo de busca",
      "digita meu endereço no campo",
      "Digite olá",
      "pode abrir o Safari?",
      "Você pode clicar em Continuar?",
      "por favor, abre a Calculadora",
      "escreve 'oi' no Notas",
      "escreva isso numa nota nova",
      "aperta o botão Salvar",
      "fecha a janela",
      "preenche o formulário com meus dados",
      "Obrigado. Agora abre o Safari",
      "quero que você abra o Notas",
      "Evie, consegue digitar isso pra mim?",
    ])
  func recognisesInstructions(_ text: String) {
    #expect(ComputerUseIntent.isPresent(in: text, apps: Self.apps))
  }

  @Test(
    "writing, questions about clicking and other uses of the verbs are not",
    arguments: [
      "escreve um poema sobre o mar",
      "escreve um email para o João",
      "escreve aqui um resumo do contrato",
      "como eu clico em salvar no Word?",
      "não clica em nada",
      "Evie, não abre o Safari",
      "o que acontece se eu digitar errado?",
      "abre a cabeça, não leve a mal",
      "abre um parágrafo explicando a lei",
      "cola branca na madeira funciona?",
      "cola de papel serve para madeira?",
      "clique duplo não funciona no meu mouse",
      "digitar rápido ajuda na prova?",
      "aperta o passo que estamos atrasados",
      "fecha a conta do restaurante?",
      "clicar em links desconhecidos é perigoso?",
      "",
    ])
  func ignoresOtherSentences(_ text: String) {
    #expect(!ComputerUseIntent.isPresent(in: text, apps: Self.apps))
  }

  // MARK: - The offer

  @Test("on the PC, an instruction proposes a session with his words as the goal")
  func proposesOnThePC() {
    let offer = ComputerUseStart.offer(
      for: "  abre o Notas e escreve oi  ", origin: .typed, explicitlyAsked: false,
      isEnabled: true, profile: Self.pc, apps: Self.apps)

    #expect(offer == .propose(goal: "abre o Notas e escreve oi"))
  }

  @Test("the Mac brain offers no act mode, and says the PC is needed")
  func macLocalOffersNoActMode() {
    let offer = ComputerUseStart.offer(
      for: "clica em Salvar", origin: .pushToTalk, explicitlyAsked: false,
      isEnabled: true, profile: Self.mac, apps: Self.apps)

    guard case .explain(let text) = offer else {
      Issue.record("expected an explanation, got \(offer)")
      return
    }
    #expect(text.hasPrefix("Controlar o Mac precisa do PC"))
  }

  @Test("a question that is not an instruction is answered as usual")
  func ordinaryQuestion() {
    let offer = ComputerUseStart.offer(
      for: "qual a capital da França?", origin: .typed, explicitlyAsked: false,
      isEnabled: true, profile: Self.pc, apps: Self.apps)

    #expect(offer == .none)
  }

  @Test("the Controlar o Mac button makes any request a goal")
  func explicitlyAsked() {
    let offer = ComputerUseStart.offer(
      for: "organiza as janelas do Safari", origin: .typed, explicitlyAsked: true,
      isEnabled: true, profile: Self.pc, apps: Self.apps)

    #expect(offer == .propose(goal: "organiza as janelas do Safari"))
  }

  @Test("the wake word never proposes a session, even for an instruction")
  func wakeWordNever() {
    for origin in [ComputerUseRequestOrigin.wakeWord, .callMode] {
      let offer = ComputerUseStart.offer(
        for: "abre o Notas e escreve oi", origin: origin, explicitlyAsked: true,
        isEnabled: true, profile: Self.pc, apps: Self.apps)
      #expect(offer == .explain(ComputerUseCopy.notByWakeWord))
    }
  }

  @Test("push-to-talk, a click on the mark and typing may propose one")
  func deliberateOrigins() {
    for origin in [ComputerUseRequestOrigin.typed, .pushToTalk, .clickedMark] {
      let offer = ComputerUseStart.offer(
        for: "clica em Salvar", origin: origin, explicitlyAsked: false,
        isEnabled: true, profile: Self.pc, apps: Self.apps)
      #expect(offer == .propose(goal: "clica em Salvar"))
    }
  }

  @Test("with the switch off, an instruction is told where to turn it on")
  func switchedOff() {
    let offer = ComputerUseStart.offer(
      for: "clica em Salvar", origin: .typed, explicitlyAsked: false,
      isEnabled: false, profile: Self.pc, apps: Self.apps)

    #expect(offer == .explain(ComputerUseCopy.switchedOff))
  }

  @Test("a goal longer than the broker takes is refused before the card")
  func tooLong() {
    let goal = "digita " + String(repeating: "a", count: EvieAgentModeBroker.maximumGoalCharacters)
    let offer = ComputerUseStart.offer(
      for: goal, origin: .typed, explicitlyAsked: false,
      isEnabled: true, profile: Self.pc, apps: Self.apps)

    #expect(offer == .explain(ComputerUseCopy.goalTooLong))
  }

  @Test("the consent says injection is mitigated by the code's rules, not eliminated")
  func consentWording() {
    let text = ComputerUseCopy.consent
    #expect(text.contains("reduzem esse risco, mas não o eliminam"))
    #expect(text.contains("Esc"))
    #expect(text.contains("15 minutos"))
  }

  // MARK: - "para"

  @Test(
    "a spoken or typed stop ends a session",
    arguments: ["para", "Para!", "Evie, para", "pare", "parar", "chega", "para tudo", "pode parar", "stop"])
  func stopCommands(_ text: String) {
    #expect(ComputerUseStopCommand.isStop(text))
  }

  @Test(
    "a sentence that only contains the word is not a stop",
    arguments: ["para o Safari ir mais rápido", "isso é para amanhã", "parabéns", "não para"])
  func notStopCommands(_ text: String) {
    #expect(!ComputerUseStopCommand.isStop(text))
  }
}
