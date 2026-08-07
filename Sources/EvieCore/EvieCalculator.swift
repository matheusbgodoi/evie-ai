import Foundation

/// One calculation, together with the reading that produced it.
///
/// `understood` exists because the reading is the part that can go wrong
/// silently. "1.234" is a thousand two hundred and thirty-four to a Brazilian
/// and one point two three four to a parser that guesses differently, and a
/// lone result hides which of the two happened. Numbers are rendered here
/// without grouping separators and with a dot decimal, so the reading is
/// unambiguous on sight.
public struct EvieCalculation: Hashable, Sendable {
  public var understood: String
  public var value: Double
  /// The result written the way it is read out loud here: dot for thousands,
  /// comma for the decimal.
  public var formattedValue: String

  public init(understood: String, value: Double, formattedValue: String) {
    self.understood = understood
    self.value = value
    self.formattedValue = formattedValue
  }
}

/// Every way a calculation can refuse.
///
/// There is no case that means "approximately". A model handed `NaN`, or
/// handed nothing, writes a plausible number in its place; a model handed a
/// sentence in Portuguese either fixes the expression or tells Matheus what
/// could not be computed.
public enum EvieCalculatorError: Error, Equatable, Sendable {
  case empty
  case tooLong
  case tooDeep
  case unexpectedCharacter(String)
  case unexpectedToken(String)
  case unbalancedParenthesis
  case ambiguousNumber(String)
  case unknownName(String)
  case wrongArgumentCount(String)
  case divisionByZero
  case outsideDomain(String)
  case overflow
}

/// A calculator with a grammar small enough to read in one sitting.
///
/// Deliberately not `NSExpression`. `NSExpression` parses function calls and
/// key paths, so feeding it a string a language model produced is closer to
/// running that string than to adding two numbers up. Everything below is a
/// hand-written recursive-descent parser over a fixed grammar: what is not in
/// the grammar cannot be evaluated, and the answer is a refusal rather than a
/// surprise.
///
/// Grammar, in the order the parser applies it:
///
///     expression  := additive
///     additive    := multiplicative (('+' | '-') multiplicative)*
///     multiplicative := unary (('*' | '/') unary)*
///     unary       := ('-' | '+') unary | power
///     power       := postfix ('^' unary)?          — right associative
///     postfix     := primary '%'*
///     primary     := number | name '(' arguments ')' | '(' expression ')'
///     arguments   := expression ((';' | ',') expression)*
public enum EvieCalculator {
  /// Long enough for any sum a person types, short enough that a pathological
  /// string cannot turn one tool call into real work.
  public static let maximumLength = 500
  /// Parenthesis nesting ceiling. Recursive descent recurses; a thousand open
  /// brackets from a confused model would otherwise take the process down with
  /// it.
  public static let maximumDepth = 32

  /// Functions of one argument, and what they do to it.
  ///
  /// `log` is base ten and `ln` is natural, said here because the two names get
  /// swapped between languages and a silent swap is a factor of 2.3 in the
  /// answer. Trigonometry is in radians.
  static let unaryFunctions = Set([
    "sqrt", "abs", "round", "floor", "ceil", "log", "ln", "sin", "cos", "tan",
  ])
  static let variadicFunctions = Set(["min", "max"])

  public static func evaluate(_ input: String) throws -> EvieCalculation {
    let normalized = normalize(input)
    guard !normalized.isEmpty else {
      throw EvieCalculatorError.empty
    }
    guard normalized.count <= maximumLength else {
      throw EvieCalculatorError.tooLong
    }

    if let change = try percentageChange(in: normalized) {
      return change
    }

    let node = try parse(normalized)
    let result = try value(of: node)
    return EvieCalculation(
      understood: render(node, parentPrecedence: 0),
      value: result,
      formattedValue: brazilianText(result)
    )
  }
}

// MARK: - Normalisation

