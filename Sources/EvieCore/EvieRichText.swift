import Foundation

/// One piece of a model answer, already separated from its syntax.
public enum EvieRichTextBlock: Hashable, Sendable {
  case heading(level: Int, text: String)
  case paragraph(String)
  case bullet(level: Int, text: String)
  case numbered(level: Int, number: Int, text: String)
  case code(language: String?, text: String)
  case rule
}

/// A model answer, parsed so the interface can render it and the clipboard can
/// receive it clean.
///
/// Local models write markdown and occasionally LaTeX whether or not they are
/// asked to. Asking them not to helps and does not settle it, so the syntax is
/// dealt with here: `###` becomes a heading rather than three visible hashes,
/// `$\rightarrow$` becomes `→`, and what lands on the clipboard has no markers at
/// all.
public struct EvieRichText: Hashable, Sendable {
  public let blocks: [EvieRichTextBlock]

  public init(_ raw: String) {
    blocks = Self.parse(raw)
  }

  /// The answer as text a person would want pasted somewhere: no hashes, no
  /// asterisks, no backticks, bullets as bullets, nesting preserved by indent.
  public var plainText: String {
    var lines: [String] = []

    for block in blocks {
      switch block {
      case .heading(_, let text):
        if !lines.isEmpty {
          lines.append("")
        }
        lines.append(Self.strippedInlineMarkers(text))
      case .paragraph(let text):
        if !lines.isEmpty {
          lines.append("")
        }
        lines.append(Self.strippedInlineMarkers(text))
      case .bullet(let level, let text):
        lines.append(
          String(repeating: "    ", count: level) + "• " + Self.strippedInlineMarkers(text)
        )
      case .numbered(let level, let number, let text):
        lines.append(
          String(repeating: "    ", count: level) + "\(number). "
            + Self.strippedInlineMarkers(text)
        )
      case .code(_, let text):
        if !lines.isEmpty {
          lines.append("")
        }
        // Code is content, not syntax: it is copied exactly as written.
        lines.append(text)
      case .rule:
        lines.append("")
      }
    }

    return
      lines
      .joined(separator: "\n")
      .trimmingCharacters(in: .whitespacesAndNewlines)
  }

  public var isEmpty: Bool {
    blocks.isEmpty
  }
}

extension EvieRichText {
  fileprivate static func parse(_ raw: String) -> [EvieRichTextBlock] {
    var blocks: [EvieRichTextBlock] = []
    var paragraph: [String] = []
    var codeLines: [String] = []
    var codeLanguage: String?
    var isInsideCode = false

    func flushParagraph() {
      let joined = paragraph.joined(separator: " ").trimmingCharacters(in: .whitespaces)
      paragraph.removeAll()
      guard !joined.isEmpty else {
        return
      }
      blocks.append(.paragraph(joined))
    }

    for rawLine in raw.replacingOccurrences(of: "\r\n", with: "\n").split(
      separator: "\n",
      omittingEmptySubsequences: false
    ) {
      let line = String(rawLine)
      let trimmed = line.trimmingCharacters(in: .whitespaces)

      if trimmed.hasPrefix("```") {
        if isInsideCode {
          blocks.append(.code(language: codeLanguage, text: codeLines.joined(separator: "\n")))
          codeLines.removeAll()
          codeLanguage = nil
          isInsideCode = false
        } else {
          flushParagraph()
          let language = String(trimmed.dropFirst(3)).trimmingCharacters(in: .whitespaces)
          codeLanguage = language.isEmpty ? nil : language
          isInsideCode = true
        }
        continue
      }
      if isInsideCode {
        codeLines.append(line)
        continue
      }

      let converted = latexConverted(trimmed)

      if converted.isEmpty {
        flushParagraph()
        continue
      }
      if isRule(converted) {
        flushParagraph()
        blocks.append(.rule)
        continue
      }
      if let heading = heading(from: converted) {
        flushParagraph()
        blocks.append(heading)
        continue
      }
      if let bullet = bullet(from: line, converted: converted) {
        flushParagraph()
        blocks.append(bullet)
        continue
      }
      if let numbered = numbered(from: line, converted: converted) {
        flushParagraph()
        blocks.append(numbered)
        continue
      }

      paragraph.append(converted)
    }

    if isInsideCode, !codeLines.isEmpty {
      blocks.append(.code(language: codeLanguage, text: codeLines.joined(separator: "\n")))
    }
    flushParagraph()
    return blocks
  }

  fileprivate static func isRule(_ line: String) -> Bool {
    let characters = Set(line)
    return line.count >= 3 && (characters == ["-"] || characters == ["*"] || characters == ["_"])
  }

