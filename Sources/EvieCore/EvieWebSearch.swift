import Foundation

/// One result from a search.
public struct EvieSearchResult: Identifiable, Hashable, Sendable {
  public var id: String { url }
  public var title: String
  public var url: String
  public var snippet: String

  public init(title: String, url: String, snippet: String) {
    self.title = title
    self.url = url
    self.snippet = snippet
  }
}

/// Turns a search engine's HTML into results, and a page into readable text.
///
/// Parsing lives here, away from the network, because it is the part that breaks
/// when an engine changes its markup and the part worth having tests for. The
/// network half is in the shell.
///
/// Everything this produces is hostile input. A web page is the least trustworthy
/// text Evie will ever see — it is written by strangers, it can be crafted for
/// her specifically, and it arrives looking like an answer. It is fenced as data
/// exactly like a file's contents, and it can reach no tool that changes
/// anything, because no such tool exists.
public enum EvieWebSearch {
  /// How many results are worth handing a model. More than this fills the context
  /// with pages nobody will open.
  public static let maximumResults = 6
  /// How much of a page is read. Enough for an article's substance, bounded so
  /// one page cannot displace the conversation.
  public static let maximumPageCharacters = 12_000
  public static let maximumSnippetCharacters = 320

  /// Parses DuckDuckGo's HTML endpoint.
  ///
  /// Chosen because it needs no account, no key, and no quota — anything else
  /// would mean the user signing up for something to ask a question. The cost is
  /// that it is markup rather than an API, so it can change without notice; that
  /// is why it is parsed leniently and why an empty result set is reported as
  /// "found nothing" rather than treated as a crash.
  public static func parseResults(from html: String) -> [EvieSearchResult] {
    var results: [EvieSearchResult] = []
    var remainder = Substring(html)

    while results.count < maximumResults,
      let anchorRange = remainder.range(of: "class=\"result__a\"")
    {
      // The class may appear before the address inside the same tag, so the text
      // starts after the tag closes, not after the class. Reading from the class
      // put the raw `href` into the title.
      let afterClass = remainder[anchorRange.upperBound...]
      guard
        let href = attribute("href", inTagEndingAt: remainder, anchorAt: anchorRange),
        let tagClose = afterClass.firstIndex(of: ">")
      else {
        remainder = afterClass
        continue
      }
      let afterAnchor = afterClass[afterClass.index(after: tagClose)...]
      guard let titleEnd = afterAnchor.range(of: "</a>") else {
        remainder = afterAnchor
        continue
      }

      let title = strippingTags(String(afterAnchor[..<titleEnd.lowerBound]))
      let snippet = firstSnippet(in: afterAnchor[titleEnd.upperBound...])
      remainder = afterAnchor[titleEnd.upperBound...]

      guard let url = resolve(href), !title.isEmpty else {
        continue
      }
      results.append(
        EvieSearchResult(
          title: title,
          url: url,
          snippet: String(snippet.prefix(maximumSnippetCharacters))
        )
      )
    }
    return results
  }

  /// The readable text of a page, with the furniture removed.
  ///
  /// Scripts and styles are dropped rather than stripped of tags, because their
  /// contents are not prose and would otherwise arrive as a wall of minified
  /// JavaScript where the article should be.
  public static func readableText(fromHTML html: String) -> String {
    var text = html
    for element in ["script", "style", "noscript", "svg", "head"] {
      text = removingElement(element, from: text)
    }
    // Block-level tags become line breaks so paragraphs survive as paragraphs.
    for tag in ["</p>", "</div>", "</li>", "</h1>", "</h2>", "</h3>", "<br>", "<br/>", "<br />"] {
      text = text.replacingOccurrences(of: tag, with: "\n", options: .caseInsensitive)
    }
    text = strippingTags(text)
    text = decodingEntities(text)

    let lines =
      text
      .split(separator: "\n", omittingEmptySubsequences: false)
      .map { $0.trimmingCharacters(in: .whitespaces) }
      .filter { !$0.isEmpty }
    return String(lines.joined(separator: "\n").prefix(maximumPageCharacters))
  }

  /// The results as the model receives them.
  public static func describe(_ results: [EvieSearchResult], query: String) -> String {
    guard !results.isEmpty else {
      return "A busca por \"\(query)\" não trouxe resultado nenhum."
    }
    let lines = results.enumerated().map { index, result in
      """
      \(index + 1). \(result.title)
         \(result.url)
         \(result.snippet)
      """
    }
    return """
      Resultados para "\(query)". Isto é o que a web diz, não o que é verdade — \
      abra uma página com read_page antes de afirmar qualquer coisa, e diga de \
      onde veio.
      \(lines.joined(separator: "\n"))
      """
  }
}

extension EvieWebSearch {
  /// DuckDuckGo wraps every result in a redirect carrying the real address in
  /// `uddg`. The real one is what a person needs to see.
  static func resolve(_ href: String) -> String? {
    let decoded = decodingEntities(href)
    guard decoded.contains("uddg=") else {
      return decoded.hasPrefix("http") ? decoded : nil
    }
    guard
      let range = decoded.range(of: "uddg="),
      let value = decoded[range.upperBound...]
        .split(separator: "&")
        .first?
        .removingPercentEncoding
    else {
      return nil
    }
    return value.hasPrefix("http") ? value : nil
  }

