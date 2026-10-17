import AppKit
import EvieCore

/// The on-screen indicator for everything Evie does with the screen: looking
/// at it once, watching it between agent steps, clicking and typing.
///
/// `ScreenPresenceMachine` decides what is allowed and when — no capture
/// before the glow is composited, no click without a full dwell, stop before
/// any animation. This class carries out its effects with real windows,
/// layers and timers, and reports back what happened. It holds no rule of
/// its own that a test could miss.
///
/// Coordinates come in as display-local points with a top-left origin
/// (`ScreenPoint`, `ScreenRect`); `ScreenGeometry` is what turns a global
/// Core Graphics point or a model's answer into one.
@MainActor
final class ScreenPresence {
  enum Phase: Equatable {
    /// One capture of these displays.
    case seeing(displays: [CGDirectDisplayID])
    /// Agent mode between steps, looking at these displays.
    case observing(displays: [CGDirectDisplayID], step: Int)
    /// Agent mode, about to act on this display.
    case acting(CGDirectDisplayID)
    /// Agent mode, typing into an app.
    case typing(app: String)
    /// The user took over. The reason is shown on the pill when given.
    case paused(reason: String)
  }

  enum Outcome {
    case success, stopped, failed
  }

  typealias Clearance = ScreenPresenceMachine.Clearance

  struct ScreenPoint: Equatable {
    let displayID: CGDirectDisplayID
    let x: CGFloat
    let y: CGFloat
    var point: CGPoint { CGPoint(x: x, y: y) }
  }

  struct ScreenRect: Equatable {
    let displayID: CGDirectDisplayID
    let rect: CGRect
  }

  /// The `eventSourceUserData` every event Evie posts carries, so her own
  /// input is never mistaken for the user taking over, and her own clicks
  /// can never press the pill's buttons. The synthetic-input executor (S5c)
  /// stamps this same value.
  static let syntheticEventTag: Int64 = EvieSyntheticInput.tag

  /// Called the moment the user stops Evie — Parar, Esc, or a pause running
  /// out — and always before any of the indicator's exit animation runs.
  var onStop: (() -> Void)?
  /// Called when the user presses Continuar on the paused pill.
  var onResume: (() -> Void)?
  /// Called when the pause is drawn: the user took over, and the session
  /// must wait for Continuar or Parar.
  var onPause: (() -> Void)?
  /// Shown beside the status ("no PC", "no Mac"), when known.
  var brainLocation: String?
  /// The agent's action budget, for "passo 3/25".
  var stepBudget: Int?

  private var machine = ScreenPresenceMachine()
  private var panels: [CGDirectDisplayID: PresencePanel] = [:]
  private let pill = PresencePillController()
  private let escape = PresenceEscapeKey()
  private let clock = ContinuousClock()

  /// The shell phase last drawn, which carries what the machine's phase does
  /// not: the displays, the app.
  private var drawn: Phase?
  private var observedDisplays: [CGDirectDisplayID] = []
  private var actingDisplay: CGDirectDisplayID?
  private var exitOutcome: Outcome = .success
  private var pendingClick: CheckedContinuation<Clearance, Never>?
  private var cursorTravel: Task<Void, Never>?
  private var holdTimer: Task<Void, Never>?
  private var dwellTimer: Task<Void, Never>?
  private var pauseTimer: Task<Void, Never>?
  private var cursorRetirement: Task<Void, Never>?
  private var noticeTimer: Task<Void, Never>?
  private var exit: Task<Void, Never>?
  private var screenObserver: NSObjectProtocol?

  /// Whether Esc is taken as a global stop key during agent sessions. Only
  /// the demo turns it off: on a Mac someone is using, a demo that swallowed
  /// their Esc would be the indicator getting in the way.
  private let usesEscapeKey: Bool

  init(usesEscapeKey: Bool = true) {
    self.usesEscapeKey = usesEscapeKey
    pill.model.onStop = { [weak self] in self?.stop() }
    pill.model.onContinue = { [weak self] in self?.resume() }
    escape.onPress = { [weak self] in self?.stop() }
    screenObserver = NotificationCenter.default.addObserver(
      forName: NSApplication.didChangeScreenParametersNotification, object: nil, queue: .main
    ) { [weak self] _ in
      MainActor.assumeIsolated { self?.rebuildForNewScreens() }
    }
  }