extension EvieCalculator {
  /// Turns what a person or a model actually types into the fixed grammar.
  ///
  /// Every rule here is a rewrite with a single reading, never a guess about
  /// intent: a multiplication sign becomes a star, "por cento" becomes a
  /// percent sign. Anything left over that the grammar does not cover is
  /// refused rather than repaired.
  static func normalize(_ input: String) -> String {
    var text = input.lowercased()

    for (from, to) in [
      ("×", "*"), ("·", "*"), ("⋅", "*"),
      ("÷", "/"),
      ("−", "-"), ("–", "-"), ("—", "-"),
      ("√", "sqrt"),
      ("**", "^"),
      ("porcento", "%"), (" por cento", "%"),
      // "15% de 240" is multiplication once the percent sign has done its work.
      ("% de ", "% * "), ("% do ", "% * "), ("% da ", "% * "), ("% of ", "% * "),
      (" pra ", " para "),
    ] {
      text = text.replacingOccurrences(of: from, with: to)
    }

    // The model is asked for a bare expression and mostly gives one; these are
    // the openings it still writes, and dropping them costs nothing.
    for opening in [
      "quanto é ", "quanto e ", "quanto dá ", "quanto da ", "quanto fica ",
      "calcule ", "calcular ", "resultado de ", "quanto vale ",
    ] where text.hasPrefix(opening) {
      text = String(text.dropFirst(opening.count))
      break
    }

    text = text.trimmingCharacters(in: .whitespacesAndNewlines)
    while text.hasPrefix("=") {
      text = String(text.dropFirst()).trimmingCharacters(in: .whitespacesAndNewlines)
    }
    while text.hasSuffix("?") || text.hasSuffix("=") {
      text = String(text.dropLast()).trimmingCharacters(in: .whitespacesAndNewlines)
    }
    return text
  }
}

// MARK: - Percentage change

extension EvieCalculator {
  /// "de 80 para 100 é quantos %" — the one percentage question the grammar
  /// cannot express, because it is a relation between two numbers rather than
  /// an operator between them.
  ///
  /// Recognised only in this exact shape: a leading "de", a " para " in the
  /// middle, and two sides that each parse as an expression on their own.
  /// Anything looser would start capturing ordinary sums that happen to
  /// contain the word.
  static func percentageChange(in normalized: String) throws -> EvieCalculation? {
    guard normalized.hasPrefix("de "), let range = normalized.range(of: " para ") else {
      return nil
    }

    let left = String(normalized[normalized.index(normalized.startIndex, offsetBy: 3)..<range.lowerBound])
    let right = trimmingQuestion(String(normalized[range.upperBound...]))
    guard
      let fromNode = try? parse(left),
      let toNode = try? parse(right)
    else {
      return nil
    }

    let from = try value(of: fromNode)
    let to = try value(of: toNode)
    guard from != 0 else {
      // A change from zero has no percentage. Saying so beats an infinity.
      throw EvieCalculatorError.divisionByZero
    }

    let change = (to - from) / from * 100
    guard change.isFinite else {
      throw EvieCalculatorError.overflow
    }
    return EvieCalculation(
      understood: "variação percentual de \(render(fromNode, parentPrecedence: 0)) "
        + "para \(render(toNode, parentPrecedence: 0))",
      value: change,
      formattedValue: brazilianText(change) + "%"
    )
  }

  /// Removes the tail of the spoken question — "é quantos %" and its
  /// variations — so the second number can be parsed on its own.
  static func trimmingQuestion(_ text: String) -> String {
    var result = text.trimmingCharacters(in: .whitespacesAndNewlines)
    let tails = [
      "%", "?", "quantos", "quanto", "é", "e", "dá", "da", "de", "em", "isso",
      "aumento", "aumentou", "variação", "por",
    ]
    var changed = true
    while changed {
      changed = false
      for tail in tails where result.hasSuffix(tail) {
        result = String(result.dropLast(tail.count))
          .trimmingCharacters(in: .whitespacesAndNewlines)
        changed = true
        break
      }
    }
    return result
  }
}

