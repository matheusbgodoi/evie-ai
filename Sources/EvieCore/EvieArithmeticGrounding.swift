import Foundation

/// Does the arithmetic in the question before the model is asked anything.
///
/// `EvieCalculatorTool` exists and is declared on every turn, and the persona
/// tells her in capitals to send every sum to it. That is the same shape of
/// instruction as "search before you answer", which this model declined twice —
/// see the comment above `EvieGrounding`. The calculator was built with the same
/// expectation written down: obeyed maybe half the time, and least often on the
/// easy sums that motivated it.
///
/// So the sum is done here, before the first completion, and the result arrives
/// as evidence next to the question. The tool stays declared for everything this
/// file deliberately does not catch.
///
/// The judgement here is the opposite of `EvieGrounding`'s. Looking something up
/// unnecessarily costs seconds and returns noise she can ignore; calculating
/// something unnecessarily puts a *number* in front of her, and a number is the
/// one kind of evidence a model will use whether or not it was asked for. "Você
/// pode me lembrar do artigo 5 da lei 8.078?" answered with "= 8083" is worse
/// than no grounding at all. So this only fires on shapes that are arithmetic
/// and cannot plausibly be anything else.
public enum EvieArithmeticGrounding {
  /// A question with more expressions than this is a pasted table or a list of
  /// figures, not a question with sums in it. Grounding four of its numbers
  /// would flood the turn with arithmetic nobody asked for, and picking which
  /// four is a guess — so past the ceiling nothing is grounded.
  public static let maximumExpressions = 4

  /// Every sum found in the question, in the order they were written.
  public static func calculations(in question: String) -> [EvieCalculation] {
    let folded = EvieGrounding.fold(question)
    guard folded.contains(where: \.isNumber) else {
      // No digits, no arithmetic. Cheap, and it is the common case.
      return []
    }

    // A message that is *entirely* an expression needs no other evidence that a
    // sum was wanted: "1200/16" and "de 80 para 100 é quantos %" are asking to
    // be computed and nothing else. The raw question goes to the calculator,
    // whose own normalisation already strips "quanto é" and a trailing "?".
    if !isDateShaped(trimmingPunctuation(folded)),
      let whole = try? EvieCalculator.evaluate(question),
      isComputation(whole)
    {
      return [whole]
    }

    return embedded(in: folded)
  }

  /// The evidence, or nothing when the question had no sum in it.
  ///
  /// Says both the expression and the result, in that order, for the same reason
  /// `EvieCalculatorTool` does: the reading is the part that goes wrong silently.
  /// A result on its own hides which question was answered, and here the
  /// expression was pulled out of a sentence by this file rather than typed by
  /// anybody — so the reading is a claim that has to be checkable.
  public static func findings(for question: String) -> String? {
    let calculations = calculations(in: question)
    guard !calculations.isEmpty else {
      return nil
    }
    let lines = calculations
      .map { "\($0.understood) = \($0.formattedValue)" }
      .joined(separator: "\n")
    return """
      Contas que já foram feitas na calculadora, antes de você responder. Cada \
      linha diz a conta como ela foi lida na pergunta e o resultado dela:

      \(lines)

      Use estes números como estão — não refaça a conta de cabeça e não \
      arredonde sem dizer. A conta foi extraída da pergunta automaticamente: se \
      o que está escrito acima não é o que o Matheus perguntou, diga isso em vez \
      de responder com o número.
      """
  }
}

// MARK: - Expressions inside a sentence

extension EvieArithmeticGrounding {
  /// The characters an expression can be made of. Everything else ends a
  /// candidate, which is what keeps "HTTP/2" and "1920x1080" from becoming sums.
  static let alphabet = Set("0123456789.,+-*/^%() ")

  /// Symbols that only ever mean arithmetic.
  ///
  /// `-` and `/` are missing on purpose: "IC 25-26", "de 10 - 15 minutos" and
  /// "12/08" are all this user's own writing, and all three evaluate cleanly.
  /// A span whose only operators are those two needs a word in the question
  /// saying a calculation was wanted.
  static let unambiguousOperators = Set("*%^+")

  /// Words that say a calculation is being asked for.
  ///
  /// Deliberately without "quanto custa" and "quanto tem": those are questions
  /// about the world, which `EvieGrounding` already sends to the notes and the
  /// web.
  static let cues = [
    "quanto e ", "quanto sao ", "quanto da ", "quanto fica ", "quanto vale ",
    "quanto que e ", "calcule", "calcular", "calcula ", "resultado de", "some ",
    "somar", "soma de", "somando", "subtraia", "subtrair", "multiplique",
    "multiplicar", "multiplicado", "vezes", "divida ", "dividir", "dividido",
    "elevado a", "media de", "media entre", "por cento", "porcento", "quantos %",
  ]

  /// Rewrites that hold whatever the sentence is about: a multiplication sign is
  /// a multiplication sign, and "15% de 3400" is a product in any context.
  static let symbolRewrites = [
    ("×", "*"), ("·", "*"), ("⋅", "*"), ("÷", "/"),
    ("−", "-"), ("–", "-"), ("—", "-"),
    ("% de ", "% * "), ("% do ", "% * "), ("% da ", "% * "),
    ("% dos ", "% * "), ("% das ", "% * "),
  ]