  isolated deinit {
    if let screenObserver {
      NotificationCenter.default.removeObserver(screenObserver)
    }
  }

  /// Whether `display` may be captured right now: only once a seeing or
  /// observing glow is composited on it. Capture code asks about the display
  /// it is about to capture, never about the indicator in general — a glow on
  /// one display says nothing to the user about another.
  /// Whether an agent session is paused for the user (Continuar or Parar).
  var isPaused: Bool {
    machine.isPaused
  }

  func mayCapture(display: CGDirectDisplayID) -> Bool {
    // Composited is all or nothing across the phase's displays, so a capturing
    // phase that is visible is on every one of `observedDisplays`.
    machine.mayCapture && observedDisplays.contains(display)
  }

  // MARK: - The calls the capture and agent loops make

  /// Shows `phase` and returns once it is composited — two display refreshes
  /// after its layers were added on every display it covers. Check
  /// `mayCapture(display:)` afterwards: when the glow could not be shown on
  /// one of them (no such display, or it did not refresh in time), capture
  /// stays refused on all of them.
  func show(_ phase: Phase) async {
    if case .paused(let reason) = phase {
      takeover(reason: reason)
      return
    }
    switch phase {
    case .seeing(let displays):
      observedDisplays = displays
    case .observing(let displays, _):
      observedDisplays = displays
    case .acting(let display):
      actingDisplay = display
    case .typing, .paused:
      break
    }
    drawn = phase
    await perform(machine.handle(.show(Self.machinePhase(phase)), at: clock.now))
  }

  /// Points the gaze at `target`: the violet reticle while observing, the
  /// amber element highlight while acting or typing. Interruptible — a new
  /// target mid-flight redirects from wherever it is.
  func lookAt(_ target: ScreenRect) {
    guard let panel = panels[target.displayID] else {
      return
    }
    cursorRetirement?.cancel()
    switch machine.state {
    case .visible(.observing, _), .appearing(.observing):
      for (id, other) in panels where id != target.displayID && other.reticle.target != nil {
        other.reticle.fadeOut(duration: 0.12)
      }
      if panel.reticle.target == nil, panels.values.contains(where: { $0 !== panel && $0.reticle.target != nil }) {
        panel.reticle.appear(at: target.rect)
      } else {
        panel.reticle.look(at: target.rect)
      }
    case .visible(.acting, _), .appearing(.acting), .dwelling, .visible(.typing, _), .appearing(.typing):
      panel.reticle.fadeOut(duration: 0.12)
      panel.highlight.highlight(target.rect)
      if let screen = Self.screen(for: target.displayID) {
        pill.show(pill.model.content, on: screen, avoiding: target.rect)
      }
    case .idle, .visible, .appearing, .paused:
      // Nothing is drawn outside a session: a reticle with no glow around it
      // would be the indicator showing less than is happening.
      break
    }
  }

  /// Moves the ghost cursor to `point`, shows the target for the dwell, and
  /// answers whether the click may be posted. `.cancelled` when the user
  /// pressed Esc or Parar, took over, or anything else replaced the step
  /// before the dwell had run its full length.
  func willClick(_ point: ScreenPoint, label: String?) async -> Clearance {
    resolvePendingClick(.cancelled)
    cursorRetirement?.cancel()
    if let screen = Self.screen(for: point.displayID) {
      pill.show(
        content(.acting, title: ScreenPresenceCopy.acting(label: label)), on: screen,
        avoiding: panels[point.displayID]?.highlight.target)
    }
    if let panel = panels[point.displayID] {
      let pointer = Self.pointer(on: panel)
      let start = ScreenPresenceLayout.cursorStart(
        target: point.point, pointer: pointer, displaySize: panel.root.bounds.size)
      let settle = panel.cursor.travel(to: point.point, from: start)
      let travel = Task { _ = try? await Task.sleep(for: .seconds(settle)) }
      cursorTravel = travel
      await travel.value
      cursorTravel = nil
    }
    return await withCheckedContinuation { continuation in
      pendingClick = continuation
      Task { await perform(machine.handle(.beginDwell, at: clock.now)) }
    }
  }

