import Foundation

/// The rules of the on-screen presence indicator, kept apart from the windows
/// and layers that draw it.
///
/// The indicator is a promise to the user: Evie does not look at the screen or
/// touch the keyboard and mouse unless they can see that she is doing it. Every
/// part of that promise that can be broken by ordering — capturing before the
/// glow is composited, clicking before the dwell has been shown, carrying on
/// after the user grabbed the mouse, animating before the work is cancelled —
/// is decided here, as a pure reducer, so it is covered by deterministic tests
/// instead of by watching the screen.
///
/// The shell feeds it events with the time they happened and carries out the
/// effects it returns, in order. It holds no timers and never reads the clock:
/// when something has to wait, the effect says until when, and the shell
/// reports back when that moment has come.
public struct ScreenPresenceMachine: Sendable {
  /// What the indicator is telling the user Evie is doing.
  public enum Phase: Sendable, Equatable {
    /// One capture the user asked for ("olha a tela").
    case seeing
    /// Agent mode, looking at the screen between actions.
    case observing(step: Int)
    /// Agent mode, about to post a click or a chord.
    case acting
    /// Agent mode, typing into a field.
    case typing

    /// The phases in which taking a screenshot is what the indicator says.
    public var capturesScreen: Bool {
      switch self {
      case .seeing, .observing: true
      case .acting, .typing: false
      }
    }

    /// The phases in which Evie is driving the Mac on the user's behalf, so
    /// real input from the user means they took over.
    public var isAgentSession: Bool {
      self != .seeing
    }
  }

  /// Whether a click the dwell was shown for may be posted.
  public enum Clearance: Sendable, Equatable {
    case proceed
    case cancelled
  }

  /// Which render a composite report is for. Each render gets a new one, so
  /// the two ticks of a render that has since been replaced cannot vouch for
  /// the phase that replaced it.
  public struct RenderID: Sendable, Hashable {
    let value: Int

    init(_ value: Int) {
      self.value = value
    }
  }

  public enum State: Sendable, Equatable {
    case idle
    /// Asked to draw, not yet confirmed on screen.
    case appearing(Phase)
    /// Composited at `since`.
    case visible(Phase, since: ContinuousClock.Instant)
    /// Acting, showing the target before a press. `visibleSince` is when the
    /// acting indicator itself was composited.
    case dwelling(visibleSince: ContinuousClock.Instant, until: ContinuousClock.Instant)
    /// The user took over during `step`.
    case paused(since: ContinuousClock.Instant, step: Int)
  }

  public enum Event: Sendable, Equatable {
    /// Draw this phase.
    case show(Phase)
    /// The shell confirmed the render `id` is composited on every display it
    /// covers — two display-link ticks after it was added, so the render
    /// server has put it on screen and not merely accepted it.
    case composited(id: RenderID)
    /// The capture or the session is finished.
    case hide
    /// The deadline of a `holdIndicator(until:)` has come. Carries the
    /// deadline back, so a hold set for an earlier look cannot end whatever
    /// is on screen now.
    case holdExpired(until: ContinuousClock.Instant)
    /// The displays changed and the shell rebuilt its panels: whatever is on
    /// screen has to be drawn, and composited, again.
    case redraw
    /// A click target is on screen; start the dwell before pressing.
    case beginDwell
    /// The dwell the shell was told to wait for has elapsed.
    case dwellEnded
    /// Real input that Evie did not post: the user moved the mouse, clicked,
    /// typed or scrolled.
    case takeover
    /// The user pressed Continuar on the paused pill.
    case resume
    /// The auto-stop deadline of a pause has come.
    case pauseExpired
    /// Esc, Parar, the emergency shortcut, the voice command "para", a revoked
    /// or expired grant.
    case stop
  }

  public enum Effect: Sendable, Equatable {
    /// Draw this phase, then report `.composited(id:)` with this id once it is
    /// on screen on every display it covers — and never if one is missing.
    case render(Phase, id: RenderID)
    /// Keep the indicator up; report `.holdExpired(until:)` at `until`.
    case holdIndicator(until: ContinuousClock.Instant)
    case hideIndicator
    /// Wait, then report `.dwellEnded` at `until`.
    case awaitDwell(until: ContinuousClock.Instant)
    /// Answer the pending click.
    case resolveDwell(Clearance)
    /// Cancel the capture or agent task. Always comes before any visual effect
    /// of the same event, so nothing keeps running while the indicator fades.
    case cancelWork
    /// Draw the paused state; report `.pauseExpired` at `autoStopAt`.
    case renderPaused(autoStopAt: ContinuousClock.Instant)
  }