// MARK: - Numbers

extension EvieCalculator {
  /// Reads one number written either way round.
  ///
  /// The rule, in full:
  ///
  /// - Both separators present: the **last** one is the decimal separator and
  ///   the other is grouping. `1.234,56` and `1,234.56` are both 1234.56.
  /// - Only commas: the comma is decimal. `1,5` is one and a half. A comma is
  ///   never grouping on its own, because this user writes Portuguese.
  /// - Only dots: a single dot with exactly three digits after it, a non-zero
  ///   digit before it and nothing after, is grouping — `1.234` is a thousand
  ///   two hundred and thirty-four. Every other dot is decimal: `1.5`,
  ///   `3.14159`, `0.500`.
  ///
  /// The one case this reads against a foreign convention is `1.234`, and it is
  /// exactly why `EvieCalculation.understood` exists: the reading is echoed
  /// back rather than assumed.
  ///
  /// Grouping is validated, not tolerated: `1.2345,6` is refused instead of
  /// being turned into some number nobody wrote.
  static func number(from raw: String) throws -> Double {
    let hasDot = raw.contains(".")
    let hasComma = raw.contains(",")

    if !hasDot && !hasComma {
      guard let value = Double(raw) else {
        throw EvieCalculatorError.ambiguousNumber(raw)
      }
      return value
    }

    let decimalSeparator: Character
    let groupingSeparator: Character?

    if hasDot && hasComma {
      decimalSeparator = raw.lastIndex(of: ".")! > raw.lastIndex(of: ",")! ? "." : ","
      groupingSeparator = decimalSeparator == "." ? "," : "."
    } else if hasComma {
      decimalSeparator = raw.filter({ $0 == "," }).count > 1 ? "\0" : ","
      groupingSeparator = decimalSeparator == "\0" ? "," : nil
    } else {
      let integerPart = raw.prefix(while: { $0 != "." })
      let afterLastDot = raw.suffix(from: raw.index(after: raw.lastIndex(of: ".")!))
      let looksGrouped =
        afterLastDot.count == 3 && afterLastDot.allSatisfy(\.isNumber)
        && integerPart.first != "0" && !integerPart.isEmpty
      if looksGrouped {
        decimalSeparator = "\0"
        groupingSeparator = "."
      } else {
        guard raw.filter({ $0 == "." }).count == 1 else {
          throw EvieCalculatorError.ambiguousNumber(raw)
        }
        decimalSeparator = "."
        groupingSeparator = nil
      }
    }

    let pieces = raw.split(separator: decimalSeparator, omittingEmptySubsequences: false)
    guard pieces.count <= 2 else {
      throw EvieCalculatorError.ambiguousNumber(raw)
    }
    let integerText = String(pieces.first ?? "")
    let fractionText = pieces.count == 2 ? String(pieces[1]) : ""
    guard !fractionText.contains(where: { !$0.isNumber }) else {
      throw EvieCalculatorError.ambiguousNumber(raw)
    }

    let digits: String
    if let groupingSeparator {
      let groups = integerText.split(separator: groupingSeparator, omittingEmptySubsequences: false)
      guard
        let first = groups.first,
        (1...3).contains(first.count),
        first.allSatisfy(\.isNumber),
        groups.dropFirst().allSatisfy({ $0.count == 3 && $0.allSatisfy(\.isNumber) })
      else {
        throw EvieCalculatorError.ambiguousNumber(raw)
      }
      digits = groups.joined()
    } else {
      guard integerText.isEmpty || integerText.allSatisfy(\.isNumber) else {
        throw EvieCalculatorError.ambiguousNumber(raw)
      }
      digits = integerText
    }

    let integerDigits = digits.isEmpty ? "0" : digits
    let plain = fractionText.isEmpty ? integerDigits : "\(integerDigits).\(fractionText)"
    guard let value = Double(plain), value.isFinite else {
      throw EvieCalculatorError.ambiguousNumber(raw)
    }
    return value
  }