  /// The press, drawn on the same frame the real click is posted.
  func didClick(at point: ScreenPoint) {
    guard let panel = panels[point.displayID] else {
      return
    }
    panel.cursor.press(rippleIn: panel.root)
    if PresenceMotion.reducesMotion {
      panel.highlight.flash()
    }
    // A next step within 1.5 s keeps the cursor and re-targets it; otherwise
    // the cursor and the highlight step aside.
    cursorRetirement?.cancel()
    cursorRetirement = Task { [weak self] in
      try? await Task.sleep(for: .seconds(1.5))
      guard !Task.isCancelled, let self, let panel = self.panels[point.displayID] else { return }
      panel.cursor.fadeOut(duration: 0.2)
      panel.highlight.fadeOut(duration: 0.12)
    }
  }

  /// Evie is typing into `app`, in the field at `field` when Accessibility
  /// knows where it is. Nothing moves per keystroke.
  func typing(field: ScreenRect?, app: String) {
    if let field {
      actingDisplay = field.displayID
    }
    drawn = .typing(app: app)
    Task {
      await perform(machine.handle(.show(.typing), at: clock.now))
      guard let field, let panel = panels[field.displayID] else { return }
      panel.reticle.fadeOut(duration: 0.12)
      panel.cursor.fadeOut(duration: 0.2)
      panel.highlight.highlight(field.rect)
      panel.highlight.showTypingChip(in: panel.root.bounds)
    }
  }

  /// "Copiado para a área de transferência" for 1.2 s, then back to the
  /// current state.
  func clipboardNotice() {
    guard let screen = pillScreen else {
      return
    }
    let previous = pill.model.content
    pill.show(content(previous.mark, title: ScreenPresenceCopy.copied), on: screen)
    noticeTimer?.cancel()
    noticeTimer = Task { [weak self] in
      try? await Task.sleep(for: .seconds(1.2))
      guard !Task.isCancelled, let self, let screen = self.pillScreen else { return }
      self.pill.show(previous, on: screen)
    }
  }

  /// The capture or session is over. A seeing glow is held for its minimum
  /// first; everything else leaves now.
  func hide(outcome: Outcome) {
    exitOutcome = outcome
    Task { await perform(machine.handle(.hide, at: clock.now)) }
  }

  /// Parar, Esc, the emergency shortcut, or the voice command: cancels the
  /// work first, then takes the indicator down.
  func stop() {
    Task { await perform(machine.handle(.stop, at: clock.now)) }
  }

  /// The session was stopped somewhere else — the emergency shortcut, "para",
  /// the grant running out — and its work is already cancelled: the
  /// indicator comes down as a stop (a pause included, with its Continuar),
  /// without reporting the stop back through `onStop`.
  func endStoppedSession() {
    Task { await perform(machine.handle(.stop, at: clock.now), reportsStop: false) }
  }

  private func takeover(reason: String) {
    pausedReason = reason
    Task { await perform(machine.handle(.takeover, at: clock.now)) }
  }

  private var pausedReason = ""

  /// Runs `post` with the global Esc stop key released, and takes it back
  /// afterwards.
  ///
  /// The contract for the synthetic-input executor (S5c): every key, click
  /// or scroll Evie posts during a session is posted inside this call, and
  /// the settle after it (at least 300 ms) is waited out inside it too.
  /// The Carbon hot key cannot see `syntheticEventTag`, and a posted event
  /// is routed after `CGEvent.post` returns, so an Esc posted outside it — or
  /// re-registered before the event was delivered — stops Evie's own
  /// session. While the key is released the user still has Parar and the
  /// emergency shortcut; a real Esc in that window is untagged input, which
  /// the takeover monitor (S5d) is to treat as the user taking over.
  func postingSyntheticInput<Result>(
    _ post: () async throws -> Result
  ) async rethrows -> Result {
    escape.suspend()
    defer { escape.endSuspension() }
    return try await post()
  }

