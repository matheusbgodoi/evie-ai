import Foundation

/// How much one computer-use session may do before it needs the person.
///
/// The limits bound what a model that has gone wrong — misreading the screen,
/// or steered by text on it — can get through between the person's looks at
/// the pill. Each is a reason to stop and hand back (`finish` with
/// `need_user`), never to retry harder.
public struct ComputerUseBudget: Sendable, Equatable {
  public static let maximumActions = 25
  /// The session's wall clock: the grant's lifetime, which is the longest a
  /// capability proposal may live (ADR 0009).
  public static let wallClock: TimeInterval = CapabilityContractLimits.maximumProposalLifetime
  /// Between two actions, so an app has a moment to respond and the person a
  /// moment to see the ghost cursor; the executor's 300 ms settle normally
  /// covers it.
  public static let minimumInterval: TimeInterval = 0.25
  /// Results that changed nothing or failed, in a row: a model repeating
  /// itself at a screen it cannot read.
  public static let maximumConsecutiveSetbacks = 3
  /// The longest `type` action: a paragraph, not a document.
  public static let maximumTypedCharacters = 2_000

  public enum Exhaustion: Sendable, Equatable {
    case actions
    case time
    case setbacks

    /// Said to the model, which then finishes with `need_user`, and shown.
    public var message: String {
      switch self {
      case .actions:
        "Cheguei ao limite de \(ComputerUseBudget.maximumActions) ações nesta sessão. "
          + "Preciso de você para continuar."
      case .time:
        "A sessão passou de 15 minutos. Preciso de você para continuar."
      case .setbacks:
        "Três ações seguidas falharam ou não mudaram nada. Preciso de você para continuar."
      }
    }
  }

  public enum Verdict: Sendable, Equatable {
    case proceed
    case wait(until: Date)
    case exhausted(Exhaustion)
  }

  public let startedAt: Date
  public private(set) var actionsTaken = 0
  public private(set) var lastActionAt: Date?
  public private(set) var consecutiveSetbacks = 0

  public init(startedAt: Date) {
    self.startedAt = startedAt
  }

  public var nextActionAllowedAt: Date? {
    lastActionAt?.addingTimeInterval(Self.minimumInterval)
  }

  /// Whether another action may be committed at `now`. Exhaustion is checked
  /// first: a session that is over is over, however long one waits.
  public func verdict(at now: Date) -> Verdict {
    if actionsTaken >= Self.maximumActions {
      return .exhausted(.actions)
    }
    if now >= startedAt.addingTimeInterval(Self.wallClock) {
      return .exhausted(.time)
    }
    if consecutiveSetbacks >= Self.maximumConsecutiveSetbacks {
      return .exhausted(.setbacks)
    }
    if let next = nextActionAllowedAt, now < next {
      return .wait(until: next)
    }
    return .proceed
  }

  /// Counts a committed action.
  public mutating func recordAction(at now: Date) {
    actionsTaken += 1
    lastActionAt = now
  }

  /// Counts what an action did: anything that changed the screen ends a run
  /// of setbacks.
  public mutating func record(_ outcome: ActionResult.Outcome) {
    switch outcome {
    // The loop settles `carriedOut` against the next observation before it
    // counts it; one that arrives here unsettled did not fail.
    case .changed, .carriedOut:
      consecutiveSetbacks = 0
    case .noChange, .failed:
      consecutiveSetbacks += 1
    }
  }
}