  fileprivate static func heading(from line: String) -> EvieRichTextBlock? {
    if line.hasPrefix("#") {
      let hashes = line.prefix { $0 == "#" }.count
      let rest = String(line.dropFirst(hashes)).trimmingCharacters(in: .whitespaces)
      // `#tag` mid-text is not a heading; a heading has a space after its hashes.
      guard hashes <= 6, line.dropFirst(hashes).first == " ", !rest.isEmpty else {
        return nil
      }
      return .heading(level: hashes, text: strippedInlineMarkers(rest))
    }

    // A line that is entirely bold is a heading trying to happen. Models produce
    // these constantly — "**1. Segmentação:**" on its own line — and rendering the
    // asterisks is never what was meant.
    if line.hasPrefix("**"), line.hasSuffix("**"), line.count > 4 {
      let inner = String(line.dropFirst(2).dropLast(2))
      guard !inner.contains("**"), inner.count <= 90 else {
        return nil
      }
      return .heading(level: 4, text: inner)
    }
    return nil
  }

  fileprivate static func bullet(from original: String, converted: String) -> EvieRichTextBlock? {
    let markers = ["* ", "- ", "+ ", "•\u{20}"]
    guard let marker = markers.first(where: { converted.hasPrefix($0) }) else {
      return nil
    }
    let text = String(converted.dropFirst(marker.count)).trimmingCharacters(in: .whitespaces)
    guard !text.isEmpty else {
      return nil
    }
    return .bullet(level: indentationLevel(of: original), text: text)
  }

  fileprivate static func numbered(from original: String, converted: String)
    -> EvieRichTextBlock?
  {
    let digits = converted.prefix { $0.isNumber }
    guard !digits.isEmpty, digits.count <= 3, let number = Int(digits) else {
      return nil
    }
    let rest = converted.dropFirst(digits.count)
    guard rest.hasPrefix(". ") || rest.hasPrefix(") ") else {
      return nil
    }
    let text = String(rest.dropFirst(2)).trimmingCharacters(in: .whitespaces)
    guard !text.isEmpty else {
      return nil
    }
    return .numbered(level: indentationLevel(of: original), number: number, text: text)
  }

  /// Four spaces, or one tab, is one level — but models indent with two just as
  /// often, so the arithmetic rounds up from two rather than demanding four.
  fileprivate static func indentationLevel(of line: String) -> Int {
    var spaces = 0
    for character in line {
      if character == " " {
        spaces += 1
      } else if character == "\t" {
        spaces += 4
      } else {
        break
      }
    }
    return min((spaces + 2) / 4, 4)
  }

  /// Removes emphasis, code, and link syntax, leaving the words.
  static func strippedInlineMarkers(_ text: String) -> String {
    var result = text

    // Links: [rótulo](url) keeps the label, which is what a reader wants pasted.
    result = result.replacingOccurrences(
      of: #"\[([^\]]+)\]\([^)]*\)"#,
      with: "$1",
      options: .regularExpression
    )
    for marker in ["***", "**", "*", "__", "_", "`", "~~"] {
      result = result.replacingOccurrences(of: marker, with: "")
    }
    return result.trimmingCharacters(in: .whitespaces)
  }
}

// MARK: - LaTeX

extension EvieRichText {
  /// Commands worth rendering as the character they stand for. Anything outside
  /// this list still loses its delimiters, because a stray backslash in the
  /// middle of a sentence is worse than a missing symbol.
  fileprivate static let latexSymbols: [String: String] = [
    "rightarrow": "→", "to": "→", "Rightarrow": "⇒", "implies": "⇒",
    "leftarrow": "←", "Leftarrow": "⇐", "leftrightarrow": "↔",
    "times": "×", "div": "÷", "pm": "±", "cdot": "·",
    "leq": "≤", "le": "≤", "geq": "≥", "ge": "≥", "neq": "≠", "ne": "≠",
    "approx": "≈", "equiv": "≡", "sim": "∼", "propto": "∝",
    "infty": "∞", "partial": "∂", "nabla": "∇", "sum": "∑", "prod": "∏",
    "int": "∫", "sqrt": "√", "forall": "∀", "exists": "∃", "in": "∈",
    "subset": "⊂", "cup": "∪", "cap": "∩", "emptyset": "∅",
    "alpha": "α", "beta": "β", "gamma": "γ", "delta": "δ", "epsilon": "ε",
    "theta": "θ", "lambda": "λ", "mu": "μ", "pi": "π", "sigma": "σ",
    "phi": "φ", "omega": "ω", "Delta": "Δ", "Sigma": "Σ", "Omega": "Ω",
    "degree": "°", "circ": "°", "ldots": "…", "dots": "…",
  ]