  /// How long the seeing glow stays up at least, counted from the composite.
  /// A capture takes a fraction of that; without the floor the glow would
  /// flash too briefly to be noticed, and an indicator that can be missed does
  /// not keep its promise. It is also the length of the one-time shutter sweep.
  public let minimumSeeing: Duration
  /// How long the click target is shown before the press, the window in which
  /// Esc or a grab of the mouse cancels it.
  public let dwell: Duration
  /// How long a paused session waits for Continuar before stopping itself.
  public let pauseAutoStop: Duration

  public private(set) var state: State = .idle {
    // A hold belongs to the visible state it was asked for in; any change of
    // state is the end of it.
    didSet { heldUntil = nil }
  }
  /// The agent step most recently observed, so a resumed session observes
  /// again at the step it was interrupted in.
  private var step = 0
  /// The render the machine is waiting to hear is composited.
  private var currentRender = RenderID(0)
  /// When a seeing glow whose capture is over may come down.
  private var heldUntil: ContinuousClock.Instant?

  public init(
    minimumSeeing: Duration = .milliseconds(700),
    dwell: Duration = .milliseconds(250),
    pauseAutoStop: Duration = .seconds(60)
  ) {
    self.minimumSeeing = minimumSeeing
    self.dwell = dwell
    self.pauseAutoStop = pauseAutoStop
  }

  /// Whether an agent session is paused for the user: only Continuar, Parar
  /// or the auto-stop leave it, and a `hide` now is a stop.
  public var isPaused: Bool {
    if case .paused = state { true } else { false }
  }

  /// Whether a screenshot may be taken now: only once a phase that says so is
  /// on screen. "Asked to show" is not enough — that is the gap in which a
  /// capture would happen before the user could know about it.
  public var mayCapture: Bool {
    if case .visible(let phase, _) = state {
      return phase.capturesScreen
    }
    return false
  }

  /// Whether a render is on screen everywhere it was asked to be. A display
  /// that got no panel, or did not refresh in time, would be captured with no
  /// glow on it, so one missing display is the whole render missing; and
  /// nothing asked for is nothing shown.
  public static func isComposited<Display: Hashable>(
    requested: some Collection<Display>, composited: Set<Display>
  ) -> Bool {
    !requested.isEmpty && requested.allSatisfy(composited.contains)
  }

  /// Applies one event that happened at `now` and returns what the shell must
  /// do, in order.
  public mutating func handle(_ event: Event, at now: ContinuousClock.Instant) -> [Effect] {
    switch event {
    case .show(let phase): show(phase)
    case .composited(let id): composited(id, at: now)
    case .hide: hide(at: now)
    case .holdExpired(let until): expireHold(until, at: now)
    case .redraw: redraw(at: now)
    case .beginDwell: beginDwell(at: now)
    case .dwellEnded: endDwell(at: now)
    case .takeover: takeOver(at: now)
    case .resume: resume()
    case .pauseExpired: expirePause(at: now)
    case .stop: stop()
    }
  }

  private mutating func show(_ phase: Phase) -> [Effect] {
    // Only Continuar leaves a pause. A loop that has not noticed the user took
    // over must not be able to carry on by drawing its next step.
    if case .paused = state {
      return []
    }
    if case .observing(let observedStep) = phase {
      step = observedStep
    }
    return draw(phase)
  }

  /// Draws `phase` from scratch: any click waiting on the dwell is cancelled,
  /// and nothing counts as on screen until this render's own composite.
  private mutating func draw(_ phase: Phase) -> [Effect] {
    let cancelledClick = cancelPendingClick()
    currentRender = RenderID(currentRender.value + 1)
    state = .appearing(phase)
    return cancelledClick + [.render(phase, id: currentRender)]
  }

  private mutating func composited(_ id: RenderID, at now: ContinuousClock.Instant) -> [Effect] {
    // A late report — after a stop, or for a render already replaced — must
    // not make anything visible that is not being drawn.
    guard case .appearing(let phase) = state, id == currentRender else {
      return []
    }
    state = .visible(phase, since: now)
    return []
  }

