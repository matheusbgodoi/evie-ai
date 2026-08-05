import Foundation

/// Something Evie has been taught how to do.
///
/// A skill is instructions, not code. That is the whole design decision, and it
/// is what makes skills safe to install and worth having: a skill teaches her how
/// to use the abilities she already has — read a folder, search the web, look at
/// an image — for a particular kind of job. It cannot reach anything the tools
/// cannot, so installing one adds no new authority to the system.
///
/// The alternative, a skill that carries a command to run, would be far more
/// powerful and would hand a file the ability to execute. Given that this project
/// spends most of its effort making sure no tool the model can call changes
/// anything, adding a tool whose whole purpose is running arbitrary code would
/// undo it. If that ever becomes necessary it should be a separate mechanism with
/// its own confirmation, not a field on this one.
///
/// Written as markdown with frontmatter so a skill can be authored anywhere — a
/// text editor, or the Obsidian vault this user already lives in — and dropped
/// into a folder.
public struct EvieSkill: Identifiable, Hashable, Sendable {
  public var id: String
  public var name: String
  /// What the skill is for, in the words a question would use. This is what
  /// decides whether it loads, so it is written as trigger words rather than as
  /// a description.
  public var when: String
  /// The instructions themselves.
  public var instructions: String
  public var isEnabled: Bool
  /// Where it came from, so the list can say which ones were written by hand.
  public var fileName: String

  public init(
    id: String,
    name: String,
    when: String,
    instructions: String,
    isEnabled: Bool = true,
    fileName: String = ""
  ) {
    self.id = id
    self.name = name
    self.when = when
    self.instructions = instructions
    self.isEnabled = isEnabled
    self.fileName = fileName
  }

  /// The longest a single skill may be.
  ///
  /// Everything loaded is paid for in the prompt of the turn that loaded it. A
  /// skill that runs to pages is a document, and documents belong in the vault
  /// where she can search them.
  public static let maximumInstructionCharacters = 4_000

  /// Reads a skill from a markdown file with frontmatter.
  ///
  /// Lenient on purpose: the keys are accepted in Portuguese or English, because
  /// a skill that silently fails to load because `quando` was written `when` is a
  /// worse experience than a parser with four extra lines in it.
  public static func parse(_ text: String, fileName: String) -> EvieSkill? {
    var name = (fileName as NSString).deletingPathExtension
    var when = ""
    var body = text

    if text.hasPrefix("---") {
      let afterOpen = text.dropFirst(3)
      if let close = afterOpen.range(of: "\n---") {
        let frontmatter = afterOpen[..<close.lowerBound]
        body = String(afterOpen[close.upperBound...])
        for line in frontmatter.split(separator: "\n") {
          let parts = line.split(separator: ":", maxSplits: 1)
          guard parts.count == 2 else {
            continue
          }
          let key = parts[0].trimmingCharacters(in: .whitespaces).lowercased()
          let value = parts[1]
            .trimmingCharacters(in: .whitespaces)
            .trimmingCharacters(in: CharacterSet(charactersIn: "\"'"))
          switch key {
          case "name", "nome":
            name = value
          case "when", "quando", "description", "descricao", "descrição":
            when = value
          default:
            continue
          }
        }
      }
    }

    let instructions = String(body.prefix(maximumInstructionCharacters))
      .trimmingCharacters(in: .whitespacesAndNewlines)
    guard !instructions.isEmpty, !name.isEmpty else {
      return nil
    }
    return EvieSkill(
      id: fileName,
      name: name,
      // With no trigger written, the name is the trigger. Better than never
      // loading.
      when: when.isEmpty ? name : when,
      instructions: instructions,
      fileName: fileName
    )
  }

  /// The file this skill would be written as.
  public func markdown() -> String {
    """
    ---
    nome: \(name)
    quando: \(when)
    ---

    \(instructions)
    """
  }
}

/// Chooses which skills a question deserves.
///
/// Matching is by words rather than by asking the model, for the same reason
/// grounding is: a decision that costs a round trip before every answer would
/// double the wait, and this one is cheap enough to be free.
///
/// It is deliberately stricter than the web ranker. A passage that is only
/// loosely relevant costs a few tokens; a skill that loads when it should not
/// puts instructions in front of Evie for a job she is not doing, and she will
/// follow them.
public enum EvieSkillLibrary {
  /// How many can load at once. Two related skills is plausible; five means the
  /// matching is wrong.
  public static let maximumLoaded = 2
  /// How much of the prompt they may occupy between them.
  public static let characterBudget = 6_000
  /// A question must share at least this much with a skill's triggers.
  ///
  /// One word in common is a coincidence — "arquivo" appears in half of
  /// everything. Requiring two, or one that is rare, is what stops a skill about
  /// contracts from loading when the question is about a contract-shaped folder.
  static let minimumScore = 1.5

