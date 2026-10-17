import Foundation

/// Whether the person's own message asks for something to be saved.
///
/// The narrow gate of ADR 0019. With "Salvar direto quando eu pedir
/// explicitamente" switched on, a new document may be written without its card
/// being clicked — but only when this is true of the message the person typed
/// or said. Text that arrived from a document, a web page or the screen is never
/// what is read here: the caller passes the prompt and nothing else, and a turn
/// carrying a picture does not qualify at all (`EvieTurnPlan`).
///
/// Like `EvieChangeIntent` it is matching, not proof. It is safe enough for
/// this because what it unlocks is small: a new file in a folder already
/// granted, never an overwrite, a move or the Trash, and reported on screen
/// after it happens.
public enum EvieDocumentIntent {
  /// Phrases that mean "write this to a file". "grave" is left out on purpose:
  /// it is also the adjective, and "um erro grave" asks for nothing.
  static let phrases: [String] = [
    "salva", "salve", "salvar", "salvando",
    "grava", "gravar",
    "cria um arquivo", "crie um arquivo", "criar um arquivo",
    "cria um documento", "crie um documento", "criar um documento",
    "gera um arquivo", "gere um arquivo", "gerar um arquivo",
    "faz um arquivo", "faca um arquivo", "fazer um arquivo",
  ]

  /// Whether this message asks for something to be saved.
  public static func isPresent(in message: String) -> Bool {
    let text = EvieChangeIntent.fold(message)
    guard !text.isEmpty else {
      return false
    }
    return phrases.contains { phrase in
      EvieChangeIntent.contains(text, word: phrase) && !isNegated(phrase, in: text)
    }
  }

  /// "não salva", "nao salve": a request not to.
  static func isNegated(_ phrase: String, in text: String) -> Bool {
    ["nao ", "nem ", "sem "].contains { EvieChangeIntent.contains(text, word: $0 + phrase) }
  }
}
