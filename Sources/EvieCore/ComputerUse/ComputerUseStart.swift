import Foundation

/// How the request that might start a session reached Evie.
public enum ComputerUseRequestOrigin: Sendable, Equatable {
  /// Typed into her field.
  case typed
  /// Spoken while the talk shortcut was held.
  case pushToTalk
  /// Spoken after a click on her mark or on "Falar com a Evie".
  case clickedMark
  /// Spoken after the wake word: the microphone opened on its own.
  case wakeWord
  /// Spoken in call mode, where the microphone reopens by itself.
  case callMode

  /// Whether a hand started this request. The wake word and call mode open
  /// the microphone by themselves, and it hears videos, calls and other
  /// people as well as him (ADR 0016).
  public var isDeliberate: Bool {
    switch self {
    case .typed, .pushToTalk, .clickedMark: true
    case .wakeWord, .callMode: false
    }
  }
}

/// What a request becomes before any model sees it.
public enum ComputerUseOffer: Sendable, Equatable {
  /// An ordinary question: answer it as usual.
  case none
  /// Show the session card with this goal, his own words; a click on
  /// Começar begins the session.
  case propose(goal: String)
  /// He asked Evie to act and she cannot: say why, and do nothing else.
  case explain(String)
}

/// Whether a request should propose an agent-mode session, decided in code
/// from his own message, how it reached Evie and the brain that would run it.
///
/// Nothing here begins a session. The card it leads to does, on a click, and
/// `EvieAgentModeBroker.begin` refuses the wake word again on its own.
public enum ComputerUseStart {
  /// - Parameters:
  ///   - explicitlyAsked: he pressed "Controlar o Mac…" first, so the request
  ///     is a goal whatever its words.
  ///   - isEnabled: `ComputerUseSwitch.isEnabled`.
  ///   - profile: the brain the conversation would run on.
  public static func offer(
    for prompt: String,
    origin: ComputerUseRequestOrigin,
    explicitlyAsked: Bool,
    isEnabled: Bool,
    profile: EvieModelProfile,
    apps: any ComputerAppResolving
  ) -> ComputerUseOffer {
    let goal = prompt.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !goal.isEmpty,
      explicitlyAsked || ComputerUseIntent.isPresent(in: goal, apps: apps)
    else {
      return .none
    }
    guard isEnabled else {
      return .explain(ComputerUseCopy.switchedOff)
    }
    guard origin.isDeliberate else {
      return .explain(ComputerUseCopy.notByWakeWord)
    }
    if EvieAgentModeBroker.unavailableReason(on: profile) != nil {
      return .explain(ComputerUseCopy.needsThePC)
    }
    guard goal.count <= EvieAgentModeBroker.maximumGoalCharacters else {
      return .explain(ComputerUseCopy.goalTooLong)
    }
    return .propose(goal: goal)
  }
}

/// Whether a message asks Evie to do something on the Mac herself: click,
/// type, paste, write into an app, open or close one.
///
/// Read from his own message only, like `EvieScreenIntent`, and only from the
/// head of a sentence, where Portuguese puts an instruction: after "Evie",
/// "por favor", "agora", "você pode"… comes an imperative ("clica", "abre",
/// "digite"), or an infinitive after "pode", "consegue", "quero"… ("pode
/// abrir o Safari?"). A question about doing it ("como eu clico…"), a
/// negation ("não clica") and an infinitive that is a topic ("clicar em links
/// é perigoso?") are not instructions. Each verb also needs what makes it an
/// action on the screen rather than a request for text: "abre" and "fecha" an
/// installed app (or a window or tab), "clica" a place ("em", "no",
/// "com o botão"…), "aperta" a button, "cola" something ("isso", "o texto")
/// put somewhere on screen, "escreve" a place on screen ("no Notas", "numa
/// nota nova", "no campo") — so "escreve um poema" stays an answer, and
/// "digita" anything. Being wrong costs a card he can dismiss; nothing acts
/// without his click on it.
public enum ComputerUseIntent {
  public static func isPresent(in message: String, apps: any ComputerAppResolving) -> Bool {
    sentences(of: message).contains { isInstruction($0, apps: apps) }
  }

  // MARK: - Vocabulary

