import Foundation

/// Orders passages by how well they answer a question.
///
/// BM25, which is the standard answer to exactly this problem and has been for
/// thirty years. It needs no model, no embeddings, no index to build or keep in
/// sync, and it runs in microseconds on a few hundred passages — which matters
/// here, because this sits between the user pressing Return and the first token
/// appearing.
///
/// Two departures from textbook BM25, both because of what this text is:
///
/// A **coverage bonus**, because a passage repeating one word of the question ten
/// times is worth less than one containing every word of it once. Plain BM25
/// prefers the former; for answering a question the latter is almost always what
/// you want.
///
/// **Near-duplicate removal**, because search results copy each other. Three
/// paraphrases of the same paragraph look like three sources agreeing and are in
/// fact one, and they crowd out the passage that would have added something.
public enum EviePassageRanker {
  /// Standard BM25 saturation. How quickly repeating a term stops helping.
  static let k1 = 1.2
  /// How much a passage being longer than average counts against it.
  static let b = 0.75
  /// Above this word overlap two passages are the same thing said twice.
  static let duplicateThreshold = 0.68
  /// Shorter than this and it is a heading, a breadcrumb, or a "leia também"
  /// link rather than an answer.
  ///
  /// This is not a nicety. BM25 normalises by length, which means a nine-word
  /// navigation link containing three words of the question outscores a real
  /// paragraph containing the same three. Measured: ranking a page about HTTP/3
  /// put "Termo Anterior: Qual a diferença entre HTTP e HTTPS" in first place.
  static let minimumPassageCharacters = 120
  /// A passage scoring below this fraction of the best one is adding noise
  /// rather than evidence. Relative rather than absolute, so a decisive top
  /// result trims the rest and a diffuse set keeps more of it.
  static let relativeScoreFloor = 0.35

  /// The best passages for a question, best first.
  public static func rank(
    _ passages: [EvieWebPassage],
    for question: String,
    limit: Int = 6,
    queryTerms: [String]? = nil
  ) -> [EvieWebPassage] {
    let queryTerms = queryTerms ?? terms(in: question)
    guard !queryTerms.isEmpty, !passages.isEmpty else {
      return Array(passages.prefix(limit))
    }
    let distinctQuery = Set(queryTerms)

    // Anything too short to be prose is dropped before scoring rather than
    // after, so it cannot displace a real paragraph from the ranking.
    let substantial = passages.filter { $0.text.count >= minimumPassageCharacters }
    let passages = substantial.isEmpty ? passages : substantial

    let tokenised = passages.map { terms(in: $0.text) }
    let averageLength =
      Double(tokenised.reduce(0) { $0 + $1.count }) / Double(max(tokenised.count, 1))

    // How many passages each query term appears in, which is what makes a common
    // word count for less than a rare one.
    var documentFrequency: [String: Int] = [:]
    for tokens in tokenised {
      for term in Set(tokens) where distinctQuery.contains(term) {
        documentFrequency[term, default: 0] += 1
      }
    }

    let total = Double(passages.count)
    var scored = passages.enumerated().map { index, passage -> EvieWebPassage in
      let tokens = tokenised[index]
      let length = Double(tokens.count)
      var counts: [String: Int] = [:]
      for token in tokens where distinctQuery.contains(token) {
        counts[token, default: 0] += 1
      }

      var score = 0.0
      for term in distinctQuery {
        let frequency = Double(counts[term] ?? 0)
        guard frequency > 0 else {
          continue
        }
        let appearsIn = Double(documentFrequency[term] ?? 0)
        let idf = log(1 + (total - appearsIn + 0.5) / (appearsIn + 0.5))
        let normalised = frequency * (k1 + 1)
          / (frequency + k1 * (1 - b + b * length / max(averageLength, 1)))
        score += idf * normalised
      }

      let coverage = Double(counts.keys.count) / Double(distinctQuery.count)
      var ranked = passage
      ranked.score = score * (0.4 + 0.6 * coverage)
      return ranked
    }

    scored.sort { $0.score > $1.score }
    guard let best = scored.first?.score, best > 0 else {
      return []
    }
    let worthKeeping = scored.filter { $0.score >= best * relativeScoreFloor }
    return deduplicated(worthKeeping, limit: limit)
  }

