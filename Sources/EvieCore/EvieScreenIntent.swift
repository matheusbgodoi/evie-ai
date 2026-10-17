import Foundation

/// Whether the person asked Evie to look at the screen, in their own words.
///
/// A capture shows whatever is on the screen — a bank page, a private message —
/// and on the PC it costs about half a minute of CPU projector, so it happens
/// only when the question plainly asks for it. Like `EvieChangeIntent`, this
/// reads the person's own message and nothing else: text on a web page or in a
/// document can never ask for a capture.
///
/// Three shapes count, accent- and case-insensitive, word by word, inside one
/// clause (commas and sentence ends split clauses):
/// - a looking request whose object is the screen or a window: an imperative
///   ("olhe", "veja", "leia" anywhere; "olha", "vê", "lê", "look", "read" only
///   when nothing but "Evie", "me", "você", "pode"… comes before them, since
///   "a criança olha a tela" is the same word as a statement), an infinitive or
///   gerund after "pode", "consegue", "tá"… ("você consegue ver minha tela?",
///   "tá vendo a tela?"), or "dá uma olhada" — then "a", "minha", "na"… and the
///   noun: "olha a tela", "pode ler a tela pra mim?", "look at my screen";
/// - a demonstrative place on its own: "nessa janela", "desta tela";
/// - a plain place right after a question about what is there: "o que tem na
///   tela", "o que é isso aqui na tela", "what's on my screen". The question
///   word, a verb of presence ("tem", "está", "aparece", "é") and the place sit
///   together, so "o que fazer com uma mancha na tela" is not one.
///
/// A negation just before the ask cancels it ("não olha a tela"). Plurals do
/// not count, so "telas de pintura" is not about the screen; neither does a
/// screen that is only a topic ("minha tela quebrou", "ver em tela grande") or
/// another device's ("a tela do meu celular").
public enum EvieScreenIntent {
  /// Whether this message asks her to look at the screen.
  public static func isPresent(in message: String) -> Bool {
    firstAsk(in: message) != nil
  }

  /// Whether the ask names a window rather than the screen, so the front
  /// window is captured on its own.
  public static func asksForWindow(in message: String) -> Bool {
    guard let noun = firstAsk(in: message) else {
      return false
    }
    return windowNouns.contains(noun)
  }

  // MARK: - Vocabulary

  static let screenNouns: Set<String> = ["tela", "screen"]
  static let windowNouns: Set<String> = ["janela", "window"]

  /// Looking verbs that are a request wherever they stand: imperatives with no
  /// indicative twin.
  static let requestVerbs: Set<String> = [
    "olhe", "veja", "leia", "analise", "confira", "descreva", "resuma",
  ]
  /// Looking verbs that are a request only at the head of their clause: the
  /// Portuguese imperatives that are also "ele olha", and English ones.
  static let leadingVerbs: Set<String> = [
    "olha", "ve", "le", "analisa", "confere", "descreve", "resume",
    "look", "see", "read", "check", "describe", "view", "analyze", "analyse",
  ]
  /// What may come before a leading verb and keep it a request.
  static let leadIns: Set<String> = [
    "evie", "me", "agora", "entao", "so", "ai", "ei", "oi", "voce", "vc", "tu", "por", "favor",
    "pode", "consegue", "hey", "please", "now", "just", "can", "could", "would", "will", "you", "do",
  ]
  /// Infinitives and gerunds: "ler na tela" is a habit, "pode ler a tela?" a
  /// request.
  static let auxiliaryVerbs: Set<String> = [
    "olhar", "ver", "ler", "analisar", "conferir", "descrever", "resumir", "enxergar",
    "olhando", "vendo", "lendo",
  ]
  /// What turns an infinitive or gerund into a request, within two words.
  static let auxiliaries: Set<String> = [
    "pode", "podia", "poderia", "consegue", "conseguiria", "consegues", "ta", "esta", "quer",
    "queria",
  ]
  /// "dá uma olhada", "pode dar uma olhada": the offer before "uma olhada".
  static let glanceWords: Set<String> = ["olhada", "olhadinha"]
  static let glanceOffers: Set<String> = ["da", "de", "dar", "daria"]

  /// Words allowed between a looking verb and its screen: articles,
  /// possessives, demonstratives, "pra", "um pouco", "at". Not "em": "ver em
  /// tela grande" is how a film is watched, not a request.
  static let objectFillers: Set<String> = [
    "a", "o", "minha", "meu", "sua", "seu", "essa", "esta", "esse", "este",
    "na", "no", "nessa", "nesta", "pra", "para", "um", "uma", "pouco", "aqui", "so",
    "the", "my", "this", "that", "your", "at", "on", "in",
  ]

  /// A place that names the screen in front of her by itself.
  static let demonstrativePlaces: Set<String> = [
    "nessa", "nesta", "naquela", "dessa", "desta", "daquela",
  ]

  /// A place that needs a question about what is there right before it, or "o
  /// brilho na tela" would ask for a capture.
  static let plainPlaces: Set<String> = ["na", "no", "em", "on", "in"]
  static let placeFillers: Set<String> = ["a", "minha", "sua", "the", "my", "this", "your"]
  static let questionWords: Set<String> = ["que", "oq", "qual", "quais", "what"]
  /// "what's" asks and says "is" at once.
  static let questionsWithPresence: Set<String> = ["whats"]
  static let presenceVerbs: Set<String> = [
    "tem", "ha", "esta", "ta", "e", "aparece", "mostra", "fica", "diz", "ve", "enxerga",
    "is", "appears", "says", "shows", "see",
  ]
  /// What may sit between the verb of presence and the place: "o que é isso
  /// aqui na tela", "o que está escrito na tela".
  static let presenceComplements: Set<String> = [
    "isso", "isto", "aqui", "ai", "escrito", "aparecendo", "acontecendo", "aberto", "mostrando",
    "this", "here", "written", "showing",
  ]
  /// How many words may separate the question word from its verb of presence:
  /// "o que você vê", "what do you see".
  static let questionReach = 2

