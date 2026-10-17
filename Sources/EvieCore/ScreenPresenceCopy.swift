import Foundation

/// What the presence pill says, and what VoiceOver announces, for each thing
/// Evie can be doing on the screen.
///
/// Kept beside the machine rather than in the view because one part of it is
/// not wording: the label of the element about to be pressed comes from the
/// Accessibility tree of someone else's app — or from a web page — and can be
/// empty, multi-line or a paragraph long. It is shown, never interpreted, but
/// shown badly it either says nothing or pushes Parar off the pill.
public enum ScreenPresenceCopy {
  /// The most characters of an element's label the pill shows.
  public static let labelLimit = 32

  public static let seeing = "Evie está vendo sua tela"
  public static let paused = "Pausado — você assumiu"
  public static let stopped = "Parado"
  public static let succeeded = "Pronto"
  public static let failed = "Algo deu errado"
  public static let copied = "Copiado para a área de transferência"
  public static let typingChip = "Digitando…"

  /// "Evie está observando · passo 3", with the action budget when the loop
  /// has one ("passo 3/25").
  public static func observing(step: Int, of total: Int?) -> String {
    let progress = total.map { "\(step)/\($0)" } ?? "\(step)"
    return "Evie está observando · passo \(progress)"
  }

  /// "Evie vai clicar em ‘Enviar’", or "Evie vai clicar" when the element has
  /// no label worth showing.
  public static func acting(label: String?) -> String {
    guard let label = shownLabel(label) else {
      return "Evie vai clicar"
    }
    return "Evie vai clicar em ‘\(label)’"
  }

  public static func typing(app: String) -> String {
    let name = collapsedWhitespace(app)
    return name.isEmpty ? "Evie está digitando" : "Evie está digitando em \(name)"
  }

  /// The label on one line, cut to `labelLimit` characters with an ellipsis.
  /// Counted in characters rather than scalars, so a flag or an accented
  /// letter is never split in half at the cut.
  private static func shownLabel(_ label: String?) -> String? {
    guard let label else {
      return nil
    }
    let line = collapsedWhitespace(label)
    guard !line.isEmpty else {
      return nil
    }
    guard line.count > labelLimit else {
      return line
    }
    return String(line.prefix(labelLimit - 1)) + "…"
  }

  private static func collapsedWhitespace(_ text: String) -> String {
    text.split(whereSeparator: \.isWhitespace).joined(separator: " ")
  }
}
