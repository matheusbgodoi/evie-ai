import Foundation
import Testing

@testable import EvieCore

@Suite("Screen presence machine")
struct ScreenPresenceMachineTests {
  private typealias Machine = ScreenPresenceMachine

  private let start = ContinuousClock.now

  private func at(_ milliseconds: Int) -> ContinuousClock.Instant {
    start.advanced(by: .milliseconds(milliseconds))
  }

  /// A machine already showing `phase`, composited at `start`.
  private func machineShowing(_ phase: Machine.Phase) -> Machine {
    var machine = Machine()
    _ = machine.handle(.show(phase), at: start)
    _ = machine.handle(.composited, at: start)
    return machine
  }

  // MARK: - The indicator comes before the capture

  @Test("nothing may be captured while the presence layer is idle")
  func idleRefusesCapture() {
    #expect(!Machine().mayCapture)
  }

  @Test("asking to show seeing draws it but does not yet allow a capture")
  func showAloneRefusesCapture() {
    var machine = Machine()

    let effects = machine.handle(.show(.seeing), at: start)

    #expect(effects == [.render(.seeing)])
    #expect(machine.state == .appearing(.seeing))
    #expect(!machine.mayCapture)
  }

  @Test("capture is allowed only once the glow has been composited")
  func compositedAllowsCapture() {
    var machine = Machine()
    _ = machine.handle(.show(.seeing), at: start)

    let effects = machine.handle(.composited, at: at(33))

    #expect(effects.isEmpty)
    #expect(machine.state == .visible(.seeing, since: at(33)))
    #expect(machine.mayCapture)
  }

  @Test("observing allows a capture, acting and typing do not")
  func captureOnlyWhileLooking() {
    #expect(machineShowing(.observing(step: 1)).mayCapture)
    #expect(!machineShowing(.acting).mayCapture)
    #expect(!machineShowing(.typing).mayCapture)
  }

  @Test("changing phase hides capture again until the new phase is composited")
  func newPhaseNeedsCompositing() {
    var machine = machineShowing(.acting)

    let effects = machine.handle(.show(.observing(step: 2)), at: at(100))

    #expect(effects == [.render(.observing(step: 2))])
    #expect(!machine.mayCapture)
    _ = machine.handle(.composited, at: at(133))
    #expect(machine.mayCapture)
  }

  @Test("a composited report with nothing being drawn changes nothing")
  func strayCompositedIgnored() {
    var machine = Machine()

    #expect(machine.handle(.composited, at: start).isEmpty)
    #expect(machine.state == .idle)
    #expect(!machine.mayCapture)
  }

  // MARK: - Seeing lasts at least 700 ms

  @Test("hiding seeing early holds the glow until 700 ms after it appeared")
  func seeingHoldsMinimum() {
    var machine = machineShowing(.seeing)

    let effects = machine.handle(.hide, at: at(120))

    #expect(effects == [.holdIndicator(until: at(700))])
    #expect(machine.state == .visible(.seeing, since: start))
  }

  @Test("hiding seeing at 700 ms hides it")
  func seeingHidesAtMinimum() {
    var machine = machineShowing(.seeing)
    _ = machine.handle(.hide, at: at(120))

    let effects = machine.handle(.hide, at: at(700))

    #expect(effects == [.hideIndicator])
    #expect(machine.state == .idle)
    #expect(!machine.mayCapture)
  }

  @Test("the 700 ms are counted from the composite, not from the request to show")
  func minimumCountsFromComposite() {
    var machine = Machine()
    _ = machine.handle(.show(.seeing), at: start)
    _ = machine.handle(.composited, at: at(40))

    #expect(machine.handle(.hide, at: at(720)) == [.holdIndicator(until: at(740))])
  }

  @Test("seeing that was never composited hides at once, because nothing was captured")
  func uncompositedSeeingHidesAtOnce() {
    var machine = Machine()
    _ = machine.handle(.show(.seeing), at: start)

    #expect(machine.handle(.hide, at: at(10)) == [.hideIndicator])
    #expect(machine.state == .idle)
  }

  @Test("the agent phases have no minimum and hide when asked")
  func agentPhasesHideAtOnce() {
    var machine = machineShowing(.observing(step: 3))

    #expect(machine.handle(.hide, at: at(10)) == [.hideIndicator])
    #expect(machine.state == .idle)
  }

