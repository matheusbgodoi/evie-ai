import Foundation

/// A stretch of text from one page, and where it came from.
public struct EvieWebPassage: Hashable, Sendable {
  public var text: String
  public var source: String
  /// How well it answered the question. Only meaningful after ranking.
  public var score: Double

  public init(text: String, source: String, score: Double = 0) {
    self.text = text
    self.source = source
    self.score = score
  }
}

/// Picks the parts of a page that answer the question, and throws the rest away.
///
/// The version this replaces took the first 3,500 characters of the first result.
/// That is the worst of both worlds: the opening of a page is menu, cookie
/// banner, "skip to content" and author biography, while the paragraph that
/// answers the question may sit at character six thousand and never be sent at
/// all. It paid a large prompt for navigation and still risked missing the
/// answer.
///
/// The question is already known, so instead of taking a prefix it is possible to
/// take the passages that match. That is not a trade — the prompt gets smaller
/// *and* more relevant at the same time — and it makes room to read three pages
/// instead of one, so a single bad result stops deciding the answer.
///
/// Ranking is BM25 with a coverage bonus, which is well understood, runs in
/// microseconds, needs no model and no index, and can be tested against text
/// rather than against a vector store.
///
/// Measured on the same question and the same network. Taking a prefix: 3,500
/// characters from one page, whose first hundred and fifty were "Home Linux
/// Tutoriais Linux Comandos Linux Distribuições…". Selecting passages: 1,872
/// characters from three sites, every one of them prose about the question.
/// End to end that moved the prompt from 4,054 tokens to 2,450 and the turn from
/// 82.6 s to 58.6 s.
///
/// Worth knowing where the rest of that time goes, because it bounds how much
/// more this is worth optimising: fetching and ranking is 1.8 s of the 58.6 s.
/// The remainder is the model reading its own instructions and writing a
/// three-hundred-token answer. Trimming the evidence further would buy very
/// little; the levers that remain are the size of the persona and the length of
/// the answer.
public enum EvieWebPassages {
  /// Roughly a paragraph. Long enough to carry an argument, short enough that a
  /// handful of them fit in a prompt without displacing the conversation.
  public static let targetPassageCharacters = 420
  /// A hard ceiling per passage, so one enormous unbroken block cannot swallow
  /// the whole budget.
  public static let maximumPassageCharacters = 700
  /// A line shorter than this in words is navigation, a tag, or a date.
  public static let minimumWordsPerLine = 4

  /// Splits a page into candidate passages.
  public static func extract(fromHTML html: String, source: String) -> [EvieWebPassage] {
    let body = mainContent(of: html)
    let lines =
      EvieWebSearch.readableText(fromHTML: body)
      .split(separator: "\n")
      .map { $0.trimmingCharacters(in: .whitespaces) }
      .filter { $0.split(separator: " ").count >= minimumWordsPerLine }

    var passages: [EvieWebPassage] = []
    var current = ""
    for line in lines {
      // A line longer than the ceiling on its own becomes its own passage rather
      // than being merged into something even longer.
      if line.count >= maximumPassageCharacters {
        if !current.isEmpty {
          passages.append(EvieWebPassage(text: current, source: source))
          current = ""
        }
        passages.append(
          EvieWebPassage(text: String(line.prefix(maximumPassageCharacters)), source: source)
        )
        continue
      }
      if current.isEmpty {
        current = line
      } else if current.count + line.count + 1 <= maximumPassageCharacters {
        current += " " + line
      } else {
        passages.append(EvieWebPassage(text: current, source: source))
        current = line
      }
      if current.count >= targetPassageCharacters {
        passages.append(EvieWebPassage(text: current, source: source))
        current = ""
      }
    }
    if !current.isEmpty {
      passages.append(EvieWebPassage(text: current, source: source))
    }
    return passages
  }

  /// The part of the page that is the page, rather than the site around it.
  ///
  /// `<article>` and `<main>` are what most publishers actually mark up, and when
  /// one is present the rest of the document is furniture. When neither is there
  /// the whole body is used, with the obvious chrome elements removed — the
  /// ranking then sorts out what is left, which it does well because navigation
  /// does not contain the words of the question.
  static func mainContent(of html: String) -> String {
    var stripped = html
    for element in ["script", "style", "noscript", "svg", "head", "nav", "footer", "aside", "form"] {
      stripped = EvieWebSearch.removingElement(element, from: stripped)
    }
    for element in ["article", "main"] {
      if let inner = innerContent(of: element, in: stripped), inner.count > 200 {
        return inner
      }
    }
    return stripped
  }

  /// What is inside the first element with this name.
  ///
  /// Nesting is counted, so an inner `<article>` inside an outer one cannot end
  /// the outer early. Searching is done over ranges of the original string rather
  /// than over copied substrings, because mapping indices between the two is
  /// where this kind of scan goes quietly wrong.
  static func innerContent(of name: String, in html: String) -> String? {
    guard let open = EvieWebSearch.openingTag(name, in: html),
      let tagClose = html[open.upperBound...].firstIndex(of: ">")
    else {
      return nil
    }
    let start = html.index(after: tagClose)

    var depth = 1
    var searchFrom = start
    while searchFrom < html.endIndex {
      let scope = searchFrom..<html.endIndex
      guard
        let close = html.range(of: "</\(name)>", options: .caseInsensitive, range: scope)
      else {
        return nil
      }
      let nextOpen = openingTag(name, in: html, from: searchFrom)

      if let nextOpen, nextOpen.lowerBound < close.lowerBound {
        depth += 1
        searchFrom = nextOpen.upperBound
        continue
      }
      depth -= 1
      if depth == 0 {
        return String(html[start..<close.lowerBound])
      }
      searchFrom = close.upperBound
    }
    return nil
  }

  /// `EvieWebSearch.openingTag` searched from the beginning; this searches from a
  /// point, which is what counting nesting needs.
  static func openingTag(
    _ name: String,
    in html: String,
    from index: String.Index
  ) -> Range<String.Index>? {
    var searchFrom = index
    while searchFrom < html.endIndex,
      let candidate = html.range(
        of: "<\(name)",
        options: .caseInsensitive,
        range: searchFrom..<html.endIndex
      )
    {
      let next = candidate.upperBound
      guard next < html.endIndex else {
        return nil
      }
      if [">", " ", "/", "\n", "\t", "\r"].contains(String(html[next])) {
        return candidate
      }
      searchFrom = next
    }
    return nil
  }
}