  static func attribute(
    _ name: String,
    inTagEndingAt html: Substring,
    anchorAt range: Range<Substring.Index>
  ) -> String? {
    // The attribute may sit either side of the class, so the whole tag is
    // searched backwards from the class to the opening bracket.
    guard let tagStart = html[..<range.lowerBound].range(of: "<", options: .backwards) else {
      return nil
    }
    guard let tagEnd = html[range.upperBound...].firstIndex(of: ">") else {
      return nil
    }
    let tag = html[tagStart.lowerBound...tagEnd]
    guard let attributeRange = tag.range(of: "\(name)=\"") else {
      return nil
    }
    let rest = tag[attributeRange.upperBound...]
    guard let end = rest.firstIndex(of: "\"") else {
      return nil
    }
    return String(rest[..<end])
  }

  static func firstSnippet(in html: Substring) -> String {
    guard let start = html.range(of: "class=\"result__snippet\"") else {
      return ""
    }
    let rest = html[start.upperBound...]
    guard let open = rest.firstIndex(of: ">"),
      let close = rest.range(of: "</a>") ?? rest.range(of: "</div>")
    else {
      return ""
    }
    let inner = rest[rest.index(after: open)..<close.lowerBound]
    return strippingTags(String(inner))
  }

  /// Removes an element and everything inside it.
  ///
  /// The opening tag has to be matched with its delimiter. Matching `<head` on
  /// its own also matches `<header>`, and since there is no `</head>` after a
  /// header the removal ran to the end of the document — a real page came back as
  /// the fifteen characters that preceded it.
  static func removingElement(_ name: String, from html: String) -> String {
    var output = html
    while let start = openingTag(name, in: output) {
      guard
        let end = output.range(
          of: "</\(name)>",
          options: .caseInsensitive,
          range: start.upperBound..<output.endIndex
        )
      else {
        output.removeSubrange(start.lowerBound..<output.endIndex)
        break
      }
      output.removeSubrange(start.lowerBound..<end.upperBound)
    }
    return output
  }

  /// The next opening tag for exactly this element name.
  static func openingTag(_ name: String, in html: String) -> Range<String.Index>? {
    var searchStart = html.startIndex
    while let candidate = html.range(
      of: "<\(name)",
      options: .caseInsensitive,
      range: searchStart..<html.endIndex
    ) {
      let next = candidate.upperBound
      guard next < html.endIndex else {
        return nil
      }
      let following = html[next]
      // `<head>` and `<head class=…>` are the element; `<header>` is not.
      if following == ">" || following == " " || following == "/" || following == "\n"
        || following == "\t" || following == "\r"
      {
        return candidate
      }
      searchStart = next
    }
    return nil
  }

  static func strippingTags(_ html: String) -> String {
    var output = ""
    var insideTag = false
    for character in html {
      switch character {
      case "<": insideTag = true
      case ">": insideTag = false
      default:
        if !insideTag {
          output.append(character)
        }
      }
    }
    return decodingEntities(output).trimmingCharacters(in: .whitespacesAndNewlines)
  }

  static func decodingEntities(_ text: String) -> String {
    var output = text
    let entities = [
      ("&amp;", "&"), ("&lt;", "<"), ("&gt;", ">"), ("&quot;", "\""),
      ("&#x27;", "'"), ("&#39;", "'"), ("&nbsp;", " "), ("&hellip;", "…"),
      ("&mdash;", "—"), ("&ndash;", "–"),
    ]
    for (entity, character) in entities {
      output = output.replacingOccurrences(of: entity, with: character)
    }
    return output
  }
}

/// Reaching the web, from the loop's point of view.
///
/// A protocol so the network stays in the shell and the loop can be tested
/// without one. It is optional everywhere: with no implementation, the tools are
/// simply not offered, and Evie is told she cannot search — which is the truth
/// when the user has left the switch off.
public protocol EvieWebSearching: Sendable {
  func search(_ query: String) async throws -> [EvieSearchResult]
  func read(_ address: String) async throws -> String
  /// Search, read the best few results, and return only the passages that match.
  /// This is what grounding uses; `search` and `read` remain for the tools the
  /// model calls itself.
  func gather(_ query: String, pages: Int, passages: Int) async throws -> [EvieWebPassage]
}

extension EvieWebSearching {
  /// A backend that can only search and read still grounds, one page at a time.
  public func gather(_ query: String, pages: Int, passages: Int) async throws
    -> [EvieWebPassage]
  {
    let results = try await search(query)
    guard let first = results.first else {
      return []
    }
    let text = try await read(first.url)
    return EviePassageRanker.rank(
      EvieWebPassages.extract(fromHTML: text, source: first.url),
      for: query,
      limit: passages
    )
  }
}

/// The two things Evie may do on the web, both of them reading.
public enum EvieWebTool: String, CaseIterable, Sendable {
  case search = "search_web"
  case read = "read_page"

  public static var definitions: [EvieToolDefinition] {
    [
      EvieToolDefinition(
        name: EvieWebTool.search.rawValue,
        summary: """
          Procura na web. Use quando a resposta depender de algo atual, de um \
          fato que você não tem certeza, ou de algo que mudou depois do seu \
          treinamento. Devolve títulos, endereços e trechos — não o conteúdo. \
          Para afirmar qualquer coisa, abra a página com read_page primeiro.
          """,
        parameters: [
          EvieToolParameter(
            name: "query",
            type: .string,
            summary: "O que procurar, em poucas palavras específicas.",
            isRequired: true
          )
        ]
      ),
      EvieToolDefinition(
        name: EvieWebTool.read.rawValue,
        summary: """
          Abre uma página e devolve o texto dela. Use o endereço exato que veio \
          de search_web — não invente endereços, eles não funcionam.
          """,
        parameters: [
          EvieToolParameter(
            name: "url",
            type: .string,
            summary: "O endereço completo, começando com https://",
            isRequired: true
          )
        ]
      ),
    ]
  }
}