  /// Continuar: the user hands control back. The session observes again
  /// before doing anything, because the screen changed while it was theirs.
  func resume() {
    Task { await perform(machine.handle(.resume, at: clock.now)) }
    onResume?()
  }

  // MARK: - Carrying out the machine's effects

  private func perform(_ effects: [ScreenPresenceMachine.Effect], reportsStop: Bool = true) async {
    for effect in effects {
      switch effect {
      case .render(let phase, let id):
        await render(phase, id: id)
      case .holdIndicator(let until):
        holdTimer?.cancel()
        holdTimer = schedule(at: until) { $0.machine.handle(.holdExpired(until: until), at: $0.clock.now) }
      case .hideIndicator:
        tearDown()
      case .awaitDwell(let until):
        dwellTimer?.cancel()
        dwellTimer = schedule(at: until) { $0.machine.handle(.dwellEnded, at: $0.clock.now) }
      case .resolveDwell(let clearance):
        resolvePendingClick(clearance)
      case .cancelWork:
        // Whatever asked for it — Parar, Esc, a pause running out, a hide
        // while paused — the work was cut short, and the exit says so.
        exitOutcome = .stopped
        cursorTravel?.cancel()
        if reportsStop {
          onStop?()
        }
      case .renderPaused(let autoStopAt):
        renderPaused()
        onPause?()
        pauseTimer?.cancel()
        pauseTimer = schedule(at: autoStopAt) { $0.machine.handle(.pauseExpired, at: $0.clock.now) }
      }
    }
  }

  /// Runs `event` at `deadline`, unless cancelled first.
  private func schedule(
    at deadline: ContinuousClock.Instant,
    _ event: @escaping @MainActor (ScreenPresence) -> [ScreenPresenceMachine.Effect]
  ) -> Task<Void, Never> {
    Task { [weak self] in
      try? await Task.sleep(until: deadline, clock: .continuous)
      guard !Task.isCancelled, let self else { return }
      await self.perform(event(self))
    }
  }

  private func resolvePendingClick(_ clearance: Clearance) {
    pendingClick?.resume(returning: clearance)
    pendingClick = nil
  }

  /// Draws a phase on every display taking part, then reports render `id`
  /// composited once every one of them has refreshed twice with it.
  private func render(_ phase: ScreenPresenceMachine.Phase, id: ScreenPresenceMachine.RenderID) async {
    exit?.cancel()
    exit = nil
    // A hold left over from an earlier look must not fire into this one. The
    // machine refuses such an expiry anyway; this keeps the timer from
    // outliving the glow it was for.
    holdTimer?.cancel()
    holdTimer = nil
    let styles = glowStyles(for: phase)
    var shown: [CGDirectDisplayID: PresencePanel] = [:]
    for (display, style) in styles {
      guard let panel = panel(for: display) else { continue }
      let entering = panel.glow.currentStyle == nil || !panel.isVisible
      // The shutter plays once per capture: when the glow arrives, or turns
      // from a quieter state to seeing — not when seeing is drawn again.
      let startsSeeing = style == .seeing && panel.glow.currentStyle != .seeing
      panel.orderFrontRegardless()
      panel.glow.apply(style, entering: entering)
      if startsSeeing {
        panel.glow.sweep(duration: 0.7)
      }
      if style != .observing {
        panel.reticle.fadeOut(duration: 0.12)
      }
      if style == .observing || style == .seeing {
        panel.cursor.fadeOut(duration: 0.2)
        panel.highlight.fadeOut(duration: 0.12)
      }
      shown[display] = panel
    }
    // Displays no longer taking part are let go.
    for (display, panel) in panels where styles[display] == nil {
      panel.close()
      panels[display] = nil
    }
    updateEscape(for: phase)
    if let screen = pillScreen {
      pill.show(pillContent(for: phase), on: screen, avoiding: panels[pillDisplay ?? 0]?.highlight.target)
    }

    var composited: Set<CGDirectDisplayID> = []
    for (display, panel) in shown where await panel.waitForComposite() {
      composited.insert(display)
    }
    // A display with no panel or no refresh leaves the whole render
    // unreported, so a capture waiting on it stays refused. Whether this
    // render is still the current one is the machine's to decide.
    guard ScreenPresenceMachine.isComposited(requested: styles.keys, composited: composited) else {
      return
    }
    await perform(machine.handle(.composited(id: id), at: clock.now))
  }