  /// Keeps the best of any group of passages that say the same thing.
  static func deduplicated(_ passages: [EvieWebPassage], limit: Int) -> [EvieWebPassage] {
    var kept: [EvieWebPassage] = []
    var keptTokens: [Set<String>] = []

    for passage in passages {
      let tokens = Set(terms(in: passage.text))
      guard !tokens.isEmpty else {
        continue
      }
      let isDuplicate = keptTokens.contains { existing in
        let shared = existing.intersection(tokens).count
        let smaller = min(existing.count, tokens.count)
        return smaller > 0 && Double(shared) / Double(smaller) >= duplicateThreshold
      }
      guard !isDuplicate else {
        continue
      }
      kept.append(passage)
      keptTokens.append(tokens)
      if kept.count >= limit {
        break
      }
    }
    return kept
  }

  /// Words worth matching on: folded, lowercased, with the words that appear in
  /// every sentence removed.
  public static func terms(in text: String) -> [String] {
    text
      .folding(
        options: [.diacriticInsensitive, .caseInsensitive],
        locale: Locale(identifier: "pt_BR")
      )
      .split(whereSeparator: { !$0.isLetter && !$0.isNumber })
      .map(String.init)
      .filter { $0.count > 2 && !stopWords.contains($0) }
  }

  /// Portuguese and English together, because half the web this searches is in
  /// English even when the question is not.
  static let stopWords: Set<String> = [
    "que", "com", "para", "por", "uma", "dos", "das", "não", "nao", "mais", "como",
    "mas", "seu", "sua", "seus", "suas", "seja", "sao", "são", "seja", "ser", "foi",
    "seus", "isso", "esse", "essa", "este", "esta", "isto", "aquilo", "pelo", "pela",
    "sem", "sobre", "entre", "quando", "onde", "qual", "quais", "quem", "todo",
    "toda", "todos", "todas", "ele", "ela", "eles", "elas", "voce", "você", "nos",
    "nós", "meu", "minha", "tem", "ter", "tinha", "ja", "já", "ate", "até", "muito",
    "pode", "podem", "faz", "fazer", "sendo", "vai", "vao", "está", "esta", "estao",
    "the", "and", "for", "are", "with", "that", "this", "from", "you", "your",
    "have", "has", "was", "were", "will", "would", "can", "but", "not", "all",
    "any", "its", "their", "they", "them", "what", "which", "when", "where", "how",
    "who", "why", "into", "than", "then", "there", "these", "those", "such", "also",
    "more", "most", "some", "other", "about", "over", "each", "been", "does",
  ]
}

extension EvieWebPassages {
  /// The passages as the model receives them.
  ///
  /// Each carries the address it came from, so a citation can sit next to the
  /// claim rather than at the bottom of the answer — which is the difference
  /// between a source the reader can check and a list of sites that were visited.
  public static func describe(_ passages: [EvieWebPassage], query: String) -> String {
    guard !passages.isEmpty else {
      return "A busca por \"\(query)\" não trouxe nada que responda isso."
    }
    let blocks = passages.map { passage in
      "[\(passage.source)]\n\(passage.text)"
    }
    return """
      Trechos encontrados na web para "\(query)", os mais relevantes primeiro. \
      Cada um traz o endereço de onde veio; cite o endereço junto da afirmação que \
      vier dele. Isto é o que as páginas dizem, não o que é verdade — se duas se \
      contradisserem, diga isso em vez de escolher uma.

      \(blocks.joined(separator: "\n\n"))
      """
  }
}
