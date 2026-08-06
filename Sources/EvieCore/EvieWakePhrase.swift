import Foundation

/// Decides whether what the microphone just heard was the phrase that wakes her.
///
/// The hard part is not the comparison, it is that "Evie" is not a Portuguese
/// word. A recogniser trained on pt-BR has no entry for it and returns whatever
/// it can build out of real words — "ivi", "e vi", "evi", "eve", "ive". Matching
/// the text exactly means she never comes, which is precisely what was reported.
///
/// So three things, in order of how much they matter:
///
/// **Spaces are discarded before comparing.** Where a recogniser puts a word
/// boundary inside an invented name is arbitrary — "e vi" and "evi" are the same
/// sound heard twice — and treating them as different is comparing punctuation
/// rather than speech.
///
/// **The comparison is by edit distance, not equality.** One or two wrong
/// letters in a six-letter name is a normal result, not a failure to speak.
///
/// **Several phrases can be accepted at once.** No amount of cleverness here
/// beats being able to add what the recogniser actually produces, which is why
/// the settings pane shows exactly what it heard.
public enum EvieWakePhrase {
  /// How close a heard phrase has to be, as a fraction of the phrase's own
  /// length.
  ///
  /// Measured rather than chosen. Against "Ei, Evie", the mis-hearings a pt-BR
  /// recogniser actually produces — "ei ivi", "ei evi", "ei eve", "ei e vi",
  /// "ei ivie" — score between 0.667 and 1.000. Twelve ordinary Portuguese
  /// sentences, including the deliberately close "seis e meia", "aquele vinho"
  /// and "hoje eu vi", never exceed 0.500.
  ///
  /// 0.6 sits in that gap with 0.167 of margin on the side that matters. The
  /// first attempt used 0.7 and dropped "ei ivi", which is exactly the
  /// mis-hearing that made her never come.
  ///
  /// The trade is deliberately asymmetric: a wake that does not fire is a
  /// feature that does not exist, while one that fires by mistake shows a window
  /// that a keystroke dismisses.
  static let minimumSimilarity = 0.6

  /// Below this a phrase is too short to be safe, whatever it is.
  ///
  /// At three normalised characters, "0.7 similarity" is one wrong letter out of
  /// three, and ordinary speech would trip it constantly. Refused rather than
  /// accepted and then blamed on the microphone.
  public static let minimumPhraseCharacters = 4

  /// Lowercased, unaccented, letters and digits only.
  ///
  /// Spaces go too. See above: word boundaries inside an invented name are noise.
  public static func normalize(_ text: String) -> String {
    text
      .folding(options: [.diacriticInsensitive, .caseInsensitive], locale: Locale(identifier: "pt_BR"))
      .lowercased()
      .unicodeScalars
      .filter { CharacterSet.alphanumerics.contains($0) }
      .reduce(into: "") { $0.unicodeScalars.append($1) }
  }

  /// The phrases a person configured, split on semicolons so variants can be
  /// added without a second setting.
  ///
  /// Not commas, which was the first attempt and was wrong for the most obvious
  /// phrase there is: "Ei, Evie" has a comma in it, so it split into "Ei" and
  /// "Evie", the first was discarded as too short, and she was left listening for
  /// a bare "Evie" — measurably worse than the phrase that was configured. A
  /// separator has to be something a phrase would not contain.
  public static func phrases(in configured: String) -> [String] {
    configured
      .split(whereSeparator: { $0 == ";" || $0.isNewline })
      .map { normalize(String($0)) }
      .filter { $0.count >= minimumPhraseCharacters }
  }

  /// Whether `heard` ends with something close enough to any configured phrase.
  ///
  /// Anchored at the end because a wake phrase is what you just said, not
  /// something from a minute ago. Without that, a transcript that once contained
  /// the phrase keeps matching for as long as it is retained, and she wakes on
  /// every subsequent syllable.
  public static func matches(_ heard: String, phrases configured: String) -> Bool {
    let candidates = phrases(in: configured)
    guard !candidates.isEmpty else {
      return false
    }
    let text = normalize(heard)
    guard !text.isEmpty else {
      return false
    }
    return candidates.contains { matches(text, phrase: $0) }
  }

  static func matches(_ normalizedText: String, phrase: String) -> Bool {
    let characters = Array(normalizedText)
    let target = Array(phrase)
    // A window either side of the phrase's length, since a mis-hearing can be a
    // letter longer or shorter than the truth.
    let slack = max(1, target.count / 3)
    let shortest = max(1, target.count - slack)
    let longest = target.count + slack

    // Only the tail is considered, and only as far back as the longest window
    // worth trying.
    let start = max(0, characters.count - longest)
    for begin in start..<characters.count {
      let remaining = characters.count - begin
      guard remaining >= shortest, remaining <= longest else {
        continue
      }
      let window = Array(characters[begin...])
      let distance = editDistance(window, target)
      let similarity = 1 - Double(distance) / Double(max(window.count, target.count))
      if similarity >= minimumSimilarity {
        return true
      }
    }
    return false
  }

  /// Levenshtein, two rows rather than a full matrix.
  ///
  /// The strings here are a handful of characters, so this is not about speed —
  /// it is about not allocating a matrix on every partial result the recogniser
  /// emits, which is several a second for as long as somebody is talking.
  static func editDistance(_ left: [Character], _ right: [Character]) -> Int {
    if left.isEmpty {
      return right.count
    }
    if right.isEmpty {
      return left.count
    }
    var previous = Array(0...right.count)
    var current = [Int](repeating: 0, count: right.count + 1)

    for i in 1...left.count {
      current[0] = i
      for j in 1...right.count {
        let substitution = previous[j - 1] + (left[i - 1] == right[j - 1] ? 0 : 1)
        current[j] = min(previous[j] + 1, current[j - 1] + 1, substitution)
      }
      swap(&previous, &current)
    }
    return previous[right.count]
  }
}