  /// The result in Brazilian notation, without trailing noise.
  ///
  /// Floating point is written to ten decimal places and then trimmed, so
  /// 0,1 + 0,2 reads as 0,3 rather than as 0,30000000000000004. Ten places is
  /// past anything a person asks for and short of where the representation
  /// error starts showing.
  public static func brazilianText(_ value: Double) -> String {
    guard value.isFinite else {
      return "—"
    }
    guard value != 0 else {
      return "0"
    }

    let magnitude = abs(value)
    if magnitude >= 1e15 || magnitude < 1e-9 {
      return String(format: "%g", value).replacingOccurrences(of: ".", with: ",")
    }

    var text = String(format: "%.10f", value)
    while text.hasSuffix("0") {
      text.removeLast()
    }
    if text.hasSuffix(".") {
      text.removeLast()
    }

    var isNegative = false
    if text.hasPrefix("-") {
      isNegative = true
      text.removeFirst()
    }

    let pieces = text.split(separator: ".", maxSplits: 1)
    let integerDigits = Array(pieces.first ?? "0")
    let fraction = pieces.count == 2 ? String(pieces[1]) : ""

    var grouped = ""
    for (offset, digit) in integerDigits.enumerated() {
      if offset > 0, (integerDigits.count - offset) % 3 == 0 {
        grouped.append(".")
      }
      grouped.append(digit)
    }

    return (isNegative ? "-" : "") + grouped + (fraction.isEmpty ? "" : ",\(fraction)")
  }

  /// The same number written back for `understood`: dot decimal, no grouping,
  /// nothing to misread.
  static func plainText(_ value: Double) -> String {
    if value == value.rounded(), abs(value) < 1e15 {
      return String(Int64(value))
    }
    return String(format: "%.10g", value)
  }
}

// MARK: - Tokens

extension EvieCalculator {
  enum Token: Equatable {
    case number(Double)
    case name(String)
    case plus
    case minus
    case star
    case slash
    case caret
    case percent
    case openParenthesis
    case closeParenthesis
    case separator
  }

  /// Splits the text into tokens.
  ///
  /// The one rule worth stating: a comma belongs to a number only when it sits
  /// directly between two digits. Everywhere else it is an argument separator.
  /// That is what makes `max(1,5; 2)` and `max(1, 2)` both readable while the
  /// comma keeps its decimal meaning — and it makes `max(1,2)` one argument of
  /// one and two tenths, which `max` then refuses rather than quietly reading
  /// as two numbers.
  static func tokenize(_ text: String) throws -> [Token] {
    let characters = Array(text)
    var tokens: [Token] = []
    var index = 0

    while index < characters.count {
      let character = characters[index]

      if character.isWhitespace {
        index += 1
        continue
      }

      let startsNumber =
        character.isNumber
        || ((character == "." || character == ",")
          && index + 1 < characters.count && characters[index + 1].isNumber)

      if startsNumber {
        var raw = ""
        if !character.isNumber {
          raw.append(character)
          index += 1
        }
        while index < characters.count {
          let next = characters[index]
          if next.isNumber {
            raw.append(next)
            index += 1
          } else if (next == "." || next == ","),
            index > 0, characters[index - 1].isNumber,
            index + 1 < characters.count, characters[index + 1].isNumber
          {
            raw.append(next)
            index += 1
          } else {
            break
          }
        }
        tokens.append(.number(try number(from: raw)))
        continue
      }

      if character.isLetter {
        var name = ""
        while index < characters.count, characters[index].isLetter {
          name.append(characters[index])
          index += 1
        }
        tokens.append(.name(name))
        continue
      }

      index += 1
      switch character {
      case "+": tokens.append(.plus)
      case "-": tokens.append(.minus)
      case "*": tokens.append(.star)
      case "/": tokens.append(.slash)
      case "^": tokens.append(.caret)
      case "%": tokens.append(.percent)
      case "(": tokens.append(.openParenthesis)
      case ")": tokens.append(.closeParenthesis)
      case ";", ",": tokens.append(.separator)
      default: throw EvieCalculatorError.unexpectedCharacter(String(character))
      }
    }

    return tokens
  }
}

