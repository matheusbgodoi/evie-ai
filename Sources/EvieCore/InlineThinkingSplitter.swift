/// Separates `<think>…</think>` written inside the answer text from the answer.
///
/// A server that does not parse reasoning out (llama.cpp with
/// `--reasoning-format none`, or a template that thinks by default, such as
/// LensVLM's) streams the trace inline. Without this it would be shown and
/// spoken as the answer. Tags arrive split across deltas — `<thi` in one, `nk>`
/// in the next — so a suffix that could still become a tag is held back until
/// the next delta settles it.
struct InlineThinkingSplitter {
  enum Piece: Equatable {
    case answer(String)
    case reasoning(String)
  }

  private static let opening = "<think>"
  private static let closing = "</think>"

  private var isThinking = false
  private var pending = ""
  /// Set after a closing tag: the newlines a template puts between the trace and
  /// the answer are not part of the answer.
  private var dropsLeadingNewlines = false

  mutating func consume(_ text: String) -> [Piece] {
    var buffer = pending + text
    pending = ""
    var pieces: [Piece] = []

    while !buffer.isEmpty {
      let tag = isThinking ? Self.closing : Self.opening
      if let range = buffer.range(of: tag) {
        append(String(buffer[..<range.lowerBound]), to: &pieces)
        buffer = String(buffer[range.upperBound...])
        isThinking.toggle()
        dropsLeadingNewlines = !isThinking
        continue
      }
      let held = Self.partialTagLength(at: buffer, of: tag)
      append(String(buffer.dropLast(held)), to: &pieces)
      pending = String(buffer.suffix(held))
      break
    }
    return pieces
  }

  /// What is left when the stream ends. A partial tag that never completed is
  /// ordinary text of whichever kind surrounds it.
  mutating func finish() -> [Piece] {
    var pieces: [Piece] = []
    append(pending, to: &pieces)
    pending = ""
    return pieces
  }

  private mutating func append(_ text: String, to pieces: inout [Piece]) {
    var text = text
    if isThinking {
      if !text.isEmpty { pieces.append(.reasoning(text)) }
      return
    }
    if dropsLeadingNewlines {
      text = String(text.drop { $0 == "\n" || $0 == "\r\n" })
      dropsLeadingNewlines = text.isEmpty
    }
    if !text.isEmpty { pieces.append(.answer(text)) }
  }

  /// The length of the longest suffix of `text` that is a proper prefix of `tag`.
  private static func partialTagLength(at text: String, of tag: String) -> Int {
    for length in stride(from: min(tag.count - 1, text.count), to: 0, by: -1)
    where text.hasSuffix(String(tag.prefix(length))) {
      return length
    }
    return 0
  }
}
