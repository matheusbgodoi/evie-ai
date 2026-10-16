/// Separates a `<think>…</think>` trace written inside the answer text from the
/// answer.
///
/// A server that does not parse reasoning out (llama.cpp with
/// `--reasoning-format none`, or a template that thinks by default, such as
/// LensVLM's) streams the trace inline. Without this it would be shown and
/// spoken as the answer. Tags arrive split across deltas — `<thi` in one, `nk>`
/// in the next — so a suffix that could still become a tag is held back until
/// the next delta settles it.
///
/// Only a trace that **opens** the content counts, which is where a template
/// puts it; leading whitespace is allowed. Anywhere else the tag is the answer
/// talking about it ("o Qwen usa a tag `<think>`…"), and treating it as a trace
/// would hide the rest of the answer — all of it when no `</think>` follows,
/// ending the turn empty. After the trace closes, everything is answer. A server
/// that sends reasoning in its own field (the PC gateway's `reasoning_content`)
/// has already parsed the trace out, so `noteSeparateReasoning()` turns the
/// splitting off for the rest of the stream.
struct InlineThinkingSplitter {
  enum Piece: Equatable {
    case answer(String)
    case reasoning(String)
  }

  private enum Mode {
    /// Nothing but whitespace, or the start of an opening tag, has arrived.
    case undecided
    case thinking
    case answering
  }

  private static let opening = "<think>"
  private static let closing = "</think>"

  private var mode = Mode.undecided
  private var pending = ""
  /// Set after a closing tag: the newlines a template puts between the trace and
  /// the answer are not part of the answer.
  private var dropsLeadingNewlines = false

  /// The server reports reasoning apart from the content, so the content is the
  /// answer as written, an opening tag included.
  mutating func noteSeparateReasoning() {
    if mode == .undecided {
      mode = .answering
    }
  }

  mutating func consume(_ text: String) -> [Piece] {
    var buffer = pending + text
    pending = ""
    var pieces: [Piece] = []

    if mode == .undecided {
      let start = buffer.drop { $0.isWhitespace }
      if start.hasPrefix(Self.opening) {
        // The whitespace before a template's trace is framing, not answer.
        buffer = String(start.dropFirst(Self.opening.count))
        mode = .thinking
      } else if Self.opening.hasPrefix(start) {
        // Empty, or a tag still arriving: the next delta decides.
        pending = buffer
        return []
      } else {
        mode = .answering
      }
    }

    if mode == .thinking {
      if let range = buffer.range(of: Self.closing) {
        append(String(buffer[..<range.lowerBound]), to: &pieces)
        buffer = String(buffer[range.upperBound...])
        mode = .answering
        dropsLeadingNewlines = true
      } else {
        let held = Self.partialTagLength(at: buffer, of: Self.closing)
        append(String(buffer.dropLast(held)), to: &pieces)
        pending = String(buffer.suffix(held))
        return pieces
      }
    }

    append(buffer, to: &pieces)
    return pieces
  }

  /// What is left when the stream ends. A partial tag that never completed is
  /// ordinary text of whichever kind surrounds it; content that never got past
  /// whitespace or `<thi` is answer.
  mutating func finish() -> [Piece] {
    var pieces: [Piece] = []
    if mode == .undecided {
      mode = .answering
    }
    append(pending, to: &pieces)
    pending = ""
    return pieces
  }

  private mutating func append(_ text: String, to pieces: inout [Piece]) {
    var text = text
    if mode == .thinking {
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
