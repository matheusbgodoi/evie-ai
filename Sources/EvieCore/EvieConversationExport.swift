import Foundation

/// Turns a stored conversation into a Markdown document.
///
/// Deliberately pure: no file system, no AppKit, no window. The interesting part
/// of an export is the text it produces, and that part is worth testing without
/// a save panel on screen.
///
/// The output targets an Obsidian vault, which is where the person who asked for
/// this keeps notes. That is why it opens with YAML front matter — in a vault a
/// file without front matter is just a wall of text, and with it the conversation
/// becomes something that can be searched, dated and linked.
public enum EvieConversationExport {
  /// The whole conversation as one Markdown document.
  public static func markdown(for conversation: EvieConversation) -> String {
    var lines: [String] = []

    lines.append("---")
    lines.append("title: \(yamlString(conversation.title))")
    lines.append("created: \(iso8601(conversation.createdAt))")
    lines.append("updated: \(iso8601(conversation.updatedAt))")
    lines.append("source: Evie")
    lines.append("---")
    lines.append("")
    lines.append("# \(headingText(conversation.title))")
    lines.append("")

    if conversation.messages.isEmpty {
      // An empty file would look like the export failed. Saying plainly that the
      // conversation held nothing is a fact, and a fact reads better than a blank
      // page in a vault full of notes.
      lines.append("Esta conversa não tem mensagens salvas.")
      lines.append("")
      return lines.joined(separator: "\n")
    }

    for message in conversation.messages {
      lines.append("## \(roleTitle(message.role))")
      lines.append("")
      lines.append("*\(iso8601(message.createdAt))*")
      lines.append("")
      lines.append(body(of: message))
      lines.append("")
    }

    return lines.joined(separator: "\n")
  }

  /// A file name that a file system will accept and a person will recognise.
  public static func fileName(for conversation: EvieConversation) -> String {
    "\(safeBaseName(from: conversation.title)).md"
  }

  // MARK: - Message bodies

  private static func body(of message: ChatMessage) -> String {
    switch message.role {
    case .assistant:
      // Evie already writes Markdown — headings, lists, fenced code. Escaping it
      // would turn a formatted answer into literal asterisks and backticks, so it
      // passes through exactly as it was stored.
      return message.content
    default:
      return quoted(message.content)
    }
  }

  /// Everything that did not come from Evie, wrapped so it cannot restructure the
  /// document.
  ///
  /// A person can type anything, including a line of three dashes. Pasted straight
  /// in, that reads as a second front-matter block or a horizontal rule and the
  /// note stops parsing the way it should. Prefixing every line with `> ` contains
  /// it: whatever the text does, it does inside the quote. A fence was the other
  /// option and was rejected because it kills wrapping — a long question would
  /// become a single unreadable line in an Obsidian pane.
  private static func quoted(_ content: String) -> String {
    let text = content.isEmpty ? "(sem texto)" : content
    return
      text
      .split(separator: "\n", omittingEmptySubsequences: false)
      .map { $0.isEmpty ? ">" : "> \($0)" }
      .joined(separator: "\n")
  }

  private static func roleTitle(_ role: ChatRole) -> String {
    switch role {
    case .user: "Você"
    case .assistant: "Evie"
    case .tool: "Ferramenta"
    case .system, .developer: "Política interna"
    }
  }

  // MARK: - Escaping

  /// A YAML double-quoted scalar, which is the one form that survives a title
  /// containing a colon, a quote or a leading dash.
  private static func yamlString(_ value: String) -> String {
    let collapsed = value.replacingOccurrences(of: "\n", with: " ")
    var escaped = ""
    for character in collapsed {
      switch character {
      case "\\": escaped += "\\\\"
      case "\"": escaped += "\\\""
      default: escaped.append(character)
      }
    }
    return "\"\(escaped)\""
  }

  /// A title is stored text too, so it cannot be trusted to stay on one line of a
  /// heading.
  private static func headingText(_ title: String) -> String {
    let collapsed =
      title
      .replacingOccurrences(of: "\n", with: " ")
      .trimmingCharacters(in: .whitespacesAndNewlines)
    return collapsed.isEmpty ? "Conversa" : collapsed
  }

  private static func iso8601(_ date: Date) -> String {
    let formatter = ISO8601DateFormatter()
    formatter.timeZone = TimeZone(secondsFromGMT: 0)
    formatter.formatOptions = [.withInternetDateTime]
    return formatter.string(from: date)
  }

  // MARK: - File names

  /// How many characters of a title survive into the file name.
  ///
  /// A title is generated from the first thing the person said and can run for a
  /// paragraph. HFS+ and APFS both stop at 255 bytes per component, and a name
  /// that long is unusable anyway, so it is cut well short of the limit.
  static let maximumBaseNameLength = 80

  private static func safeBaseName(from title: String) -> String {
    var cleaned = ""
    for character in title {
      // `/` is a path separator and `:` is one too as far as Finder is concerned;
      // control characters and newlines have no business in a file name.
      if character == "/" || character == ":" || character == "\\"
        || character.unicodeScalars.contains(where: { CharacterSet.controlCharacters.contains($0) })
      {
        cleaned.append("-")
      } else {
        cleaned.append(character)
      }
    }

    cleaned = cleaned.trimmingCharacters(in: .whitespacesAndNewlines)
    if cleaned.count > maximumBaseNameLength {
      cleaned = String(cleaned.prefix(maximumBaseNameLength))
        .trimmingCharacters(in: .whitespacesAndNewlines)
    }
    // A leading dot hides the file in Finder and in every shell, which is the one
    // way an export can succeed and still look like it did nothing.
    while cleaned.hasPrefix(".") {
      cleaned.removeFirst()
    }
    cleaned = cleaned.trimmingCharacters(in: .whitespacesAndNewlines)

    return cleaned.isEmpty ? "Conversa" : cleaned
  }
}
