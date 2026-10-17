import Foundation
import NaturalLanguage

/// Works out which words of a question are worth searching for.
///
/// Uses linguistic analysis with a deterministic grammar filter. The motivating failure was
/// measured rather than imagined. Asked "o que eu tenho sobre a Cluemed" over a
/// real vault, the previous version extracted `["tenho", "cluemed"]` — "tenho"
/// survived because it was not on the list. Worse, because the vault is mostly
/// technical notes, "tenho" is *rare* in it, so BM25's inverse document frequency
/// gave it a **high** weight. Chemistry lessons containing "tenho" outranked the
/// note actually called Cluemed.
///
/// A stopword list alone misses inflected grammar, while inverse document
/// frequency assumes rare means informative. Linguistic tags remain the main
/// selection; deterministic function words supplement hosts without those assets.
///
/// Part of speech supplies the main selection. A small deterministic supplement
/// also applies when system linguistic assets are absent or return otherWord.
///
/// Lemmatising is the second gain and nearly free once the tagger is running.
/// Portuguese inflects heavily — "cobro", "cobrei", "cobrava" and "cobrar" are
/// one idea — and matching them as one is the difference between finding a note
/// and not. Both the lemma and the word as written are kept, so a passage that
/// says "cobro" and one that says "cobrar" are both reachable without paying to
/// analyse every passage in the vault.
public enum EvieQueryTerms {
  /// Verbs that are grammar rather than subject matter.
  ///
  /// Short and specific: these are the auxiliaries and light verbs that appear in
  /// any sentence about anything. Everything else the tagger calls a verb is kept,
  /// because "cobrar", "revisar" and "assinar" are what a question is *about*.
  static let auxiliaryLemmas: Set<String> = [
    "ser", "estar", "ter", "haver", "ir", "vir", "fazer", "dar", "poder",
    "querer", "saber", "dever", "ficar", "ver", "dizer", "falar", "achar",
    "precisar", "conseguir", "deixar", "colocar", "passar", "levar", "pegar",
  ]

  /// Grammar still needs filtering when the OS has no Portuguese tagger assets,
  /// or reports every word as `.otherWord`. This supplements, rather than guesses,
  /// inflection: subject verbs keep their original spelling without a real lemma.
  private static let functionForms: Set<String> = [
    "quanto", "quanta", "quantos", "quantas", "porque", "tenho", "temos", "tinham",
    "tivemos", "tive", "teve", "tenha", "tenham", "preciso", "precisa", "precisamos",
    "posso", "podemos", "quero", "quer", "queremos", "devo", "deve", "devemos",
    "sou", "somos", "era", "eram", "estou", "estamos", "estava", "vou", "vamos",
  ]

  private static func isFunctionWord(_ word: String) -> Bool {
    EviePassageRanker.stopWords.contains(word)
      || auxiliaryLemmas.contains(word) || functionForms.contains(word)
  }

  /// The classes that carry subject matter.
  static let contentClasses: Set<NLTag> = [.noun, .verb, .adjective, .otherWord, .number]

  /// The words worth matching on, lemmatised and folded, with the surface form
  /// kept alongside.
  public static func extract(from question: String) -> [String] {
    extract(from: question, tagger: NLTagger(tagSchemes: [.lexicalClass, .lemma]))
  }

  static func extract(from question: String, tagger: NLTagger) -> [String] {
    guard !question.trimmingCharacters(in: .whitespaces).isEmpty else {
      return []
    }

    tagger.string = question
    tagger.setLanguage(.portuguese, range: question.startIndex..<question.endIndex)

    var terms: [String] = []
    var sawAnyTag = false
    tagger.enumerateTags(
      in: question.startIndex..<question.endIndex,
      unit: .word,
      scheme: .lexicalClass,
      options: [.omitPunctuation, .omitWhitespace]
    ) { tag, range in
      guard let tag else {
        return true
      }
      sawAnyTag = true
      guard contentClasses.contains(tag) else {
        return true
      }
      let surface = fold(String(question[range]))
      let lemma =
        tagger
        .tag(at: range.lowerBound, unit: .word, scheme: .lemma).0
        .map { fold($0.rawValue) }

      // Checked against the lemma whatever the tagger called it. "poder" in
      // "para poder ir" comes back tagged as a noun, and gating this on `.verb`
      // let it through — measured. The cost is that "o poder do Estado" loses a
      // real noun; the benefit is that every question stops carrying grammar into
      // the ranking, where a rare function word gets a high inverse-frequency
      // weight and outranks the thing actually asked about.
      if let lemma, isFunctionWord(lemma) {
        return true
      }
      if isFunctionWord(surface) {
        return true
      }
      for term in [surface, lemma].compactMap({ $0 })
      where term.count > 2 && !terms.contains(term) {
        terms.append(term)
      }
      return true
    }

    // A tagger that recognised *nothing* — an unusual language, a string the
    // analyser has no model for — must not leave the search with no terms.
    //
    // But a question that is entirely grammar, like "o que eu preciso fazer para
    // poder ir", correctly yields nothing, and falling back there put every
    // function word straight back in. Recognising nothing and filtering
    // everything are different outcomes and the difference has to be tracked;
    // measured, because the test for dropping auxiliaries failed on exactly this.
    guard sawAnyTag else {
      return EviePassageRanker.terms(in: question).filter { !isFunctionWord($0) }
    }
    return terms
  }

  static func fold(_ text: String) -> String {
    text.folding(
      options: [.diacriticInsensitive, .caseInsensitive],
      locale: Locale(identifier: "pt_BR")
    )
  }
}