  /// Rewrites applied only when the question said a calculation was wanted.
  ///
  /// Ungated they would be a disaster: "mais de 100 pessoas" and "fui lá 3
  /// vezes" are not sums, and " x " is a letter far more often than it is a
  /// multiplication sign.
  static let wordRewrites = [
    (" dividido por ", " / "), (" dividido pra ", " / "),
    (" dividido entre ", " / "), (" dividido ", " / "), (" sobre ", " / "),
    (" multiplicado por ", " * "), (" vezes ", " * "), (" x ", " * "),
    (" elevado a ", " ^ "), (" somado com ", " + "), (" mais ", " + "),
    (" menos ", " - "),
  ]

  static func embedded(in folded: String) -> [EvieCalculation] {
    // Read before rewriting, because rewriting eats the cue: " vezes " becomes
    // " * " and the evidence that a sum was asked for goes with it.
    let hasCue = cues.contains(where: folded.contains)

    var text = folded
    for (from, to) in symbolRewrites {
      text = text.replacingOccurrences(of: from, with: to)
    }
    if hasCue {
      for (from, to) in wordRewrites {
        text = text.replacingOccurrences(of: from, with: to)
      }
    }

    let characters = Array(text)
    var found: [EvieCalculation] = []
    var seen = Set<String>()
    var index = 0

    while index < characters.count {
      guard alphabet.contains(characters[index]) else {
        index += 1
        continue
      }
      let start = index
      while index < characters.count, alphabet.contains(characters[index]) {
        index += 1
      }

      var lower = start
      var upper = index
      while lower < upper, characters[lower] == " " || characters[lower] == "," {
        lower += 1
      }
      while upper > lower, [" ", ",", "."].contains(characters[upper - 1]) {
        // Sentence punctuation, not an operator: "faça 3 * 4." is still a sum.
        upper -= 1
      }
      guard lower < upper else {
        continue
      }

      // A candidate touching a letter is part of a word, not a sum: the "/2" in
      // "HTTP/2" and the "3" in "MG996R" both die here.
      let before = lower > 0 ? characters[lower - 1] : " "
      let after = upper < characters.count ? characters[upper] : " "
      guard !before.isLetter, !after.isLetter else {
        continue
      }

      let span = String(characters[lower..<upper])
      guard span.contains(where: \.isNumber), !isDateShaped(span) else {
        continue
      }
      guard hasCue || span.contains(where: unambiguousOperators.contains) else {
        continue
      }
      // A refusal is a dropped candidate, never a failed turn and never a
      // complaint handed to the model. The calculator refusing means this file
      // read the sentence wrong — "20% do faturamento" becomes "20% *" and
      // stops there — and an apology about an expression the user never typed
      // would be noise he has to decode.
      guard let calculation = try? EvieCalculator.evaluate(span),
        isComputation(calculation),
        seen.insert(calculation.understood).inserted
      else {
        continue
      }
      found.append(calculation)
      if found.count > maximumExpressions {
        return []
      }
    }

    return found
  }
}

// MARK: - What counts

extension EvieArithmeticGrounding {
  /// Whether anything was actually computed.
  ///
  /// A number that was merely written down is not a sum, and this is the rule
  /// that keeps "o artigo 5 da lei 8.078" and "R$ 1.234,56" out: both parse,
  /// neither has an operator between two operands. Two numbers is the test, not
  /// the presence of an operator symbol, because "50%" carries an operator and
  /// still computes nothing anybody asked about.
  ///
  /// A name in the reading — `sqrt(...)`, or the percentage-change form — is a
  /// computation on its own and passes with one number.
  static func isComputation(_ calculation: EvieCalculation) -> Bool {
    let understood = calculation.understood
    if understood.contains(where: \.isLetter) {
      return true
    }
    var numbers = 0
    var insideNumber = false
    for character in understood {
      if character.isNumber {
        if !insideNumber {
          numbers += 1
          insideNumber = true
        }
      } else {
        insideNumber = false
      }
    }
    return numbers >= 2
  }

  /// A date wearing a division sign.
  ///
  /// Only the shapes that cannot be read any other way: three parts, or a
  /// zero-padded part. "2/3" is left alone — it is as likely to be a fraction as
  /// a date, and a bare date without a cue is already refused for having only
  /// `/` as its operator.
  static func isDateShaped(_ text: String) -> Bool {
    let parts = text.split(separator: "/", omittingEmptySubsequences: false)
    guard parts.count == 2 || parts.count == 3 else {
      return false
    }
    guard parts.allSatisfy({ (1...4).contains($0.count) && $0.allSatisfy(\.isNumber) }) else {
      return false
    }
    if parts.count == 3 {
      return true
    }
    return parts.contains { $0.count == 2 && $0.first == "0" }
  }

  static func trimmingPunctuation(_ text: String) -> String {
    var result = text
    while let last = result.last, last == "?" || last == "." || last == "!" || last == " " {
      result.removeLast()
    }
    return result
  }
}
