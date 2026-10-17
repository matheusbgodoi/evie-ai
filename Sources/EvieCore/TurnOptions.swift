import Foundation

/// How hard the model may think before it answers.
///
/// The raw values are the gateway's `reasoning_effort` names; it maps `high` to
/// `xhigh` itself, so Evie never sends `high`.
public enum ReasoningLevel: String, Codable, Sendable, CaseIterable {
  case off
  case low
  case medium
  case xhigh

  /// The output cap a thinking turn needs, or `nil` when it does not think.
  ///
  /// Thinking spends output tokens before the answer starts, so a turn that
  /// thinks needs a bigger cap or it ends with reasoning and no answer. The two
  /// figures are the PC stack's measured pairings (its ADR-003): `xhigh` with a
  /// 16384 cap and a 12288 budget gave a full answer, and without the budget
  /// gave empty content; low and medium are run at 8192 with about 6144.
  var thinkingOutputCap: Int? {
    switch self {
    case .off: nil
    case .low, .medium: 8_192
    case .xhigh: 16_384
    }
  }

  /// The share of a turn's output the reasoning may use: three quarters, which
  /// is what both measured pairings above work out to. The rest is kept for the
  /// answer, so a budget can never eat the whole cap.
  static func thinkingBudget(forOutputCap cap: Int) -> Int {
    cap * 3 / 4
  }
}

/// How a server is told whether to think, which differs by server.
public enum ThinkingParameterStyle: String, Codable, Sendable {
  /// `chat_template_kwargs: {enable_thinking, reasoning_effort,
  /// preserve_thinking: false}` plus `thinking_budget_tokens` — the PC gateway.
  case templateKwargs
  /// A top-level `"enable_thinking": Bool` — mlx-vlm 0.7.8, which has no
  /// `chat_template_kwargs`. Requests in this style also send
  /// `context_management: []`, which only that server reads (see
  /// `OpenAICompatibleClient.makeRequest`).
  case topLevel
  /// Nothing is sent. The loopback Gemma server accepts every thinking parameter
  /// and ignores all of them (`docs/MODEL_STRATEGY.md`).
  case none
}

/// What one request asks of the model beyond the conversation itself.
public struct TurnOptions: Sendable, Equatable {
  public var reasoning: ReasoningLevel
  /// The cap for this turn; `nil` means the configuration's own. It is clamped
  /// to the configuration's `maxCompletionTokens` when the request is built.
  public var maxTokens: Int?
  public var thinkingBudgetTokens: Int?
  /// The model's last known state, which picks the deadlines. `nil` until the
  /// readiness probe exists.
  public var readiness: ReadinessRung?

  public init(
    reasoning: ReasoningLevel = .off,
    maxTokens: Int? = nil,
    thinkingBudgetTokens: Int? = nil,
    readiness: ReadinessRung? = nil
  ) {
    self.reasoning = reasoning
    self.maxTokens = maxTokens
    self.thinkingBudgetTokens = thinkingBudgetTokens
    self.readiness = readiness
  }

  /// A spoken answer: short, because it is listened to.
  public static func voice(_ configuration: EvieConfiguration) -> TurnOptions {
    answering(configuration, cap: 1_024)
  }

  /// A written answer.
  public static func chat(_ configuration: EvieConfiguration) -> TurnOptions {
    answering(configuration, cap: configuration.maxCompletionTokens)
  }

  /// One step of a computer-use session. It thinks a little on the PC, where
  /// that is cheap and a wrong click is not, and keeps the step's cap at 1024
  /// either way: a step is one tool call, and a step that runs long is a step
  /// that has lost the plot.
  public static func computerStep(_ configuration: EvieConfiguration) -> TurnOptions {
    let cap = 1_024
    guard configuration.thinkingStyle == .templateKwargs else {
      return TurnOptions(reasoning: .off, maxTokens: cap)
    }
    return TurnOptions(
      reasoning: .low,
      maxTokens: cap,
      thinkingBudgetTokens: ReasoningLevel.thinkingBudget(forOutputCap: cap)
    )
  }

  /// The configuration's default reasoning, with the cap raised to what that
  /// reasoning needs. A server that cannot be told to think gets no reasoning,
  /// so asking for it does not quietly quadruple the cap either.
  private static func answering(_ configuration: EvieConfiguration, cap: Int) -> TurnOptions {
    let reasoning =
      configuration.thinkingStyle == .none ? .off : configuration.defaultReasoning
    guard let thinkingCap = reasoning.thinkingOutputCap else {
      return TurnOptions(reasoning: .off, maxTokens: cap)
    }
    return TurnOptions(
      reasoning: reasoning,
      maxTokens: thinkingCap,
      thinkingBudgetTokens: ReasoningLevel.thinkingBudget(forOutputCap: thinkingCap)
    )
  }
}