  /// Turns LaTeX fragments into readable characters.
  ///
  /// A lone `$` is left alone: in Brazilian text it is nearly always currency,
  /// and `R$ 1.234,56` must survive untouched.
  static func latexConverted(_ line: String) -> String {
    var result = line

    for (open, close) in [("\\(", "\\)"), ("\\[", "\\]")] {
      result = replacingDelimited(result, open: open, close: close)
    }
    result = replacingDollarMath(result)
    return result
  }

  fileprivate static func replacingDelimited(
    _ text: String,
    open: String,
    close: String
  ) -> String {
    var result = ""
    var rest = Substring(text)

    while let start = rest.range(of: open) {
      result += rest[rest.startIndex..<start.lowerBound]
      let afterOpen = rest[start.upperBound...]
      guard let end = afterOpen.range(of: close) else {
        result += rest[start.lowerBound...]
        return result
      }
      result += renderedMath(String(afterOpen[afterOpen.startIndex..<end.lowerBound]))
      rest = afterOpen[end.upperBound...]
    }
    return result + rest
  }

  /// Only converts `$…$` when the content actually looks like mathematics —
  /// that is, when it contains a backslash command.
  fileprivate static func replacingDollarMath(_ text: String) -> String {
    var result = ""
    var rest = Substring(text)

    while let start = rest.firstIndex(of: "$") {
      let afterDollar = rest[rest.index(after: start)...]
      guard let end = afterDollar.firstIndex(of: "$") else {
        break
      }
      let inner = afterDollar[afterDollar.startIndex..<end]
      guard inner.contains("\\") else {
        result += rest[rest.startIndex...start]
        rest = afterDollar
        continue
      }
      result += rest[rest.startIndex..<start]
      result += renderedMath(String(inner))
      rest = afterDollar[afterDollar.index(after: end)...]
    }
    return result + rest
  }

  fileprivate static func renderedMath(_ body: String) -> String {
    var result = ""
    var rest = Substring(body)

    while let backslash = rest.firstIndex(of: "\\") {
      result += rest[rest.startIndex..<backslash]
      let afterBackslash = rest[rest.index(after: backslash)...]
      let name = afterBackslash.prefix { $0.isLetter }
      if let symbol = latexSymbols[String(name)] {
        result += symbol
      }
      rest = afterBackslash[name.endIndex...]
    }
    result += rest

    // Whatever plumbing is left is not worth showing.
    return
      result
      .replacingOccurrences(of: "{", with: "")
      .replacingOccurrences(of: "}", with: "")
      .replacingOccurrences(of: "_", with: "")
      .replacingOccurrences(of: "^", with: "")
      .trimmingCharacters(in: .whitespaces)
  }
}

extension EvieRichText {
  /// The answer split into what a voice should say, one sentence at a time.
  ///
  /// Chunking is what lets the first words start while the rest is still being
  /// synthesised, and what makes an interruption land within a sentence instead
  /// of at the end of a paragraph. Code blocks are skipped: reading punctuation
  /// aloud helps nobody.
  public var spokenSentences: [String] {
    var spoken: [String] = []

    for block in blocks {
      switch block {
      case .code, .rule:
        continue
      case .heading(_, let text), .paragraph(let text):
        spoken.append(contentsOf: Self.sentences(in: Self.strippedInlineMarkers(text)))
      case .bullet(_, let text):
        spoken.append(contentsOf: Self.sentences(in: Self.strippedInlineMarkers(text)))
      case .numbered(_, _, let text):
        spoken.append(contentsOf: Self.sentences(in: Self.strippedInlineMarkers(text)))
      }
    }
    return spoken
  }

  /// Splits on sentence ends, and further on length, so no single utterance is so
  /// long that stopping it feels unresponsive.
  static func sentences(in text: String) -> [String] {
    let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !trimmed.isEmpty else {
      return []
    }

    var sentences: [String] = []
    var current = ""
    for character in trimmed {
      current.append(character)
      if character == "." || character == "!" || character == "?" || character == ":" {
        let candidate = current.trimmingCharacters(in: .whitespaces)
        // "R$ 1.234,56" and "3.5" are not sentence ends.
        if candidate.count > 12 || character != "." {
          sentences.append(candidate)
          current = ""
        }
      }
    }
    let tail = current.trimmingCharacters(in: .whitespaces)
    if !tail.isEmpty {
      sentences.append(tail)
    }

    return sentences.flatMap(Self.splitLongSentence)
  }

  private static func splitLongSentence(_ sentence: String) -> [String] {
    let limit = 220
    guard sentence.count > limit else {
      return [sentence]
    }
    var parts: [String] = []
    var current = ""
    for word in sentence.split(separator: " ") {
      if current.count + word.count + 1 > limit, !current.isEmpty {
        parts.append(current)
        current = ""
      }
      current += current.isEmpty ? String(word) : " \(word)"
    }
    if !current.isEmpty {
      parts.append(current)
    }
    return parts
  }
}
