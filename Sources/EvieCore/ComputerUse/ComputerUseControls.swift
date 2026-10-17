import CoreGraphics
import Foundation

/// The mark on every input event Evie posts herself.
public enum EvieSyntheticInput {
  /// `eventSourceUserData` on each event `SyntheticInput` posts, set on its
  /// source and on the event. Measured 2026-10-16 (M5 24 GB, macOS 27.2): a
  /// tagged mouse move posted at `.cghidEventTap` reached a global `NSEvent`
  /// monitor and a listen-only `CGEventTap` with the value intact.
  public static let tag: Int64 = 0xE71E

  public static func isEvies(userData: Int64) -> Bool {
    userData == tag
  }
}

/// How a button on one of Evie's cards was pressed.
public enum ComputerUserPress: Sendable, Equatable {
  /// A mouse click, with the event's `eventSourceUserData`.
  case click(eventUserData: Int64)
  /// Return, Space or a key equivalent.
  case keyboard
  /// `AXPress` from assistive technology, or from any other process with the
  /// Accessibility grant.
  case accessibility

  /// Whether this press can say yes to an action or a session: only a click
  /// Evie did not post. A key can come from her own typing into the wrong
  /// window, and an Accessibility press from any trusted process, so neither
  /// is a hand on the card for certain.
  public var mayApprove: Bool {
    guard case .click(let userData) = self else {
      return false
    }
    return !EvieSyntheticInput.isEvies(userData: userData)
  }

  /// Whether this press can say no. Assistive technology may (a no costs
  /// nothing); Evie's own click and a key may not, so nothing she posts
  /// answers her own question either way.
  public var mayDecline: Bool {
    switch self {
    case .click(let userData): !EvieSyntheticInput.isEvies(userData: userData)
    case .accessibility: true
    case .keyboard: false
    }
  }
}

/// One question for the person, as the confirmation card shows it.
public struct ComputerConfirmationRequest: Sendable, Equatable {
  public let confirmation: ComputerConfirmation
  /// The newest picture of the session, for the card's thumbnail. In memory
  /// only, like every picture of a session.
  public let picture: EvieImagePart?
  /// The action's target on that picture, as fractions of its width and
  /// height (0…1), for the reticle; `nil` for an action with no place.
  public let mark: CGRect?

  public init(confirmation: ComputerConfirmation, picture: EvieImagePart?, mark: CGRect?) {
    self.confirmation = confirmation
    self.picture = picture
    self.mark = mark
  }

  /// The policy's question, built from the screen's own data.
  public var text: String {
    confirmation.text
  }
}

/// The confirmation card's half in code: it holds the question the loop is
/// waiting on and decides which presses answer it.
///
/// The shell draws the card (`onShow`) and reports every press with how it
/// was made; `answer` ignores what `ComputerUserPress` does not allow — a click
/// Evie posted, any key — so the card keeps waiting for a hand. Keyboard
/// confirmation is therefore off for as long as act mode runs, which is the
/// only time this desk asks anything.
@MainActor
public final class ComputerConfirmationDesk {
  public enum Choice: Sendable, Equatable {
    case perform, skip
  }

  /// Puts the card on screen.
  public var onShow: ((ComputerConfirmationRequest) -> Void)?
  /// Takes the card with this confirmation id down.
  public var onClose: ((UUID) -> Void)?
  public private(set) var waiting: ComputerConfirmationRequest?
  private var reply: CheckedContinuation<Bool, Never>?

  public init() {}

  /// Shows the question and waits for the person's answer: `true` only for
  /// Fazer clicked by a hand. A stop or a cancelled session answers `false`.
  public func ask(_ request: ComputerConfirmationRequest) async -> Bool {
    withdraw()
    return await withTaskCancellationHandler {
      await withCheckedContinuation { (continuation: CheckedContinuation<Bool, Never>) -> Void in
        if Task.isCancelled {
          continuation.resume(returning: false)
          return
        }
        waiting = request
        reply = continuation
        onShow?(request)
      }
    } onCancel: {
      Task { @MainActor [weak self] in
        self?.settle(request.confirmation.id, with: false)
      }
    }
  }

  /// A press on the card. Returns whether it answered the question; a press
  /// that does not count changes nothing.
  @discardableResult
  public func answer(_ id: UUID, _ choice: Choice, by press: ComputerUserPress) -> Bool {
    guard waiting?.confirmation.id == id else {
      return false
    }
    switch choice {
    case .perform:
      guard press.mayApprove else {
        return false
      }
    case .skip:
      guard press.mayDecline else {
        return false
      }
    }
    settle(id, with: choice == .perform)
    return true
  }

  /// Answers no to whatever is waiting, as a stop does.
  public func withdraw() {
    guard let id = waiting?.confirmation.id else {
      return
    }
    settle(id, with: false)
  }

  private func settle(_ id: UUID, with answer: Bool) {
    guard waiting?.confirmation.id == id, let reply else {
      return
    }
    waiting = nil
    self.reply = nil
    onClose?(id)
    reply.resume(returning: answer)
  }
}