  @Test("hiding while idle does nothing")
  func hideWhileIdle() {
    var machine = Machine()

    #expect(machine.handle(.hide, at: start).isEmpty)
  }

  // MARK: - The dwell before a click

  @Test("a dwell that runs its full length clears the click")
  func fullDwellProceeds() {
    var machine = machineShowing(.acting)

    let begun = machine.handle(.beginDwell, at: at(100))
    #expect(begun == [.awaitDwell(until: at(350))])
    #expect(machine.state == .dwelling(visibleSince: start, until: at(350)))

    let ended = machine.handle(.dwellEnded, at: at(350))
    #expect(ended == [.resolveDwell(.proceed)])
    #expect(machine.state == .visible(.acting, since: start))
  }

  @Test("Esc during the dwell cancels the click and stops the session")
  func escapeDuringDwellCancels() {
    var machine = machineShowing(.acting)
    _ = machine.handle(.beginDwell, at: at(100))

    let effects = machine.handle(.stop, at: at(200))

    #expect(effects == [.resolveDwell(.cancelled), .cancelWork, .hideIndicator])
    #expect(machine.state == .idle)
    // The timer that was waiting on the dwell fires afterwards and finds
    // nothing to clear.
    #expect(machine.handle(.dwellEnded, at: at(350)) == [.resolveDwell(.cancelled)])
  }

  @Test("a dwell reported finished before its time is cancelled, not cleared")
  func earlyDwellEndCancels() {
    var machine = machineShowing(.acting)
    _ = machine.handle(.beginDwell, at: at(100))

    #expect(machine.handle(.dwellEnded, at: at(349)) == [.resolveDwell(.cancelled)])
    #expect(machine.state == .visible(.acting, since: start))
  }

  @Test("a click cannot begin unless the acting indicator is on screen")
  func dwellNeedsActingIndicator() {
    var idle = Machine()
    #expect(idle.handle(.beginDwell, at: start) == [.resolveDwell(.cancelled)])

    var appearing = Machine()
    _ = appearing.handle(.show(.acting), at: start)
    #expect(appearing.handle(.beginDwell, at: at(10)) == [.resolveDwell(.cancelled)])

    var observing = machineShowing(.observing(step: 1))
    #expect(observing.handle(.beginDwell, at: at(10)) == [.resolveDwell(.cancelled)])
  }

  @Test("a new phase shown mid-dwell cancels the pending click")
  func showDuringDwellCancels() {
    var machine = machineShowing(.acting)
    _ = machine.handle(.beginDwell, at: at(100))

    let effects = machine.handle(.show(.observing(step: 4)), at: at(200))

    #expect(effects == [.resolveDwell(.cancelled), .render(.observing(step: 4))])
  }

  @Test("hiding mid-dwell cancels the pending click")
  func hideDuringDwellCancels() {
    var machine = machineShowing(.acting)
    _ = machine.handle(.beginDwell, at: at(100))

    #expect(machine.handle(.hide, at: at(200)) == [.resolveDwell(.cancelled), .hideIndicator])
    #expect(machine.state == .idle)
  }

  // MARK: - Takeover pauses

  @Test("real input during the dwell cancels the click and pauses the session")
  func takeoverDuringDwellPauses() {
    var machine = machineShowing(.observing(step: 3))
    _ = machine.handle(.show(.acting), at: at(10))
    _ = machine.handle(.composited, at: at(40))
    _ = machine.handle(.beginDwell, at: at(100))

    let effects = machine.handle(.takeover, at: at(200))

    #expect(effects == [.resolveDwell(.cancelled), .renderPaused(autoStopAt: at(60_200))])
    #expect(machine.state == .paused(since: at(200), step: 3))
    #expect(!machine.mayCapture)
  }

  @Test("real input while observing or typing pauses the session")
  func takeoverPausesAgentPhases() {
    var observing = machineShowing(.observing(step: 2))
    #expect(observing.handle(.takeover, at: at(10)) == [.renderPaused(autoStopAt: at(60_010))])
    #expect(observing.state == .paused(since: at(10), step: 2))

    var typing = machineShowing(.typing)
    #expect(typing.handle(.takeover, at: at(10)) == [.renderPaused(autoStopAt: at(60_010))])

    var appearing = Machine()
    _ = appearing.handle(.show(.acting), at: start)
    #expect(appearing.handle(.takeover, at: at(10)) == [.renderPaused(autoStopAt: at(60_010))])
  }