  /// What may come before the verb: a name, politeness, a modal.
  static let leadIns: Set<String> = [
    "evie", "ei", "oi", "por", "favor", "pf", "pfv", "me", "voce", "vc", "tu", "agora", "entao",
    "e", "ai", "so", "que", "pode", "poderia", "podia", "consegue", "conseguiria", "quer",
    "queria", "quero",
  ]
  /// Modals after which an infinitive is a request ("pode abrir…").
  static let modals: Set<String> = [
    "pode", "poderia", "podia", "consegue", "conseguiria", "quer", "queria", "quero",
  ]

  enum Verb {
    case click, press, type, paste, write, open, close, fill
  }

  static let imperatives: [String: Verb] = [
    "clica": .click, "clique": .click,
    "aperta": .press, "aperte": .press,
    "digita": .type, "digite": .type,
    "cola": .paste, "cole": .paste,
    "escreve": .write, "escreva": .write,
    "abre": .open, "abra": .open,
    "fecha": .close, "feche": .close,
    "preenche": .fill, "preencha": .fill,
  ]
  static let infinitives: [String: Verb] = [
    "clicar": .click, "apertar": .press, "digitar": .type, "colar": .paste,
    "escrever": .write, "abrir": .open, "fechar": .close, "preencher": .fill,
  ]

  /// What follows "clica" when it is the verb, not the noun "clique duplo".
  static let clickPlaces: Set<String> = [
    "em", "no", "na", "nos", "nas", "num", "numa", "nesse", "nessa", "neste", "nesta", "ali",
    "aqui", "la", "com", "duas", "sobre", "dentro", "o", "a",
  ]
  /// What "cola" pastes: "cola isso", "cole o texto", not "cola branca".
  static let pastedThings: Set<String> = [
    "isso", "isto", "aquilo", "aqui", "o", "a", "esse", "essa", "este", "esta", "meu", "minha",
  ]
  /// Where text goes on the screen, after "no", "na", "numa"…
  static let placePrepositions: Set<String> = [
    "no", "na", "nos", "nas", "num", "numa", "nesse", "nessa", "neste", "nesta", "em", "dentro",
  ]
  static let placeNouns: Set<String> = [
    "campo", "nota", "janela", "documento", "aba", "caixa", "barra", "planilha", "formulario",
    "busca", "pesquisa", "editor",
  ]
  static let closableNouns: Set<String> = ["janela", "aba", "abas", "janelas"]
  static let fillableNouns: Set<String> = ["formulario", "campo", "campos", "cadastro", "ficha"]
  /// Articles and possessives between a verb and its object.
  static let determiners: Set<String> = [
    "o", "a", "os", "as", "um", "uma", "meu", "minha", "seu", "sua", "esse", "essa", "este",
    "esta", "app", "aplicativo", "programa",
  ]
  /// The longest app name tried, in words ("Editor de Scripts").
  static let longestAppName = 3

  // MARK: - Reading

  static func sentences(of message: String) -> [[String]] {
    ComputerActionPolicy.fold(message)
      .split(whereSeparator: { ".!?;\n".contains($0) })
      .map { sentence in
        sentence.split(whereSeparator: { !$0.isLetter && !$0.isNumber }).map(String.init)
      }
      .filter { !$0.isEmpty }
  }

  static func isInstruction(_ words: [String], apps: any ComputerAppResolving) -> Bool {
    var index = 0
    var afterModal = false
    while index < words.count, leadIns.contains(words[index]) {
      afterModal = afterModal || modals.contains(words[index])
      index += 1
    }
    guard index < words.count else {
      return false
    }
    let head = words[index]
    let verb = imperatives[head] ?? (afterModal ? infinitives[head] : nil)
    guard let verb else {
      return false
    }
    let rest = Array(words[(index + 1)...])
    guard !rest.isEmpty else {
      return false
    }
    switch verb {
    case .click:
      return clickPlaces.contains(rest[0])
    case .press:
      return rest.prefix(3).contains("botao")
    case .type:
      return true
    case .paste:
      return pastedThings.contains(rest[0]) && namesPlace(rest, apps: apps)
    case .write:
      return namesPlace(rest, apps: apps)
    case .open:
      return namesApp(afterDeterminers(rest), apps: apps)
    case .close:
      let object = afterDeterminers(rest)
      return object.first.map(closableNouns.contains) == true || namesApp(object, apps: apps)
    case .fill:
      return rest.prefix(4).contains(where: fillableNouns.contains)
    }
  }