// MARK: - Syntax tree

extension EvieCalculator {
  indirect enum Node: Equatable {
    case number(Double)
    case negation(Node)
    /// A postfix `%`. Kept as its own node rather than folded into a division
    /// by a hundred, because `240 + 15%` means fifteen percent *of 240* and
    /// that is decided by the operator on its left.
    case percentage(Node)
    case addition(Node, Node)
    case subtraction(Node, Node)
    case multiplication(Node, Node)
    case division(Node, Node)
    case power(Node, Node)
    case call(String, [Node])
  }

  static func parse(_ text: String) throws -> Node {
    var parser = Parser(tokens: try tokenize(text))
    let node = try parser.parseExpression(depth: 0)
    guard parser.isFinished else {
      throw parser.leftoverError()
    }
    return node
  }

  struct Parser {
    var tokens: [Token]
    var index = 0

    var isFinished: Bool {
      index >= tokens.count
    }

    func peek() -> Token? {
      index < tokens.count ? tokens[index] : nil
    }

    func leftoverError() -> EvieCalculatorError {
      guard let token = peek() else {
        return .unexpectedToken("")
      }
      switch token {
      case .closeParenthesis: return .unbalancedParenthesis
      case .separator: return .unexpectedToken(";")
      default: return .unexpectedToken(EvieCalculator.describe(token))
      }
    }

    mutating func advance() -> Token? {
      guard index < tokens.count else {
        return nil
      }
      defer { index += 1 }
      return tokens[index]
    }

    mutating func parseExpression(depth: Int) throws -> Node {
      guard depth <= EvieCalculator.maximumDepth else {
        throw EvieCalculatorError.tooDeep
      }
      var left = try parseTerm(depth: depth)
      while let token = peek(), token == .plus || token == .minus {
        _ = advance()
        let right = try parseTerm(depth: depth)
        left = token == .plus ? .addition(left, right) : .subtraction(left, right)
      }
      return left
    }

    mutating func parseTerm(depth: Int) throws -> Node {
      var left = try parseUnary(depth: depth)
      while let token = peek(), token == .star || token == .slash {
        _ = advance()
        let right = try parseUnary(depth: depth)
        left = token == .star ? .multiplication(left, right) : .division(left, right)
      }
      return left
    }

    mutating func parseUnary(depth: Int) throws -> Node {
      guard depth <= EvieCalculator.maximumDepth else {
        throw EvieCalculatorError.tooDeep
      }
      if peek() == .minus {
        _ = advance()
        return .negation(try parseUnary(depth: depth + 1))
      }
      if peek() == .plus {
        _ = advance()
        return try parseUnary(depth: depth + 1)
      }
      return try parsePower(depth: depth)
    }

    mutating func parsePower(depth: Int) throws -> Node {
      let base = try parsePostfix(depth: depth)
      guard peek() == .caret else {
        return base
      }
      _ = advance()
      // Right associative, and the exponent goes through the unary rule so
      // 2^-1 is a number rather than a syntax error.
      return .power(base, try parseUnary(depth: depth + 1))
    }

    mutating func parsePostfix(depth: Int) throws -> Node {
      var node = try parsePrimary(depth: depth)
      while peek() == .percent {
        _ = advance()
        node = .percentage(node)
      }
      return node
    }

