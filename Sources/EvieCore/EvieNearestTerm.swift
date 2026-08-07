import Foundation

/// The nearest word the notes actually contain, for a search term that matched
/// nothing.
///
/// This exists because of a defect in the model, measured on 2026-08-07 and not
/// fixable from here. Asked to repeat the word `cluemed` — the name of one of
/// the owner's companies — `gemma-4-26b-a4b-it` returns `cluumed`, every time,
/// including when told to repeat it exactly. Asked to spell it out it produces
/// `c-l-u-e-m-e-d`, correctly, so the letters survive and the word does not. The
/// same prompt with `keymatic` is returned untouched.
///
/// It reaches the tools: the agent was observed calling `search_content` with
/// `cluumed`, which matches **0** passages where `cluemed` matches **173**. What
/// the owner then reads is "não encontrei nenhuma menção" about the company he
/// keeps a folder of notes on.
///
/// So a term that matches nothing is given one chance to be a near miss. This is
/// deliberately the failure path only: a search that found something is never
/// second-guessed, and the cost is paid only where the alternative is an empty
/// answer. It also catches the ordinary case of a person mistyping their own
/// search.
public enum EvieNearestTerm {
  /// Below this length a single edit is too much of the word to be a typo —
  /// "casa" and "cara" are different words, not one misspelt.
  static let minimumLength = 5
  /// How many distinct words are considered before giving up. A vault of this
  /// size holds tens of thousands; the bound keeps a failed search from becoming
  /// a slow failed search.
  static let vocabularyLimit = 60_000

  /// Tallies the words of `text` that are within one edit of `term`.
  ///
  /// The term being searched for is known before the search starts, so nothing
  /// has to be kept in order to look for near misses afterwards — only the
  /// handful of words that could be one. Candidates are filtered before any
  /// distance is computed (same first letter, length within one), because edit
  /// distance over a whole vault's vocabulary is what turns a 50 ms miss into a
  /// 5 s one.
  ///
  /// An earlier version of this accumulated the full text of every file scanned
  /// and only looked at it on failure. That is up to 600 files held in memory on
  /// every search, including the searches that worked.
  public static func accumulate(
    from text: String,
    for term: String,
    into counts: inout [String: Int]
  ) {
    guard term.count >= minimumLength, let initial = term.first else {
      return
    }
    let target = Array(term)
    let lowered = term.lowercased()
    for token in text.lowercased().split(whereSeparator: { !$0.isLetter && !$0.isNumber }) {
      guard token.first == initial,
        abs(token.count - target.count) <= 1,
        token.count >= minimumLength,
        token != lowered,
        counts.count < vocabularyLimit
      else {
        continue
      }
      if isWithinOneEdit(Array(token), target) {
        counts[String(token), default: 0] += 1
      }
    }
  }

  /// The best of what `accumulate` gathered.
  ///
  /// Most frequent wins, and ties break alphabetically so the result does not
  /// depend on the order the notes happened to be read in.
  public static func best(of counts: [String: Int]) -> String? {
    counts
      .sorted { $0.value == $1.value ? $0.key < $1.key : $0.value > $1.value }
      .first?
      .key
  }

  /// The most common word in `corpus` within one edit of `term`, or nil.
  public static func nearest(to term: String, in corpus: [String]) -> String? {
    var counts: [String: Int] = [:]
    for text in corpus {
      accumulate(from: text, for: term, into: &counts)
    }
    return best(of: counts)
  }

  /// Whether `a` becomes `b` with at most one insertion, deletion or
  /// substitution. Not a general edit distance: it stops at the first mismatch
  /// and tries the three repairs, which is all that is needed and is linear.
  static func isWithinOneEdit(_ a: [Character], _ b: [Character]) -> Bool {
    if a.count == b.count {
      var differences = 0
      for index in a.indices where a[index] != b[index] {
        differences += 1
        if differences > 1 {
          return false
        }
      }
      return differences == 1
    }

    let (shorter, longer) = a.count < b.count ? (a, b) : (b, a)
    guard longer.count - shorter.count == 1 else {
      return false
    }
    var i = 0
    var j = 0
    var skipped = false
    while i < shorter.count && j < longer.count {
      if shorter[i] == longer[j] {
        i += 1
        j += 1
        continue
      }
      if skipped {
        return false
      }
      skipped = true
      j += 1
    }
    return true
  }
}
