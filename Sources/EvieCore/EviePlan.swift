import Foundation

/// One step of a plan, and how far it got.
public struct EviePlanStep: Identifiable, Equatable, Sendable {
  public enum State: Equatable, Sendable {
    case pending
    case running
    case done(String)
    case failed(String)
    /// Reached only because the run was stopped, so the difference between "not
    /// reached" and "went wrong" survives to the summary.
    case cancelled
  }

  public let id: UUID
  public var instruction: String
  public var state: State

  public init(id: UUID = UUID(), instruction: String, state: State = .pending) {
    self.id = id
    self.instruction = instruction
    self.state = state
  }

  public var result: String? {
    if case .done(let text) = state {
      return text
    }
    return nil
  }
}

/// A question broken into steps that run one after another.
///
/// One after another and never at once, and that is measured rather than
/// stylistic: this Mac serves one model, and three concurrent requests took
/// 23.3 s against 8.1 s for a single one. Running steps in parallel costs 2.9×
/// and buys nothing at all.
public struct EviePlan: Equatable, Sendable {
  public var question: String
  public var steps: [EviePlanStep]

  public init(question: String, steps: [EviePlanStep]) {
    self.question = question
    self.steps = steps
  }

  public var isFinished: Bool {
    steps.allSatisfy {
      if case .pending = $0.state { return false }
      if case .running = $0.state { return false }
      return true
    }
  }

  /// The plan as it looks on screen while it runs.
  ///
  /// Written here rather than in the view because it is the thing a person
  /// stares at for minutes, and how far along it is is worth a test. A step
  /// that failed says so on the line where it failed: the run keeps going, and
  /// finding out at the end that step two produced nothing is worse than seeing
  /// it happen.
  public var progressReport: String {
    steps.enumerated().map { index, step in
      let number = index + 1
      switch step.state {
      case .pending:
        return "○ \(number). \(step.instruction)"
      case .running:
        return "◐ \(number). \(step.instruction)"
      case .done:
        return "● \(number). \(step.instruction)"
      case .failed(let reason):
        return "✕ \(number). \(step.instruction) — \(reason)"
      case .cancelled:
        return "○ \(number). \(step.instruction) — parado"
      }
    }.joined(separator: "\n")
  }

  /// What the steps produced, for the pass that writes the answer.
  public var findings: [(instruction: String, result: String)] {
    steps.compactMap { step in
      step.result.map { (step.instruction, $0) }
    }
  }
}

/// Recognises the command that asks for a plan.
///
/// A command and not a guess. A plan costs a model call to write plus one per
/// step plus one to answer — minutes on this hardware — and something that
/// expensive must never start because a question merely looked complicated.
public enum EviePlanCommand {
  public static let name = "/plano"

  /// The question behind `/plano …`, or nil when this is not that command.
  ///
  /// Anchored at the start and requiring a boundary after the word, so
  /// "/planos de saúde" and "meu /plano é esse" are ordinary questions.
  public static func question(in input: String) -> String? {
    let trimmed = input.trimmingCharacters(in: .whitespacesAndNewlines)
    guard trimmed.lowercased().hasPrefix(name) else {
      return nil
    }
    let rest = String(trimmed.dropFirst(name.count))
    guard let first = rest.first else {
      // `/plano` alone is the command with nothing to plan.
      return ""
    }
    guard first.isWhitespace else {
      return nil
    }
    return rest.trimmingCharacters(in: .whitespacesAndNewlines)
  }
}

/// Turns what the model wrote into steps, or refuses.
///
/// A numbered list rather than JSON, and that is a decision about the model
/// rather than about taste: a 26B model running locally produces a clean list
/// far more reliably than it produces valid JSON, and a malformed plan is a
/// minute of work thrown away.
public enum EviePlanParser {
  /// Below this it is not a plan, it is a question — and answering it directly
  /// costs one call instead of four.
  public static let minimumSteps = 2
  /// Above this the model is padding. Each step is a full turn, so the ceiling
  /// is about the person's time rather than about correctness.
  ///
  /// Four rather than six, and the difference was measured. A five-step plan for
  /// "compare o HTTP/2 com o HTTP/3" took 425 s end to end, and the answer it
  /// produced rested almost entirely on the first three steps — the last two
  /// restated and concluded, which the synthesis pass does anyway. Two fewer
  /// steps is close to two fewer minutes for an answer of the same substance.
  public static let maximumSteps = 4
  /// Longer than this and the "step" is prose that escaped the list.
  static let maximumStepCharacters = 240

  public enum ParseError: LocalizedError, Equatable {
    case tooFewSteps(Int)

    public var errorDescription: String? {
      switch self {
      case .tooFewSteps(let found):
        found == 0
          ? "Não consegui transformar isso em etapas."
          : "Isso é uma pergunta só, não um plano — vou responder direto."
      }
    }
  }

  public static func steps(in text: String) throws -> [EviePlanStep] {
    var found: [String] = []
    for line in text.split(whereSeparator: \.isNewline) {
      guard let instruction = instruction(in: String(line)) else {
        continue
      }
      found.append(instruction)
      if found.count == maximumSteps {
        break
      }
    }
    guard found.count >= minimumSteps else {
      throw ParseError.tooFewSteps(found.count)
    }
    return found.map { EviePlanStep(instruction: $0) }
  }

  /// The instruction on one line, if that line is a list item at all.
  static func instruction(in line: String) -> String? {
    var text = line.trimmingCharacters(in: .whitespaces)
    // Emphasis is decoration the model adds to headings; it is never part of
    // what the step says.
    text = text.replacingOccurrences(of: "**", with: "")
      .replacingOccurrences(of: "__", with: "")
    guard let body = stripMarker(from: text) else {
      return nil
    }
    let instruction = body.trimmingCharacters(in: CharacterSet(charactersIn: " \t:—-"))
    // A number alone, or a heading like "Plano:", is not a step.
    guard instruction.count > 3, instruction.count <= maximumStepCharacters else {
      return nil
    }
    return instruction
  }

  /// Removes a leading `1.`, `2)`, `-`, `*` or `•`, or reports that there was
  /// none.
  ///
  /// Returning nil rather than the line unchanged is what keeps a preamble —
  /// "Aqui está o plano:" — from becoming step one.
  static func stripMarker(from text: String) -> String? {
    if let first = text.first, "-*•‣".contains(first) {
      return String(text.dropFirst())
    }
    let digits = text.prefix { $0.isNumber }
    // Two digits at most, so "2024. Foi um ano difícil" stays a sentence rather
    // than becoming step twenty-twenty-four.
    guard !digits.isEmpty, digits.count <= 2 else {
      return nil
    }
    // Whitespace between the number and its separator is allowed, because "1 -"
    // is as common a way to write a list as "1." and dropping it lost a whole
    // format — measured against the shapes a local model actually produces.
    let after = text.dropFirst(digits.count).drop { $0 == " " || $0 == "\t" }
    guard let separator = after.first, ".)-:".contains(separator) else {
      return nil
    }
    return String(after.dropFirst())
  }
}