    mutating func parsePrimary(depth: Int) throws -> Node {
      guard depth <= EvieCalculator.maximumDepth else {
        throw EvieCalculatorError.tooDeep
      }
      guard let token = advance() else {
        throw EvieCalculatorError.unexpectedToken("")
      }
      switch token {
      case .number(let value):
        return .number(value)

      case .openParenthesis:
        let inner = try parseExpression(depth: depth + 1)
        guard advance() == .closeParenthesis else {
          throw EvieCalculatorError.unbalancedParenthesis
        }
        return inner

      case .name(let name):
        guard
          EvieCalculator.unaryFunctions.contains(name)
            || EvieCalculator.variadicFunctions.contains(name)
        else {
          throw EvieCalculatorError.unknownName(name)
        }
        guard advance() == .openParenthesis else {
          throw EvieCalculatorError.unexpectedToken(name)
        }
        var arguments = [try parseExpression(depth: depth + 1)]
        while peek() == .separator {
          _ = advance()
          arguments.append(try parseExpression(depth: depth + 1))
        }
        guard advance() == .closeParenthesis else {
          throw EvieCalculatorError.unbalancedParenthesis
        }
        return .call(name, arguments)

      default:
        throw EvieCalculatorError.unexpectedToken(EvieCalculator.describe(token))
      }
    }
  }

  static func describe(_ token: Token) -> String {
    switch token {
    case .number(let value): plainText(value)
    case .name(let name): name
    case .plus: "+"
    case .minus: "-"
    case .star: "*"
    case .slash: "/"
    case .caret: "^"
    case .percent: "%"
    case .openParenthesis: "("
    case .closeParenthesis: ")"
    case .separator: ";"
    }
  }
}

// MARK: - Evaluation

extension EvieCalculator {
  static func value(of node: Node) throws -> Double {
    let result: Double
    switch node {
    case .number(let value):
      result = value

    case .negation(let inner):
      result = -(try value(of: inner))

    case .percentage(let inner):
      result = try value(of: inner) / 100

    case .addition(let left, let right):
      let base = try value(of: left)
      result = base + (try relativeValue(of: right, relativeTo: base))

    case .subtraction(let left, let right):
      let base = try value(of: left)
      result = base - (try relativeValue(of: right, relativeTo: base))

    case .multiplication(let left, let right):
      result = try value(of: left) * (try value(of: right))

    case .division(let left, let right):
      let divisor = try value(of: right)
      guard divisor != 0 else {
        throw EvieCalculatorError.divisionByZero
      }
      result = try value(of: left) / divisor

    case .power(let base, let exponent):
      let baseValue = try value(of: base)
      let exponentValue = try value(of: exponent)
      guard baseValue >= 0 || exponentValue == exponentValue.rounded() else {
        throw EvieCalculatorError.outsideDomain("potência de base negativa com expoente fracionário")
      }
      result = pow(baseValue, exponentValue)

    case .call(let name, let arguments):
      result = try call(name, arguments)
    }

    guard result.isFinite else {
      throw EvieCalculatorError.overflow
    }
    return result
  }

  /// What the right-hand side of a `+` or a `-` is worth.
  ///
  /// This is the whole of the percentage convention: `240 + 15%` is 276, not
  /// 240,15, because everybody who types it means fifteen percent of what came
  /// before. Anywhere else — `240 * 15%`, a bare `15%` — a percent is simply a
  /// hundredth, which is the same convention read literally.
  static func relativeValue(of node: Node, relativeTo base: Double) throws -> Double {
    guard case .percentage(let inner) = node else {
      return try value(of: node)
    }
    return base * (try value(of: inner)) / 100
  }

  static func call(_ name: String, _ arguments: [Node]) throws -> Double {
    let values = try arguments.map { try value(of: $0) }

    if variadicFunctions.contains(name) {
      guard values.count >= 2 else {
        throw EvieCalculatorError.wrongArgumentCount(name)
      }
      return name == "min" ? values.min()! : values.max()!
    }

    guard values.count == 1, let argument = values.first else {
      throw EvieCalculatorError.wrongArgumentCount(name)
    }

    switch name {
    case "sqrt":
      guard argument >= 0 else {
        throw EvieCalculatorError.outsideDomain("raiz quadrada de número negativo")
      }
      return argument.squareRoot()
    case "abs": return abs(argument)
    case "round": return argument.rounded()
    case "floor": return argument.rounded(.down)
    case "ceil": return argument.rounded(.up)
    case "log":
      guard argument > 0 else {
        throw EvieCalculatorError.outsideDomain("logaritmo de número menor ou igual a zero")
      }
      return log10(argument)
    case "ln":
      guard argument > 0 else {
        throw EvieCalculatorError.outsideDomain("logaritmo de número menor ou igual a zero")
      }
      return log(argument)
    case "sin": return sin(argument)
    case "cos": return cos(argument)
    case "tan": return tan(argument)
    default:
      throw EvieCalculatorError.unknownName(name)
    }
  }
}