  @Test("moving the mouse while Evie only looks once is not a takeover")
  func seeingIgnoresTakeover() {
    var machine = machineShowing(.seeing)

    #expect(machine.handle(.takeover, at: at(100)).isEmpty)
    #expect(machine.state == .visible(.seeing, since: start))
    #expect(machine.mayCapture)
  }

  @Test("a paused session cannot be resumed behind the user's back by showing a phase")
  func pausedRefusesShow() {
    var machine = machineShowing(.observing(step: 2))
    _ = machine.handle(.takeover, at: at(10))

    #expect(machine.handle(.show(.acting), at: at(20)).isEmpty)
    #expect(machine.handle(.beginDwell, at: at(30)) == [.resolveDwell(.cancelled)])
    #expect(machine.state == .paused(since: at(10), step: 2))
  }

  @Test("Continuar resumes by observing again at the step that was interrupted")
  func resumeObservesAgain() {
    var machine = machineShowing(.observing(step: 5))
    _ = machine.handle(.show(.acting), at: at(10))
    _ = machine.handle(.takeover, at: at(20))

    let effects = machine.handle(.resume, at: at(5_000))

    #expect(effects == [.render(.observing(step: 5))])
    #expect(machine.state == .appearing(.observing(step: 5)))
    #expect(!machine.mayCapture)
  }

  @Test("resume outside a pause does nothing")
  func resumeOutsidePause() {
    var machine = machineShowing(.acting)

    #expect(machine.handle(.resume, at: at(10)).isEmpty)
    #expect(machine.state == .visible(.acting, since: start))
  }

  @Test("a pause left alone for 60 s stops the session")
  func pauseAutoStops() {
    var machine = machineShowing(.observing(step: 1))
    _ = machine.handle(.takeover, at: at(1_000))

    #expect(machine.handle(.pauseExpired, at: at(60_999)).isEmpty)
    #expect(machine.handle(.pauseExpired, at: at(61_000)) == [.cancelWork, .hideIndicator])
    #expect(machine.state == .idle)
  }

  @Test("the timer from an earlier pause cannot stop a later one early")
  func staleAutoStopIgnored() {
    var machine = machineShowing(.observing(step: 1))
    _ = machine.handle(.takeover, at: at(1_000))
    _ = machine.handle(.resume, at: at(2_000))
    _ = machine.handle(.composited, at: at(2_030))
    _ = machine.handle(.takeover, at: at(30_000))

    #expect(machine.handle(.pauseExpired, at: at(61_000)).isEmpty)
    #expect(machine.state == .paused(since: at(30_000), step: 1))
  }

  // MARK: - Stop is immediate

  @Test("stop cancels the work before hiding, without waiting for the seeing minimum")
  func stopSkipsMinimum() {
    var machine = machineShowing(.seeing)

    let effects = machine.handle(.stop, at: at(50))

    #expect(effects == [.cancelWork, .hideIndicator])
    #expect(machine.state == .idle)
    #expect(!machine.mayCapture)
  }

  @Test("stop ends a pause at once")
  func stopEndsPause() {
    var machine = machineShowing(.observing(step: 1))
    _ = machine.handle(.takeover, at: at(10))

    #expect(machine.handle(.stop, at: at(20)) == [.cancelWork, .hideIndicator])
    #expect(machine.state == .idle)
  }

  @Test("stop while something is still appearing hides it and refuses the capture")
  func stopWhileAppearing() {
    var machine = Machine()
    _ = machine.handle(.show(.seeing), at: start)

    #expect(machine.handle(.stop, at: at(5)) == [.cancelWork, .hideIndicator])
    // The composite that was already on its way arrives after the stop.
    #expect(machine.handle(.composited, at: at(33)).isEmpty)
    #expect(!machine.mayCapture)
  }

  @Test("stop with nothing on screen still cancels the work")
  func stopWhileIdleCancels() {
    var machine = Machine()

    #expect(machine.handle(.stop, at: start) == [.cancelWork])
  }

  @Test("the presence durations default to the documented values")
  func defaults() {
    let machine = Machine()

    #expect(machine.minimumSeeing == .milliseconds(700))
    #expect(machine.dwell == .milliseconds(250))
    #expect(machine.pauseAutoStop == .seconds(60))
  }
}