  /// After the noun, "do/da/of" and one of these name some other screen.
  static let ofWords: Set<String> = ["do", "da", "de", "dum", "duma", "of", "on"]
  static let otherDevices: Set<String> = [
    "iphone", "ipad", "celular", "telefone", "smartphone", "tablet", "tv", "televisao",
    "televisor", "relogio", "watch", "carro", "cinema", "kindle", "phone", "android",
  ]

  static let negations: Set<String> = [
    "nao", "nem", "nunca", "sem", "dont", "not", "never", "cant", "cannot", "wont",
  ]
  /// How far back a negation reaches: "não precisa ler a tela" is two words.
  static let negationReach = 3

  // MARK: - Matching

  /// The screen or window noun of the first ask that is not negated.
  static func firstAsk(in message: String) -> String? {
    for words in clauses(in: message) {
      for (index, word) in words.enumerated() {
        guard screenNouns.contains(word) || windowNouns.contains(word),
          let start = askStart(endingAt: index, in: words),
          !isNegated(at: start, in: words),
          !namesAnotherDevice(after: index, in: words)
        else {
          continue
        }
        return word
      }
    }
    return nil
  }

  /// Where the ask that ends at the noun `index` begins, if one does.
  private static func askStart(endingAt index: Int, in words: [String]) -> Int? {
    // A looking request, then at most three fillers, then the noun.
    var cursor = index - 1
    var fillers = 0
    while cursor >= 0, objectFillers.contains(words[cursor]), fillers < 3 {
      if demonstrativePlaces.contains(words[cursor]) {
        // "me explica o que está nessa janela" is an ask even without a verb.
        return cursor
      }
      cursor -= 1
      fillers += 1
    }
    if cursor >= 0, isLookingRequest(at: cursor, in: words) {
      return cursor
    }

    // A demonstrative place, possibly with a possessive: "desta janela".
    var place = index - 1
    if place >= 0, placeFillers.contains(words[place]) {
      place -= 1
    }
    guard place >= 0 else {
      return nil
    }
    if demonstrativePlaces.contains(words[place]) {
      return place
    }
    if plainPlaces.contains(words[place]) {
      return questionAboutWhatIsThere(before: place, in: words)
    }
    return nil
  }

  /// Whether the looking verb at `index` is a request rather than a statement
  /// about looking.
  private static func isLookingRequest(at index: Int, in words: [String]) -> Bool {
    let word = words[index]
    if requestVerbs.contains(word) {
      return true
    }
    if leadingVerbs.contains(word) {
      return words[..<index].allSatisfy(leadIns.contains)
    }
    if auxiliaryVerbs.contains(word) {
      return words[max(0, index - 2)..<index].contains(where: auxiliaries.contains)
    }
    if glanceWords.contains(word) {
      // "dá uma olhada", not "dei uma olhada".
      return index >= 2 && words[index - 1] == "uma" && glanceOffers.contains(words[index - 2])
    }
    return false
  }

  /// Where the question about the place at `place` begins: a question word,
  /// at most `questionReach` words, a verb of presence, at most two
  /// complements, the place.
  private static func questionAboutWhatIsThere(before place: Int, in words: [String]) -> Int? {
    var cursor = place - 1
    var complements = 0
    while cursor >= 0, presenceComplements.contains(words[cursor]), complements < 2 {
      cursor -= 1
      complements += 1
    }
    guard cursor >= 0 else {
      return nil
    }
    if questionsWithPresence.contains(words[cursor]) {
      return cursor
    }
    guard presenceVerbs.contains(words[cursor]) else {
      return nil
    }
    let reach = max(0, cursor - questionReach - 1)
    return words[reach..<cursor].lastIndex(where: questionWords.contains)
  }

  private static func isNegated(at start: Int, in words: [String]) -> Bool {
    let from = max(0, start - negationReach)
    return words[from..<start].contains(where: negations.contains)
  }

  /// "a tela do meu celular", "the screen of my phone": a screen, but not this
  /// one.
  private static func namesAnotherDevice(after index: Int, in words: [String]) -> Bool {
    let following = words.dropFirst(index + 1).prefix(3)
    guard let first = following.first, ofWords.contains(first) else {
      return false
    }
    return following.dropFirst().contains(where: otherDevices.contains)
  }

  /// The message's clauses, each as its words. An ask lies within one: in
  /// "olha, a tela do meu celular quebrou" the "olha" is an interjection.
  static func clauses(in message: String) -> [[String]] {
    message
      .split(whereSeparator: { ",.;:!?…\n".contains($0) })
      .map { words(in: String($0)) }
      .filter { !$0.isEmpty }
  }

  /// Lowercased words without accents. Apostrophes are removed rather than
  /// split on, so "what's" and "don't" stay one word each.
  static func words(in message: String) -> [String] {
    message
      .folding(options: [.diacriticInsensitive, .caseInsensitive], locale: Locale(identifier: "pt_BR"))
      .replacingOccurrences(of: "'", with: "")
      .replacingOccurrences(of: "’", with: "")
      .split(whereSeparator: { !$0.isLetter && !$0.isNumber })
      .map(String.init)
  }
}
