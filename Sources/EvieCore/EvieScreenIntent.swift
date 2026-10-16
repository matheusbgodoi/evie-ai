import Foundation

/// Whether the person asked Evie to look at the screen, in their own words.
///
/// A capture shows whatever is on the screen — a bank page, a private message —
/// and on the PC it costs about half a minute of CPU projector, so it happens
/// only when the question plainly asks for it. Like `EvieChangeIntent`, this
/// reads the person's own message and nothing else: text on a web page or in a
/// document can never ask for a capture.
///
/// Three shapes count, accent- and case-insensitive, word by word:
/// - a looking verb whose object is the screen or a window: "olha a tela",
///   "vê minha tela", "dá uma olhada na tela", "look at my screen";
/// - a demonstrative place on its own: "nessa janela", "desta tela";
/// - a plain place with a question about it: "o que tem na tela",
///   "isso aqui na tela", "what's on my screen".
///
/// A negation just before the ask cancels it ("não olha a tela"). Plurals do
/// not count, so "telas de pintura" is not about the screen; neither does a
/// screen that is only a topic ("minha tela quebrou").
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

  /// Verbs (and "olhada") whose object can be the screen.
  static let lookingWords: Set<String> = [
    "olha", "olhe", "olhar", "olhando", "olhada",
    "ve", "veja", "ver", "vendo", "enxerga",
    "le", "leia", "ler", "lendo",
    "analisa", "analise", "analisar", "confere", "confira",
    "descreve", "descreva", "resume", "resuma",
    "look", "see", "read", "check", "describe", "view", "analyze", "analyse",
  ]

  /// Words allowed between a looking verb and its screen: articles,
  /// possessives, demonstratives, "pra", "um pouco", "at".
  static let objectFillers: Set<String> = [
    "a", "o", "minha", "meu", "sua", "seu", "essa", "esta", "esse", "este",
    "na", "no", "nessa", "nesta", "em", "pra", "para", "um", "uma", "pouco", "aqui",
    "the", "my", "this", "that", "your", "at", "on", "in",
  ]

  /// A place that names the screen in front of her by itself.
  static let demonstrativePlaces: Set<String> = [
    "nessa", "nesta", "naquela", "dessa", "desta", "daquela",
  ]

  /// A place that needs a question beside it, or "o brilho na tela" would ask
  /// for a capture.
  static let plainPlaces: Set<String> = ["na", "no", "em", "on", "in"]
  static let placeFillers: Set<String> = ["a", "minha", "sua", "the", "my", "this", "your"]
  static let questionWords: Set<String> = [
    "que", "isso", "isto", "aqui", "qual", "quais", "what", "whats", "this",
  ]

  static let negations: Set<String> = ["nao", "nem", "nunca", "sem", "dont", "not", "never"]
  /// How far back a negation reaches: "não precisa ler a tela" is two words.
  static let negationReach = 3

  // MARK: - Matching

  /// The screen or window noun of the first ask that is not negated.
  static func firstAsk(in message: String) -> String? {
    let words = words(in: message)
    for (index, word) in words.enumerated() {
      guard screenNouns.contains(word) || windowNouns.contains(word),
        let start = askStart(endingAt: index, in: words),
        !isNegated(at: start, in: words)
      else {
        continue
      }
      return word
    }
    return nil
  }

  /// Where the ask that ends at the noun `index` begins, if one does.
  private static func askStart(endingAt index: Int, in words: [String]) -> Int? {
    // A looking verb, then at most three fillers, then the noun.
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
    if cursor >= 0, lookingWords.contains(words[cursor]) {
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
    // A plain place with a question before it: "o que tem na tela".
    if plainPlaces.contains(words[place]),
      let question = words[..<place].lastIndex(where: questionWords.contains)
    {
      return question
    }
    return nil
  }

  private static func isNegated(at start: Int, in words: [String]) -> Bool {
    let from = max(0, start - negationReach)
    return words[from..<start].contains(where: negations.contains)
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