  /// The skills worth loading for this question, best first.
  public static func matching(
    _ question: String,
    in skills: [EvieSkill],
    limit: Int = maximumLoaded
  ) -> [EvieSkill] {
    let enabled = skills.filter(\.isEnabled)
    guard !enabled.isEmpty else {
      return []
    }
    let asked = Set(EviePassageRanker.terms(in: question))
    guard !asked.isEmpty else {
      return []
    }

    // How many skills each word appears in, so a word every skill mentions
    // decides nothing.
    var frequency: [String: Int] = [:]
    let triggers = enabled.map { Set(EviePassageRanker.terms(in: "\($0.name) \($0.when)")) }
    for terms in triggers {
      for term in terms {
        frequency[term, default: 0] += 1
      }
    }

    let total = Double(enabled.count)
    let scored = enabled.enumerated().map { index, skill -> (EvieSkill, Double) in
      let shared = triggers[index].intersection(asked)
      let score = shared.reduce(0.0) { running, term in
        let appearsIn = Double(frequency[term] ?? 1)
        // A word unique to one skill is worth much more than one they all use.
        return running + log(1 + total / appearsIn) + 0.5
      }
      return (skill, score)
    }

    var budget = characterBudget
    return
      scored
      .filter { $0.1 >= minimumScore }
      .sorted { $0.1 > $1.1 }
      .prefix(limit)
      .compactMap { skill, _ in
        guard skill.instructions.count <= budget else {
          return nil
        }
        budget -= skill.instructions.count
        return skill
      }
  }

  /// The block appended to her instructions for this turn.
  public static func guidance(for skills: [EvieSkill]) -> String? {
    guard !skills.isEmpty else {
      return nil
    }
    let blocks = skills.map { skill in
      """
      ## \(skill.name)

      \(skill.instructions)
      """
    }
    return """
      O Matheus te ensinou a fazer isto, e a pergunta dele parece ser um caso \
      disso. Siga estas instruções; se elas não servirem para o que ele está \
      pedindo de verdade, ignore-as e responda normalmente.

      \(blocks.joined(separator: "\n\n"))
      """
  }
}

/// The one thing Evie may do about skills on her own: suggest one.
///
/// Same shape as memory and as changing a file. She writes the instructions, the
/// user reads them and decides. A skill she installed by herself would be
/// instructions nobody had read taking effect on every future question.
public enum EvieSkillTool {
  public static let name = "propose_skill"

  public static var definition: EvieToolDefinition {
    EvieToolDefinition(
      name: name,
      summary: """
        Sugere guardar um jeito de fazer algo, para você seguir da próxima vez \
        que o Matheus pedir a mesma coisa. NÃO instala nada: ele lê e decide. \
        Use quando ele corrigir seu jeito de fazer, ou ensinar um procedimento \
        que vai se repetir. Nunca use para um assunto pontual.
        """,
      parameters: [
        EvieToolParameter(
          name: "nome",
          type: .string,
          summary: "Nome curto, como \"revisar contrato\".",
          isRequired: true
        ),
        EvieToolParameter(
          name: "quando",
          type: .string,
          summary: """
            As palavras que aparecem quando ele pede isso, separadas por vírgula.
            """,
          isRequired: true
        ),
        EvieToolParameter(
          name: "instrucoes",
          type: .string,
          summary: "O passo a passo, escrito para você seguir depois.",
          isRequired: true
        ),
      ]
    )
  }

  public static func skill(from call: EvieToolCall) -> EvieSkill? {
    let arguments = (try? call.arguments()) ?? [:]
    let name = (arguments["nome"] ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
    let when = (arguments["quando"] ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
    let instructions = (arguments["instrucoes"] ?? "")
      .trimmingCharacters(in: .whitespacesAndNewlines)
    guard !name.isEmpty, !instructions.isEmpty else {
      return nil
    }
    return EvieSkill(
      id: EvieSkill.fileName(for: name),
      name: name,
      when: when.isEmpty ? name : when,
      instructions: String(instructions.prefix(EvieSkill.maximumInstructionCharacters)),
      fileName: EvieSkill.fileName(for: name)
    )
  }
}

extension EvieSkill {
  /// A file name safe to write, derived from the skill's own name.
  public static func fileName(for name: String) -> String {
    let folded = name.folding(
      options: [.diacriticInsensitive, .caseInsensitive],
      locale: Locale(identifier: "pt_BR")
    )
    let slug =
      folded
      .map { $0.isLetter || $0.isNumber ? String($0) : "-" }
      .joined()
      .split(separator: "-")
      .joined(separator: "-")
    return (slug.isEmpty ? "skill" : String(slug.prefix(48))) + ".md"
  }
}
