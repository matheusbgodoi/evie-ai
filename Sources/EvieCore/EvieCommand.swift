import Foundation

/// A command that can be typed into the field.
public struct EvieCommand: Identifiable, Equatable, Sendable {
  /// Written with its slash, so the one string is both what is matched and what
  /// is shown. Two representations of the same name is how they drift apart.
  public let name: String
  /// What goes after the command, for the placeholder shown beside it.
  public let argumentHint: String
  public let summary: String
  /// Said plainly next to the command, because this one costs minutes and
  /// finding that out by waiting is a bad way to find out.
  public let cost: String?

  public var id: String { name }

  public init(name: String, argumentHint: String, summary: String, cost: String? = nil) {
    self.name = name
    self.argumentHint = argumentHint
    self.summary = summary
    self.cost = cost
  }

  /// What the field should contain once this command is chosen: the name and a
  /// space, so the next keystroke is the question rather than a correction.
  public var completion: String {
    name + " "
  }
}

/// Every command Evie answers to.
///
/// One list, so a command cannot exist without being discoverable. `/plano` was
/// added before this and was invisible: there was no way to learn it existed
/// except being told, which is the same problem as a feature that does not exist.
public enum EvieCommandCatalogue {
  public static let all: [EvieCommand] = [
    EvieCommand(
      name: EviePlanCommand.name,
      argumentHint: "pergunta",
      summary: "Divide em etapas, faz uma de cada vez e responde no fim",
      cost: "minutos"
    ),
    EvieCommand(
      name: EvieVaultSearchCommand.name,
      argumentHint: "termo",
      summary: "Mostra os trechos das suas anotações, sem passar pelo modelo"
    ),
    EvieCommand(
      name: EvieWebCommand.name,
      argumentHint: "pergunta",
      summary: "Pula as anotações e responde a partir da web"
    )
  ]

  /// The commands worth offering for what has been typed so far.
  ///
  /// Empty for anything that is not the beginning of a command, which is most
  /// of what anybody types. In particular, once there is a space the command has
  /// been named and what follows is its argument — continuing to suggest there
  /// would put a menu over the field for the whole time a question is written.
  public static func suggestions(for input: String) -> [EvieCommand] {
    // Leading whitespace only. The trailing space is the whole signal that the
    // command has been named — trimming it made "/plano " look identical to
    // "/plano" and left the menu open over the question being typed.
    let written = input.drop(while: \.isWhitespace)
    guard written.hasPrefix("/"), !written.contains(where: \.isWhitespace) else {
      return []
    }
    let typed = fold(String(written))
    return all.filter { fold($0.name).hasPrefix(typed) }
  }

  /// Whether what has been typed is a complete, known command with nothing after
  /// it — the state in which pressing return should run it rather than complete
  /// it again.
  public static func isComplete(_ input: String) -> Bool {
    let trimmed = fold(input.trimmingCharacters(in: .whitespaces))
    return all.contains { fold($0.name) == trimmed }
  }

  static func fold(_ text: String) -> String {
    text.folding(
      options: [.diacriticInsensitive, .caseInsensitive],
      locale: Locale(identifier: "pt_BR")
    )
  }
}