  private mutating func hide(at now: ContinuousClock.Instant) -> [Effect] {
    switch state {
    case .idle:
      return []
    case .visible(.seeing, let since) where now < since + minimumSeeing:
      heldUntil = since + minimumSeeing
      return [.holdIndicator(until: since + minimumSeeing)]
    case .paused:
      // Only Continuar, Parar or the auto-stop leave a pause. A loop ending
      // its session while the user holds the Mac is a stop: the work it left
      // behind is cancelled, not abandoned.
      return stop()
    case .appearing, .visible:
      // Seeing that was never composited hides at once: capture was never
      // allowed, so there is nothing the user has to be shown happened.
      state = .idle
      return [.hideIndicator]
    case .dwelling:
      let cancelledClick = cancelPendingClick()
      state = .idle
      return cancelledClick + [.hideIndicator]
    }
  }

  private mutating func expireHold(
    _ until: ContinuousClock.Instant, at now: ContinuousClock.Instant
  ) -> [Effect] {
    // Only the hold of the glow on screen now. The timer of a look that has
    // since been replaced — by a second look, or by an agent session — would
    // otherwise take the new one down mid-capture.
    guard let heldUntil, heldUntil == until else {
      return []
    }
    return hide(at: now)
  }

  private mutating func redraw(at now: ContinuousClock.Instant) -> [Effect] {
    switch state {
    case .idle:
      return []
    case .visible(.seeing, _) where heldUntil != nil:
      // The capture is over and its glow went with the old panels; drawing a
      // new one would show more than is happening.
      state = .idle
      return [.hideIndicator]
    case .appearing(let phase), .visible(let phase, _):
      return draw(phase)
    case .dwelling:
      // The target the dwell was showing went with the old panels, so the
      // click is not cleared.
      return draw(.acting)
    case .paused(let since, _):
      return [.renderPaused(autoStopAt: since + pauseAutoStop)]
    }
  }

  private mutating func beginDwell(at now: ContinuousClock.Instant) -> [Effect] {
    guard case .visible(.acting, let since) = state else {
      // No click without the acting indicator already on screen.
      return [.resolveDwell(.cancelled)]
    }
    let until = now + dwell
    state = .dwelling(visibleSince: since, until: until)
    return [.awaitDwell(until: until)]
  }

  private mutating func endDwell(at now: ContinuousClock.Instant) -> [Effect] {
    guard case .dwelling(let since, let until) = state else {
      // Stopped, paused or replaced while waiting: the click is not cleared.
      return [.resolveDwell(.cancelled)]
    }
    state = .visible(.acting, since: since)
    // Cleared only when the target was shown for the whole dwell. An early
    // report means the user had less time to object than they were promised.
    return [.resolveDwell(now >= until ? .proceed : .cancelled)]
  }

  private mutating func takeOver(at now: ContinuousClock.Instant) -> [Effect] {
    switch state {
    case .appearing(let phase) where phase.isAgentSession,
      .visible(let phase, _) where phase.isAgentSession:
      state = .paused(since: now, step: step)
      return [.renderPaused(autoStopAt: now + pauseAutoStop)]
    case .dwelling:
      let cancelledClick = cancelPendingClick()
      state = .paused(since: now, step: step)
      return cancelledClick + [.renderPaused(autoStopAt: now + pauseAutoStop)]
    case .idle, .appearing, .visible, .paused:
      // Moving the mouse while Evie looks once is just using the Mac.
      return []
    }
  }

  private mutating func resume() -> [Effect] {
    guard case .paused(_, let pausedStep) = state else {
      return []
    }
    // The user changed the screen while in control, so the session resumes by
    // looking again rather than by finishing an action planned on a stale
    // observation.
    return draw(.observing(step: pausedStep))
  }

  private mutating func expirePause(at now: ContinuousClock.Instant) -> [Effect] {
    // Checked against this pause's own start, so the timer of an earlier pause
    // that was resumed cannot end a later one early.
    guard case .paused(let since, _) = state, now >= since + pauseAutoStop else {
      return []
    }
    return stop()
  }

  private mutating func stop() -> [Effect] {
    // Immediate: no minimum glow time, and the work is cancelled before the
    // indicator is touched. Emitted even with nothing on screen, because the
    // one thing a stop must never do is leave work running.
    let cancelledClick = cancelPendingClick()
    let wasShowing = state != .idle
    state = .idle
    return cancelledClick + [.cancelWork] + (wasShowing ? [.hideIndicator] : [])
  }

  /// The effect that answers a click waiting on the dwell, if there is one.
  /// Does not change the state; the caller moves on from dwelling itself.
  private func cancelPendingClick() -> [Effect] {
    if case .dwelling = state {
      return [.resolveDwell(.cancelled)]
    }
    return []
  }
}