  /// Whether a place on the screen follows: a preposition, then an app or a
  /// noun such as "campo" or "nota".
  static func namesPlace(_ words: [String], apps: any ComputerAppResolving) -> Bool {
    for (offset, word) in words.enumerated() where placePrepositions.contains(word) {
      let object = afterDeterminers(Array(words[(offset + 1)...]))
      if let noun = object.first, placeNouns.contains(noun) {
        return true
      }
      if namesApp(object, apps: apps) {
        return true
      }
    }
    return false
  }

  /// Whether the words start with the name of an installed app.
  static func namesApp(_ words: [String], apps: any ComputerAppResolving) -> Bool {
    let longest = min(longestAppName, words.count)
    guard longest > 0 else {
      return false
    }
    return (1...longest).contains { count in
      apps.resolve(name: words.prefix(count).joined(separator: " ")) != nil
    }
  }

  static func afterDeterminers(_ words: [String]) -> [String] {
    Array(words.drop(while: determiners.contains))
  }
}

/// Whether what he said or typed while a session runs is "para".
///
/// Only the whole utterance counts — "para", "pare", "chega", "para tudo",
/// "Evie, para" — so a sentence that merely contains the word ("isso é para
/// amanhã") never stops anything, and "não para" is not a stop.
public enum ComputerUseStopCommand {
  static let stops: Set<String> = [
    "para", "pare", "parar", "chega", "stop", "cancela", "cancele", "cancelar", "interrompe",
    "interrompa",
  ]
  static let fillers: Set<String> = [
    "evie", "ei", "pode", "agora", "ja", "tudo", "ai", "isso", "ok",
  ]

  public static func isStop(_ text: String) -> Bool {
    let words = ComputerActionPolicy.fold(text)
      .split(whereSeparator: { !$0.isLetter && !$0.isNumber })
      .map(String.init)
    guard !words.isEmpty, words.count <= 5, words.contains(where: stops.contains) else {
      return false
    }
    return words.allSatisfy { stops.contains($0) || fillers.contains($0) }
  }
}

/// What Evie says about starting a session, and the one-time consent.
public enum ComputerUseCopy {
  public static let needsThePC =
    "Controlar o Mac precisa do PC: o cérebro deste Mac vê a tela, mas não usa ferramentas "
    + "com segurança. Quando o PC estiver de volta, peça de novo."
  public static let switchedOff =
    "O controle do Mac está desligado. Ligue “Deixar a Evie controlar o Mac” em "
    + "\(EvieSettingsSection.screenAndAgent.path) e peça de novo."
  public static let notByWakeWord =
    "Não começo a controlar o Mac pela palavra de ativação: o microfone também ouve vídeos, "
    + "chamadas e outras pessoas. Segure o atalho de falar, ou escreva o pedido."
  public static let goalTooLong =
    "Esse pedido é longo demais para uma sessão. Diga em poucas frases o que fazer no Mac."
  /// Shown on the overlay after "Controlar o Mac…" in the menu.
  public static let askForGoal = "Diga ou escreva o que fazer no Mac"

  public static let sessionTitle = "Controlar o Mac?"
  public static let start = "Começar"
  public static let notNow = "Agora não"
  public static let perform = "Fazer"
  public static let skip = "Pular"
  public static let sessionTerms =
    "Até 15 minutos ou 25 ações. Esc, ⌥⇧Esc, Parar ou “para” interrompem; mexer no mouse "
    + "ou no teclado pausa."

  /// The first session's card, once (ADR 0016).
  public static let consent =
    "Antes da primeira vez: numa sessão a Evie vê sua tela, clica e digita por você, por até "
    + "15 minutos ou 25 ações. Ela pergunta antes de enviar, comprar, apagar ou fechar algo, "
    + "e não mexe em campos de senha, no Terminal, nos Ajustes do Sistema nem em gerenciadores "
    + "de senhas. Um texto na tela pode tentar dar ordens a ela (injeção de instruções): as "
    + "regras do código reduzem esse risco, mas não o eliminam, então acompanhe o que ela faz. "
    + "Para parar: Esc, ⌥⇧Esc, o botão Parar ou diga “para”. Mexer no mouse ou no teclado "
    + "pausa a sessão."
  public static let consentAccept = "Entendi, começar"
}