/// Whether a session is paused because the person took over, so the loop
/// waits instead of looking or acting.
///
/// The shell pauses it when the presence draws the pause (the pill's
/// Continuar and Parar) and resumes it on Continuar; a stop cancels the task,
/// which ends any wait. `count` lets the loop tell that a pause happened since
/// it last looked: the screen was his meanwhile, so it looks again before
/// acting.
@MainActor
public final class ComputerUsePause {
  public private(set) var isPaused = false
  /// How many pauses there have been.
  public private(set) var count = 0
  private var waiters: [UUID: CheckedContinuation<Void, any Error>] = [:]

  public init() {}

  public func pause() {
    guard !isPaused else {
      return
    }
    isPaused = true
    count += 1
  }

  public func resume() {
    isPaused = false
    let woken = waiters
    waiters.removeAll()
    for waiter in woken.values {
      waiter.resume()
    }
  }

  /// Returns at once when not paused; otherwise when Continuar is pressed.
  /// Throws `CancellationError` when the session is stopped meanwhile.
  public func waitWhilePaused() async throws {
    try Task.checkCancellation()
    guard isPaused else {
      return
    }
    let id = UUID()
    try await withTaskCancellationHandler {
      try await withCheckedThrowingContinuation {
        (continuation: CheckedContinuation<Void, any Error>) -> Void in
        if Task.isCancelled {
          continuation.resume(throwing: CancellationError())
          return
        }
        guard isPaused else {
          continuation.resume()
          return
        }
        waiters[id] = continuation
      }
    } onCancel: {
      Task { @MainActor [weak self] in
        self?.waiters.removeValue(forKey: id)?.resume(throwing: CancellationError())
      }
    }
  }
}

/// Which input means the person took the Mac back.
///
/// Anything Evie did not post: a key, a button, a scroll, a pointer that
/// moved. Not a pointer event without movement — the window server sends
/// those when a window appears under a still pointer — and not mouse-entered
/// or exited, for the same reason (measured 2026-10-16: an Evie window
/// ordered in under the pointer delivered `mouseEntered` with no user data).
/// Nothing counts while the person is being asked something (`hold`), since
/// the mouse is how they answer, nor for a moment after they answered or
/// pressed Continuar (`quietPeriod`), while the hand leaves the button.
public struct ComputerTakeoverRule: Sendable {
  public enum Input: Sendable, Equatable {
    case pointerMoved(dx: Double, dy: Double)
    case button
    case scroll
    case key
  }

  public static let quietPeriod: Duration = .seconds(1)

  private var holds = 0
  private var quietUntil: ContinuousClock.Instant?

  public init() {}

  /// The person is being asked something; their input is the answer.
  public mutating func hold() {
    holds += 1
  }

  /// One question is over; input counts again after `quietPeriod`.
  public mutating func release(at now: ContinuousClock.Instant) {
    holds = max(0, holds - 1)
    quiet(from: now)
  }

  /// Ignore input for `quietPeriod` from `now`: right after Continuar.
  public mutating func quiet(from now: ContinuousClock.Instant) {
    quietUntil = now + Self.quietPeriod
  }

  public func isTakeover(
    _ input: Input,
    eventUserData: Int64,
    at now: ContinuousClock.Instant
  ) -> Bool {
    guard !EvieSyntheticInput.isEvies(userData: eventUserData), holds == 0 else {
      return false
    }
    if let quietUntil, now < quietUntil {
      return false
    }
    if case .pointerMoved(let dx, let dy) = input, dx == 0, dy == 0 {
      return false
    }
    return true
  }
}

/// What the session did, in memory, for the card shown when it ends.
///
/// Each line is Evie's own account — the executor's result, the policy's
/// question or refusal, all built from what the system reports — never a
/// picture and never the clipboard's text. It is not saved anywhere.
@MainActor
public final class ComputerActionLog {
  public struct Entry: Sendable, Equatable {
    public enum Kind: Sendable, Equatable {
      /// Carried out.
      case done
      /// Carried out, and nothing changed.
      case noChange
      /// Tried, and it did not work.
      case failed
      /// He pressed Pular.
      case declined
      /// The policy or the broker said no.
      case refused
    }

    public let kind: Kind
    public let text: String

    public init(kind: Kind, text: String) {
      self.kind = kind
      self.text = text
    }
  }

  /// One line, cut so a long result does not fill the card.
  public static let maximumLineCharacters = 200

  public private(set) var entries: [Entry] = []

  public init() {}

  public func record(_ kind: Entry.Kind, _ text: String) {
    let firstLine = text.split(whereSeparator: \.isNewline).first.map(String.init) ?? ""
    let trimmed = firstLine.trimmingCharacters(in: .whitespaces)
    let cut =
      trimmed.count > Self.maximumLineCharacters
      ? String(trimmed.prefix(Self.maximumLineCharacters)) + "…" : trimmed
    entries.append(Entry(kind: kind, text: cut))
  }

  /// The numbered list the end-of-session card shows.
  public var text: String {
    guard !entries.isEmpty else {
      return "Nenhuma ação no Mac."
    }
    return entries.enumerated().map { offset, entry in
      let lead =
        switch entry.kind {
        case .done, .noChange: ""
        case .failed, .refused: "Não fiz: "
        case .declined: "Você pulou: "
        }
      return "\(offset + 1). \(lead)\(entry.text)"
    }
    .joined(separator: "\n")
  }
}
