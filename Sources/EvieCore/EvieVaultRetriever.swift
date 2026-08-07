import Foundation

/// Turns text into a vector, when this Mac can.
///
/// A protocol so the retriever can be tested without a model and so the whole
/// thing degrades to word matching on a machine that has no embedding available,
/// rather than failing.
public protocol EvieSemanticEmbedder: Sendable {
  func vector(for text: String) -> [Float]?
}

/// One passage and why it was chosen.
public struct EvieRetrievedPassage: Hashable, Sendable {
  public var passage: EvieVaultPassage
  public var score: Double
  /// Which rankers found it, so a search that only ever works one way is
  /// visible instead of being assumed to be hybrid.
  public var matchedByWords: Bool
  public var matchedByMeaning: Bool

  public init(
    passage: EvieVaultPassage,
    score: Double,
    matchedByWords: Bool = false,
    matchedByMeaning: Bool = false
  ) {
    self.passage = passage
    self.score = score
    self.matchedByWords = matchedByWords
    self.matchedByMeaning = matchedByMeaning
  }
}

/// Finds the passages of the vault that answer a question.
///
/// Two rankers, fused. They fail in different directions, which is the entire
/// reason to run both:
///
/// **Words** (BM25) are exact and unbeatable on the things that matter most in
/// somebody's own notes — a company name, a person, a number. They are also
/// blind: ask "quanto eu cobro pela consultoria" of a note saying "valor da
/// minha hora" and there is not one word in common, so it scores zero.
///
/// **Meaning** (embeddings) crosses that gap. Measured on this Mac before this
/// was built: that exact pair scores 0.796 against 0.933 for an unrelated
/// sentence, so the signal is real. It is also vague — it will happily rank a
/// passage that is *about the same subject* above the one that contains the
/// actual figure, and it does not know that "Cluemed" is special.
///
/// They are combined with Reciprocal Rank Fusion rather than by adding scores,
/// because their scores are not on the same scale and never will be. RRF only
/// uses the *order* each ranker produced, which is the part that is comparable.
/// A passage both rankers liked rises above one that either loved alone, which is
/// exactly the behaviour wanted.
public struct EvieVaultRetriever: Sendable {
  /// The constant from the RRF paper. It decides how quickly being further down
  /// a ranking stops mattering; sixty is the value everyone uses and there is no
  /// reason here to differ.
  static let fusionConstant = 60.0
  /// How deep each ranker is consulted before fusing.
  static let candidatesPerRanker = 40
  /// How far a vector may be and still count as related. From the measurement
  /// above: related pairs sat at 0.66–0.80, unrelated at 0.93.
  static let maximumSemanticDistance = 0.88
  /// How much more a match in the note's title or heading counts than one in its
  /// body. Two, because it is the strongest of the three signals: the person
  /// named the note themselves.
  static let titleWeight = 2.0

  public var embedder: (any EvieSemanticEmbedder)?

  public init(embedder: (any EvieSemanticEmbedder)? = nil) {
    self.embedder = embedder
  }

  /// The best passages for a question.
  public func retrieve(
    _ question: String,
    from passages: [EvieVaultPassage],
    vectors: [[Float]?] = [],
    limit: Int = 6
  ) -> [EvieRetrievedPassage] {
    guard !passages.isEmpty else {
      return []
    }

    let terms = EvieQueryTerms.extract(from: question)
    var byTitle = rankByTitle(terms: terms, in: passages)
    var byWords = rankByWords(question, in: passages)
    let byMeaning = rankByMeaning(question, in: passages, vectors: vectors)

    // Not one word of the question appears anywhere. Before giving up, allow for
    // the term being off by a letter — see `EvieNearestTerm` for the measured
    // reason that happens without anybody mistyping anything. Only on this path:
    // a search that found something is never second-guessed.
    if byTitle.isEmpty && byWords.isEmpty {
      let corpus = passages.map { $0.noteTitle + " " + $0.text }
      let corrected = terms.compactMap { EvieNearestTerm.nearest(to: $0, in: corpus) }
      if !corrected.isEmpty {
        byTitle = rankByTitle(terms: corrected, in: passages)
        byWords = rankByWords(corrected.joined(separator: " "), in: passages)
      }
    }

    // Nothing matched any way. Saying so beats returning the least bad passage,
    // which reads as an answer.
    guard !byTitle.isEmpty || !byWords.isEmpty || !byMeaning.isEmpty else {
      return []
    }

    var fused: [Int: Double] = [:]
    var wordMatches: Set<Int> = []
    var meaningMatches: Set<Int> = []

    // Where a passage sits is evidence about what it is about, and it is evidence
    // the person themselves produced. A note titled "Cluemed" is about Cluemed on
    // every line of it, including the ones that only say "eles". Weighted above
    // the others because it is the most reliable of the three and the cheapest.
    for (rank, index) in byTitle.enumerated() {
      fused[index, default: 0] += Self.titleWeight / (Self.fusionConstant + Double(rank + 1))
      wordMatches.insert(index)
    }
    for (rank, index) in byWords.enumerated() {
      fused[index, default: 0] += 1 / (Self.fusionConstant + Double(rank + 1))
      wordMatches.insert(index)
    }
    for (rank, index) in byMeaning.enumerated() {
      fused[index, default: 0] += 1 / (Self.fusionConstant + Double(rank + 1))
      meaningMatches.insert(index)
    }

    return
      fused
      .sorted { $0.value > $1.value }
      .prefix(limit)
      .map { index, score in
        EvieRetrievedPassage(
          passage: passages[index],
          score: score,
          matchedByWords: wordMatches.contains(index),
          matchedByMeaning: meaningMatches.contains(index)
        )
      }
  }

