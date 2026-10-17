import Foundation

/// Whether a question is about the person's files: a folder, a document, a
/// place on the Mac, or saving something.
///
/// It decides routing, not permission. A question it recognises goes to the
/// tool-using agent loop even when no folder has been granted yet, because
/// that is how "o que tem na minha mesa?" reaches `list_roots` and the card that
/// asks for the Desktop — answered without tools, it could only be told that
/// she cannot look. A false positive costs a tool declaration; a false
/// negative costs the feature.
public enum EvieFileIntent {
  /// Words that put a question on the disk.
  static let words: Set<String> = [
    "pasta", "pastas", "arquivo", "arquivos", "documento", "documentos", "pdf", "pdfs",
    "docx", "planilha", "planilhas", "finder", "anexo",
  ]

  /// Document names written out: "resumo.docx", "aula 3.pdf".
  static let namedFile = try? NSRegularExpression(
    pattern: #"\.(pdf|docx?|txt|md|rtf|odt|pptx?|xlsx?|csv|pages|key|numbers)\b"#,
    options: [.caseInsensitive]
  )

  public static func isPresent(in message: String) -> Bool {
    let folded = EvieChangeIntent.fold(message)
    guard !folded.isEmpty else {
      return false
    }
    let tokens = folded.components(separatedBy: CharacterSet.letters.inverted)
    if tokens.contains(where: words.contains) {
      return true
    }
    if !EvieSuggestedRoot.mentioned(in: message).isEmpty
      || EvieDocumentIntent.isPresent(in: message)
    {
      return true
    }
    let range = NSRange(folded.startIndex..., in: folded)
    return namedFile?.firstMatch(in: folded, range: range) != nil
  }
}