// MARK: - Rendering

extension EvieCalculator {
  static func precedence(of node: Node) -> Int {
    switch node {
    case .addition, .subtraction: 1
    case .multiplication, .division: 2
    case .negation: 3
    case .power: 4
    case .percentage: 5
    case .number, .call: 6
    }
  }

  /// Writes the tree back out, with a bracket exactly where the tree needs one.
  static func render(_ node: Node, parentPrecedence: Int) -> String {
    let own = precedence(of: node)
    let text: String

    switch node {
    case .number(let value):
      text = plainText(value)
    case .negation(let inner):
      text = "-" + render(inner, parentPrecedence: own)
    case .percentage(let inner):
      text = render(inner, parentPrecedence: own) + "%"
    case .addition(let left, let right):
      text = render(left, parentPrecedence: own) + " + " + render(right, parentPrecedence: own + 1)
    case .subtraction(let left, let right):
      text = render(left, parentPrecedence: own) + " - " + render(right, parentPrecedence: own + 1)
    case .multiplication(let left, let right):
      text = render(left, parentPrecedence: own) + " * " + render(right, parentPrecedence: own + 1)
    case .division(let left, let right):
      text = render(left, parentPrecedence: own) + " / " + render(right, parentPrecedence: own + 1)
    case .power(let base, let exponent):
      text = render(base, parentPrecedence: own + 1) + "^" + render(exponent, parentPrecedence: own)
    case .call(let name, let arguments):
      text = name + "(" + arguments.map { render($0, parentPrecedence: 0) }.joined(separator: "; ")
        + ")"
    }

    return own < parentPrecedence ? "(\(text))" : text
  }
}

// MARK: - Refusals in words

extension EvieCalculatorError: LocalizedError {
  public var errorDescription: String? {
    switch self {
    case .empty:
      "Não veio conta nenhuma para calcular."
    case .tooLong:
      "A expressão passou de \(EvieCalculator.maximumLength) caracteres. Quebre em contas menores."
    case .tooDeep:
      "Parênteses aninhados demais. Quebre em contas menores."
    case .unexpectedCharacter(let character):
      "\"\(character)\" não faz parte de uma conta. Use só números, + - * / ^ % "
        + "parênteses e as funções conhecidas."
    case .unexpectedToken(let token):
      token.isEmpty
        ? "A expressão termina no meio de uma conta."
        : "\"\(token)\" está fora de lugar na expressão."
    case .unbalancedParenthesis:
      "Os parênteses não fecham."
    case .ambiguousNumber(let raw):
      "Não dá para ler \"\(raw)\" como número sem adivinhar. Escreva de um jeito só: "
        + "vírgula decimal (1234,56) ou ponto decimal (1234.56)."
    case .unknownName(let name):
      "Não existe função chamada \(name). As que existem são sqrt, abs, round, floor, "
        + "ceil, log, ln, sin, cos, tan, min e max."
    case .wrongArgumentCount(let name):
      name == "min" || name == "max"
        ? "\(name) precisa de dois ou mais valores separados por ponto e vírgula: \(name)(1,5; 2)."
        : "\(name) recebe exatamente um valor."
    case .divisionByZero:
      "Divisão por zero — essa conta não tem resultado."
    case .outsideDomain(let reason):
      "Conta impossível: \(reason)."
    case .overflow:
      "O resultado é grande demais para ser representado."
    }
  }
}
