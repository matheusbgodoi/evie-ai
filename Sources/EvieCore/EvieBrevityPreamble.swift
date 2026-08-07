import Foundation

/// A request for a short answer says how long the answer should be. It does not
/// say whether to go and look first.
///
/// The model reads it as though it did. Measured on 2026-08-07 against
/// `gemma-4-26b-a4b-it`, with the notes granted and the source-order rule in the
/// system prompt, asking about a company that has its own folder in the vault:
///
/// | question | tools called |
/// |---|---|
/// | `o que é a cluemed?` | `list_roots → search_content → search_content → read_file` |
/// | `me diga o que é a cluemed` | `list_roots → search_content` |
/// | `em uma frase, me diga o que é a cluemed` | **none** |
///
/// The same question, four words longer at the front, and she answers from
/// memory — then says she found no mention of it in notes that contain 534
/// passages about it. Once she produced an answer about a *different* company
/// and cited a note whose heading happens to be "1. Em uma frase".
///
/// Two attempts to fix this in the system prompt failed 3/3 each: one adding the
/// rule beside the source-order list, one putting it at the very end of the
/// prompt, which is the position this project has found carries most weight. The
/// preamble sits at the start of the user's own message and outweighs both.
///
/// So it is handled here instead of being asked for. When a question opens with
/// one of these, a reminder is appended *after* it — last thing the model reads,
/// and only on the turns that need it.
public enum EvieBrevityPreamble {
  /// Ways of asking for a short answer, as they are actually typed. Matched only
  /// at the start, because "explique em uma frase o que aconteceu" is the same
  /// instruction while "a resposta cabe em uma frase" is a statement about
  /// something else.
  static let openings = [
    "em uma frase",
    "em duas frases",
    "em poucas palavras",
    "em uma linha",
    "resumidamente",
    "resumindo",
    "rapidamente",
    "só me diz",
    "so me diz",
    "me diz rápido",
    "me diz rapido",
    "curto e grosso",
    "direto ao ponto",
  ]

  static let reminder =
    "(Isso diz o tamanho da resposta, não se você deve procurar. "
    + "Procure primeiro e resuma depois.)"

  /// The opening this question uses, if any.
  ///
  /// Case- and accent-insensitive, because it is typed in a hurry and often
  /// dictated. Leading punctuation and whitespace are skipped so that
  /// "- em uma frase: ..." is still recognised.
  public static func opening(of question: String) -> String? {
    let trimmed = question.drop { $0.isWhitespace || $0.isPunctuation }
    guard !trimmed.isEmpty else {
      return nil
    }
    let folded = String(trimmed).folding(
      options: [.diacriticInsensitive, .caseInsensitive],
      locale: Locale(identifier: "pt_BR")
    )
    return openings.first { folded.hasPrefix($0) }
  }

  /// The question as the model should receive it: unchanged, plus a reminder
  /// when one is warranted.
  ///
  /// The question itself is never rewritten. What the user typed is what she is
  /// asked, because a question quietly edited on the way in is a question nobody
  /// can debug — and because the length instruction is real and still has to be
  /// obeyed.
  public static func annotated(_ question: String) -> String {
    guard opening(of: question) != nil else {
      return question
    }
    return question + "\n\n" + reminder
  }
}