  private func renderPaused() {
    cursorTravel?.cancel()
    // After a rebuild there are no panels yet; the pause goes on every
    // display the session was using.
    let displays = panels.isEmpty ? Array(glowStyles(for: .acting).keys) : Array(panels.keys)
    for display in displays {
      let entering = panels[display] == nil
      guard let panel = panel(for: display) else { continue }
      panel.orderFrontRegardless()
      panel.glow.apply(.paused, entering: entering)
      panel.reticle.fadeOut(duration: 0.12)
      panel.cursor.fadeOut(duration: 0.2)
      panel.highlight.fadeOut(duration: 0.12)
    }
    escape.disarm()
    if let screen = pillScreen {
      var paused = content(.paused, title: pausedReason.isEmpty ? ScreenPresenceCopy.paused : pausedReason)
      paused.showsContinue = true
      paused.showsEscape = false
      pill.show(paused, on: screen)
    }
  }

  /// Takes everything down, the way `exitOutcome` says it ended, and closes
  /// the windows once the last fade is over.
  private func tearDown() {
    for timer in [holdTimer, dwellTimer, pauseTimer, cursorRetirement, noticeTimer, cursorTravel] {
      timer?.cancel()
    }
    escape.disarm()
    let outcome = exitOutcome
    exitOutcome = .success
    let wasSeeing = drawn.map { if case .seeing = $0 { true } else { false } } ?? false
    var longest = 0.0
    for panel in panels.values {
      panel.reticle.fadeOut(duration: 0.2)
      panel.cursor.fadeOut(duration: 0.2)
      panel.highlight.fadeOut(duration: 0.12)
      let fade: Double
      switch outcome {
      case .success where wasSeeing:
        fade = panel.glow.fade(duration: PresenceMotion.reducesMotion ? 0.25 : 0.35)
      case .success:
        fade = panel.glow.flareAndFade()
      case .stopped:
        fade = panel.glow.grayAndFade()
      case .failed:
        fade = panel.glow.fade(duration: 0.2)
      }
      longest = max(longest, fade)
    }

    // The pill says how it ended before it leaves; a one-shot look just ends.
    var pillHold = 0.0
    if let screen = pillScreen, !(outcome == .success && wasSeeing) {
      let (mark, title, hold): (PresencePillContent.Mark, String, Double) =
        switch outcome {
        case .success: (.done, ScreenPresenceCopy.succeeded, 0.8)
        case .stopped: (.stopped, ScreenPresenceCopy.stopped, 0.9)
        case .failed: (.failed, ScreenPresenceCopy.failed, 0.9)
        }
      var ending = content(mark, title: title)
      ending.showsStop = false
      pill.show(ending, on: screen)
      pillHold = hold
    }
    drawn = nil
    exit?.cancel()
    exit = Task { [weak self] in
      try? await Task.sleep(for: .seconds(pillHold))
      guard !Task.isCancelled, let self else { return }
      self.pill.hide()
      try? await Task.sleep(for: .seconds(max(0, longest - pillHold) + 0.05))
      guard !Task.isCancelled else { return }
      for panel in self.panels.values {
        panel.close()
      }
      self.panels.removeAll()
      self.exit = nil
    }
  }

  /// Displays were added, removed or rearranged: every panel is dropped, and
  /// the machine has a session still on screen drawn again — and composited
  /// again before anything may be captured — on the displays that remain.
  /// The reticle, highlight and cursor are not carried over — their
  /// coordinates belonged to the old arrangement — and come back with the
  /// next step.
  private func rebuildForNewScreens() {
    for panel in panels.values {
      panel.close()
    }
    panels.removeAll()
    pill.close()
    Task { await perform(machine.handle(.redraw, at: clock.now)) }
  }

