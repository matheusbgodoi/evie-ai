import Foundation

/// Reads the argument of a typed command.
///
/// Anchored at the start and requiring a boundary after the name, because that
/// is the whole difference between a command and a word somebody wrote. Without
/// the boundary "/website caiu" starts a web search for "site caiu" and
/// "/buscarei um jeito" searches the notes — a command that fires by accident is
/// worse than one that is hard to find, since the user cannot even tell what
/// happened.
public enum EvieSlashCommand {
  /// The text after `name`, or nil when this is not that command.
  ///
  /// An empty string means the command was typed with nothing after it, which is
  /// a different outcome from "not this command" and has to stay
  /// distinguishable: one deserves an explanation, the other deserves silence.
  public static func argument(after name: String, in input: String) -> String? {
    let trimmed = input.trimmingCharacters(in: .whitespacesAndNewlines)
    guard trimmed.lowercased().hasPrefix(name) else {
      return nil
    }
    let rest = String(trimmed.dropFirst(name.count))
    guard let first = rest.first else {
      return ""
    }
    guard first.isWhitespace else {
      return nil
    }
    return rest.trimmingCharacters(in: .whitespacesAndNewlines)
  }
}

/// Recognises the command that only searches the notes.
///
/// Every ordinary question pays for a full model turn before anything appears.
/// When the intent is to *find the note* rather than to be told something, that
/// turn buys nothing: the passages are the answer, and the model would only
/// paraphrase them. So this command stops at the retrieval and shows what came
/// back.
public enum EvieVaultSearchCommand {
  public static let name = "/buscar"

  /// What to look for, or nil when this is not that command.
  public static func query(in input: String) -> String? {
    EvieSlashCommand.argument(after: name, in: input)
  }
}

/// Recognises the command that skips the notes and goes to the web.
///
/// Evie's order is notes, then web, then what she already knows, and that order
/// is enforced by the code rather than asked of the model. This is the way to
/// say the first step is pointless for this question — the user already knows it
/// is not in his notes — without weakening the rule for every other question.
public enum EvieWebCommand {
  public static let name = "/web"

  /// The question to answer from the web, or nil when this is not that command.
  public static func question(in input: String) -> String? {
    EvieSlashCommand.argument(after: name, in: input)
  }
}

/// Writes what `/buscar` found onto the card.
///
/// Every passage keeps its breadcrumb, because the point of searching is to be
/// told *where* something is. An answer card that showed the text without the
/// note it came from would be the paraphrase this command exists to avoid.
public enum EvieVaultSearchReport {
  /// How much of a passage is shown. Passages run to 900 characters, and a
  /// screen of six of them is a wall rather than a result — enough to recognise
  /// the note is enough, and the note is one click away.
  static let maximumPassageCharacters = 320

  public static func text(for retrieved: [EvieRetrievedPassage], query: String) -> String {
    guard !retrieved.isEmpty else {
      // No model call here either. The user asked to search; an answer written
      // from memory and shown where a search result belongs would be a lie
      // about where the information came from.
      return """
        Não achei nada nas suas anotações sobre "\(query)".
        """
    }
    let heading =
      retrieved.count == 1
      ? "1 trecho sobre \"\(query)\":"
      : "\(retrieved.count) trechos sobre \"\(query)\":"
    let body = retrieved.map { found in
      "**\(found.passage.breadcrumb)**\n\(condensed(readable(found.passage.text)))"
    }
    return ([heading] + body).joined(separator: "\n\n")
  }

  /// A note as somebody would want to read it, rather than as it is stored.
  ///
  /// A vault is full of writing meant for an editor, not for a reader: a
  /// wikilink is a pair of brackets, a note opens with a block of YAML nobody
  /// asked to see, and a table degenerates into a row of pipes and dashes once
  /// it is out of its grid. None of that is the note; all of it was on screen.
  ///
  /// The maths is handled elsewhere, in `EvieRichText`, which every card runs
  /// its text through.
  static func readable(_ text: String) -> String {
    var body = Substring(text)

    // Front matter, but only when the note opens with it. A `---` in the middle
    // of a note is a horizontal rule and belongs to the writing.
    if body.hasPrefix("---\n"), let close = body.range(of: "\n---", range: body.index(body.startIndex, offsetBy: 3)..<body.endIndex) {
      body = body[close.upperBound...]
    }

    var result = String(body)
    // `[[Nota|como aparece]]` shows the label; `[[Nota]]` shows the name. Either
    // way the brackets are punctuation for Obsidian, not for a person.
    while let open = result.range(of: "[["), let close = result.range(of: "]]", range: open.upperBound..<result.endIndex) {
      let inner = result[open.upperBound..<close.lowerBound]
      let shown = inner.split(separator: "|").last.map(String.init) ?? String(inner)
      result.replaceSubrange(open.lowerBound..<close.upperBound, with: shown)
    }
    // A table separator carries no information once the table is gone.
    result = result
      .split(separator: "\n", omittingEmptySubsequences: false)
      .filter { !$0.allSatisfy { "|-: ".contains($0) } || $0.isEmpty }
      .joined(separator: "\n")

    return result.trimmingCharacters(in: .whitespacesAndNewlines)
  }

  /// The passage, cut at a word rather than mid-syllable when it is too long.
  static func condensed(_ text: String) -> String {
    let collapsed = text.trimmingCharacters(in: .whitespacesAndNewlines)
    guard collapsed.count > maximumPassageCharacters else {
      return collapsed
    }
    let cut = collapsed.prefix(maximumPassageCharacters)
    let atWord = cut.lastIndex(where: \.isWhitespace).map { cut[..<$0] } ?? cut
    return atWord.trimmingCharacters(in: .whitespacesAndNewlines) + "…"
  }
}