  /// Passages whose note title or heading path contains what was asked about.
  ///
  /// Ordered by how many distinct terms matched, so a note called exactly the
  /// thing asked about beats one that merely mentions it in a subheading.
  public func rankByTitle(terms: [String], in passages: [EvieVaultPassage]) -> [Int] {
    guard !terms.isEmpty else {
      return []
    }
    return
      passages.enumerated()
      .compactMap { index, passage -> (Int, Int)? in
        let place = EvieQueryTerms.fold(passage.breadcrumb)
        let matched = terms.filter { place.contains($0) }.count
        return matched > 0 ? (index, matched) : nil
      }
      .sorted { $0.1 > $1.1 }
      .prefix(Self.candidatesPerRanker)
      .map(\.0)
  }

  /// BM25 over the passages, returning indices best first.
  public func rankByWords(_ question: String, in passages: [EvieVaultPassage]) -> [Int] {
    // Analysed terms rather than a stopword split, so a pronoun that happens to
    // be rare in this vault cannot outrank a company's name.
    let ranked = EviePassageRanker.rank(
      passages.map { EvieWebPassage(text: $0.searchableText, source: $0.path) },
      for: question,
      limit: Self.candidatesPerRanker,
      queryTerms: EvieQueryTerms.extract(from: question)
    )
    // Mapped back by text, because the ranker deals in its own type. Passages
    // are unique enough that this is unambiguous.
    var indexByText: [String: Int] = [:]
    for (index, passage) in passages.enumerated() {
      indexByText[passage.searchableText] = index
    }
    return ranked.compactMap { indexByText[$0.text] }
  }

  /// Cosine distance from the question, returning indices closest first.
  public func rankByMeaning(
    _ question: String,
    in passages: [EvieVaultPassage],
    vectors: [[Float]?]
  ) -> [Int] {
    guard let embedder,
      vectors.count == passages.count,
      let asked = embedder.vector(for: question)
    else {
      return []
    }

    return
      vectors.enumerated()
      .compactMap { index, vector -> (Int, Double)? in
        guard let vector else {
          return nil
        }
        let distance = Self.cosineDistance(asked, vector)
        guard distance <= Self.maximumSemanticDistance else {
          return nil
        }
        return (index, distance)
      }
      .sorted { $0.1 < $1.1 }
      .prefix(Self.candidatesPerRanker)
      .map(\.0)
  }

  /// One minus cosine similarity, so smaller is closer — the same direction
  /// `NLEmbedding.distance` reports, which keeps the measured thresholds above
  /// meaningful.
  static func cosineDistance(_ a: [Float], _ b: [Float]) -> Double {
    guard a.count == b.count, !a.isEmpty else {
      return .infinity
    }
    var dot: Double = 0
    var normA: Double = 0
    var normB: Double = 0
    for index in a.indices {
      dot += Double(a[index]) * Double(b[index])
      normA += Double(a[index]) * Double(a[index])
      normB += Double(b[index]) * Double(b[index])
    }
    guard normA > 0, normB > 0 else {
      return .infinity
    }
    return 1 - dot / (normA.squareRoot() * normB.squareRoot())
  }
}

extension EvieVaultRetriever {
  /// What the model receives.
  ///
  /// Each passage names the note and section it came from, so a citation can be
  /// a place the user can open rather than "nas suas anotações".
  public static func describe(
    _ retrieved: [EvieRetrievedPassage],
    query: String
  ) -> String {
    guard !retrieved.isEmpty else {
      return "Não achei nada nas suas anotações sobre \"\(query)\"."
    }
    return """
      Trechos das anotações do Matheus sobre "\(query)", os mais relevantes \
      primeiro. Cada um diz de qual nota e de qual seção veio; cite a nota quando \
      usar. Isto é o que ele escreveu, e pode estar desatualizado — se a nota \
      contradisser o que você sabe, diga que a nota diz uma coisa e por quê você \
      acha outra, em vez de escolher calado.

      \(retrieved.map(\.passage.quoted).joined(separator: "\n\n"))
      """
  }
}