  // MARK: - What each phase looks like

  private func glowStyles(for phase: ScreenPresenceMachine.Phase) -> [CGDirectDisplayID: GlowLayer.Style] {
    var styles: [CGDirectDisplayID: GlowLayer.Style] = [:]
    switch phase {
    case .seeing:
      for display in observedDisplays { styles[display] = .seeing }
    case .observing:
      for display in observedDisplays { styles[display] = .observing }
    case .acting, .typing:
      // The display being acted on turns amber; the others the agent can
      // see drop back to observing.
      for display in observedDisplays { styles[display] = .observing }
      if let display = actingDisplay ?? observedDisplays.first {
        styles[display] = .acting
      }
    }
    return styles
  }

  private func pillContent(for phase: ScreenPresenceMachine.Phase) -> PresencePillContent {
    switch phase {
    case .seeing:
      var seeing = content(.seeing, title: ScreenPresenceCopy.seeing)
      seeing.showsEscape = false
      return seeing
    case .observing(let step):
      return content(.observing, title: ScreenPresenceCopy.observing(step: step, of: stepBudget))
    case .acting:
      return content(.acting, title: ScreenPresenceCopy.acting(label: nil))
    case .typing:
      if case .typing(let app) = drawn {
        return content(.typing, title: ScreenPresenceCopy.typing(app: app))
      }
      return content(.typing, title: ScreenPresenceCopy.typing(app: ""))
    }
  }

  private func content(_ mark: PresencePillContent.Mark, title: String) -> PresencePillContent {
    PresencePillContent(
      mark: mark, title: title, detail: brainLocation, showsStop: true, showsContinue: false,
      showsEscape: escape.isArmed)
  }

  /// Esc is held only while an agent session is up; a one-shot look is over
  /// before anyone could reach for it, and Parar covers it.
  private func updateEscape(for phase: ScreenPresenceMachine.Phase) {
    if phase.isAgentSession && usesEscapeKey {
      escape.arm()
    } else {
      escape.disarm()
    }
  }

  /// The pill goes on the display being acted on, else the first one being
  /// looked at, else the main display.
  private var pillDisplay: CGDirectDisplayID? {
    actingDisplayIfActing ?? observedDisplays.first ?? CGMainDisplayID()
  }

  private var actingDisplayIfActing: CGDirectDisplayID? {
    switch machine.state {
    case .visible(.acting, _), .appearing(.acting), .dwelling, .visible(.typing, _), .appearing(.typing):
      actingDisplay
    default:
      nil
    }
  }

  private var pillScreen: NSScreen? {
    pillDisplay.flatMap(Self.screen(for:)) ?? NSScreen.main
  }

  private func panel(for display: CGDirectDisplayID) -> PresencePanel? {
    if let panel = panels[display] {
      return panel
    }
    guard let screen = Self.screen(for: display) else {
      return nil
    }
    let panel = PresencePanel(screen: screen, displayID: display)
    panels[display] = panel
    return panel
  }

  static func screen(for display: CGDirectDisplayID) -> NSScreen? {
    NSScreen.screens.first { screen in
      (screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber)?.uint32Value
        == display
    }
  }

  /// The real pointer in `panel`'s display-local top-left points, when it is
  /// on that display.
  private static func pointer(on panel: PresencePanel) -> CGPoint? {
    let location = NSEvent.mouseLocation
    guard panel.frame.contains(location) else {
      return nil
    }
    return CGPoint(x: location.x - panel.frame.minX, y: panel.frame.maxY - location.y)
  }

  private static func machinePhase(_ phase: Phase) -> ScreenPresenceMachine.Phase {
    switch phase {
    case .seeing: .seeing
    case .observing(_, let step): .observing(step: step)
    case .acting: .acting
    case .typing: .typing
    case .paused: .observing(step: 0)
    }
  }
}
