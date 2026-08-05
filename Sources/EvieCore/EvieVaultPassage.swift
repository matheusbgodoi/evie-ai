import Foundation

/// A piece of a note, with enough around it to be understood alone.
///
/// The heading path is carried on every passage rather than left implicit, and it
/// is the single most useful thing in this type. A paragraph two screens into a
/// note about a company mentions "eles" and "a proposta" and nothing else; on its
/// own it matches no question and answers none. Prefixed with
/// "Cluemed › Captação › Eurofarma" it matches a question about Cluemed, and a
/// model reading it knows what "eles" refers to.
public struct EvieVaultPassage: Hashable, Sendable {
  /// The note's own name, without the extension.
  public var noteTitle: String
  /// Headings from the top of the note down to this passage.
  public var headingPath: [String]
  public var text: String
  /// Relative to the authorised folder, so it can be quoted back and reopened.
  public var path: String
  public var rootID: String

  public init(
    noteTitle: String,
    headingPath: [String] = [],
    text: String,
    path: String,
    rootID: String
  ) {
    self.noteTitle = noteTitle
    self.headingPath = headingPath
    self.text = text
    self.path = path
    self.rootID = rootID
  }

  /// Where this came from, written the way a person names a place in a document.
  public var breadcrumb: String {
    ([noteTitle] + headingPath).joined(separator: " › ")
  }

  /// What is matched against, and what is embedded.
  ///
  /// The context is part of the text on purpose. For word matching it means the
  /// note's title counts towards every passage in it, which is right — a note
  /// called "Cluemed" is about Cluemed throughout. For embedding it means the
  /// vector describes the passage *in its place* rather than as a floating
  /// sentence.
  public var searchableText: String {
    "\(breadcrumb)\n\(text)"
  }

  /// What the model receives.
  public var quoted: String {
    "[\(breadcrumb)]\n\(text)"
  }
}

/// Cuts a note into passages.
public enum EvieVaultChunker {
  /// About a paragraph and a half. Long enough to answer something, short enough
  /// that six of them fit in a prompt beside the question and the persona.
  public static let targetCharacters = 420
  public static let maximumCharacters = 900
  /// Below this a passage is a heading with nothing under it.
  public static let minimumCharacters = 40

  public static func chunk(
    markdown: String,
    path: String,
    rootID: String
  ) -> [EvieVaultPassage] {
    let title = ((path as NSString).lastPathComponent as NSString).deletingPathExtension
    var passages: [EvieVaultPassage] = []
    var headings: [String] = []
    var buffer = ""

    func flush() {
      let text = buffer.trimmingCharacters(in: .whitespacesAndNewlines)
      buffer = ""
      guard text.count >= minimumCharacters else {
        return
      }
      passages.append(
        EvieVaultPassage(
          noteTitle: title,
          headingPath: headings,
          text: String(text.prefix(maximumCharacters)),
          path: path,
          rootID: rootID
        )
      )
    }

    for rawLine in markdown.split(separator: "\n", omittingEmptySubsequences: false) {
      let line = String(rawLine)
      if let (level, heading) = Self.heading(in: line) {
        // A heading ends the passage before it and opens the next, so a passage
        // never straddles two sections.
        flush()
        headings = Array(headings.prefix(max(level - 1, 0)))
        headings.append(heading)
        continue
      }
      // Frontmatter delimiters and empty lines are not content.
      guard line != "---", !line.trimmingCharacters(in: .whitespaces).isEmpty else {
        continue
      }
      buffer += buffer.isEmpty ? line : "\n" + line
      if buffer.count >= targetCharacters {
        flush()
      }
    }
    flush()
    return passages
  }

  /// `## Título` becomes level 2 and "Título".
  static func heading(in line: String) -> (level: Int, text: String)? {
    guard line.hasPrefix("#") else {
      return nil
    }
    let hashes = line.prefix { $0 == "#" }.count
    guard hashes <= 6 else {
      return nil
    }
    let text = line.dropFirst(hashes).trimmingCharacters(in: .whitespaces)
    guard !text.isEmpty else {
      return nil
    }
    return (hashes, text)
  }

  /// The notes a passage points at, from `[[wikilinks]]`.
  ///
  /// A vault is a graph and the links were drawn by the person who wrote it —
  /// they are a better relevance signal than anything that can be inferred, and
  /// following one costs a local file read.
  public static func links(in markdown: String) -> [String] {
    var links: [String] = []
    var remainder = Substring(markdown)
    while let open = remainder.range(of: "[["),
      let close = remainder.range(of: "]]", range: open.upperBound..<remainder.endIndex)
    {
      let inner = remainder[open.upperBound..<close.lowerBound]
      // `[[Nota|texto mostrado]]` and `[[Nota#seção]]` both point at "Nota".
      let target = inner
        .split(separator: "|").first?
        .split(separator: "#").first
        .map(String.init)?
        .trimmingCharacters(in: .whitespaces)
      if let target, !target.isEmpty, !links.contains(target) {
        links.append(target)
      }
      remainder = remainder[close.upperBound...]
    }
    return links
  }
}
