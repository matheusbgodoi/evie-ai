import CoreGraphics
import Foundation
import Testing

@testable import EvieCore

@Suite("Computer use controls")
@MainActor
struct ComputerUseControlsTests {
  static let person = ComputerUserPress.click(eventUserData: 0)
  static let evie = ComputerUserPress.click(eventUserData: EvieSyntheticInput.tag)

  /// A confirmation as the broker makes them, for the desk.
  static func question() throws -> ComputerConfirmationRequest {
    let clock = TestClock()
    let broker = EvieAgentModeBroker(policy: ComputerUseFixture.policy, now: { clock.now })
    let grant = try #require(broker.begin(goal: "Envia esse e-mail", gesture: .button))
    let observation = ComputerUseFixture.observation()
    broker.register(observation, grant: grant)
    let clearance = broker.authorize(
      .click(.element(observationID: "obs-1", index: 0), button: .left, count: 1),
      grant: grant, observation: observation, live: ComputerUseFixture.live(for: observation))
    guard case .needsConfirmation(let confirmation) = clearance else {
      Issue.record("expected a question, got \(clearance)")
      throw Unexpected.noQuestion
    }
    return ComputerConfirmationRequest(confirmation: confirmation, picture: nil, mark: nil)
  }

  enum Unexpected: Error {
    case noQuestion
  }

  @MainActor
  final class Flag {
    var value = false
  }

  /// Lets the asking task reach its card.
  static func untilAsked(_ desk: ComputerConfirmationDesk) async {
    while desk.waiting == nil {
      await Task.yield()
    }
  }

  // MARK: - Who pressed

  @Test("only a click Evie did not post can approve")
  func approvals() {
    #expect(Self.person.mayApprove)
    #expect(!Self.evie.mayApprove)
    #expect(!ComputerUserPress.keyboard.mayApprove)
    #expect(!ComputerUserPress.accessibility.mayApprove)
  }

  @Test("declining takes a real click or assistive technology, never Evie's click or a key")
  func declines() {
    #expect(Self.person.mayDecline)
    #expect(ComputerUserPress.accessibility.mayDecline)
    #expect(!Self.evie.mayDecline)
    #expect(!ComputerUserPress.keyboard.mayDecline)
  }

  // MARK: - The confirmation card

  @Test("Fazer by a person's click answers yes and closes the card")
  func deskApproves() async throws {
    let desk = ComputerConfirmationDesk()
    let request = try Self.question()
    var shown: [String] = []
    var closed: [UUID] = []
    desk.onShow = { shown.append($0.text) }
    desk.onClose = { closed.append($0) }

    async let answer = desk.ask(request)
    await Self.untilAsked(desk)
    #expect(desk.answer(request.confirmation.id, .perform, by: Self.person))

    #expect(await answer)
    #expect(shown == [request.text])
    #expect(closed == [request.confirmation.id])
  }

  @Test("a tagged click and a key on the card are ignored; the card keeps waiting")
  func deskIgnoresEvieAndKeys() async throws {
    let desk = ComputerConfirmationDesk()
    let request = try Self.question()

    async let answer = desk.ask(request)
    await Self.untilAsked(desk)
    #expect(!desk.answer(request.confirmation.id, .perform, by: Self.evie))
    #expect(!desk.answer(request.confirmation.id, .perform, by: .keyboard))
    #expect(!desk.answer(request.confirmation.id, .skip, by: Self.evie))
    #expect(desk.waiting?.confirmation.id == request.confirmation.id)
    #expect(desk.answer(request.confirmation.id, .skip, by: Self.person))

    #expect(await answer == false)
  }

  @Test("an answer for a card that is no longer up does nothing")
  func deskStaleAnswer() async throws {
    let desk = ComputerConfirmationDesk()
    let request = try Self.question()

    #expect(!desk.answer(request.confirmation.id, .perform, by: Self.person))
  }

  @Test("a stop withdraws the question as a no")
  func deskWithdraw() async throws {
    let desk = ComputerConfirmationDesk()
    let request = try Self.question()

    async let answer = desk.ask(request)
    await Self.untilAsked(desk)
    desk.withdraw()

    #expect(await answer == false)
    #expect(desk.waiting == nil)
  }

  @Test("cancelling the session while the card is up answers no")
  func deskCancelled() async throws {
    let desk = ComputerConfirmationDesk()
    let request = try Self.question()

    let waiting = Task { await desk.ask(request) }
    await Self.untilAsked(desk)
    waiting.cancel()

    #expect(await waiting.value == false)
    #expect(desk.waiting == nil)
  }

  // MARK: - The pause

  @Test("waiting on a session that is not paused returns at once")
  func pauseOpen() async throws {
    let pause = ComputerUsePause()

    try await pause.waitWhilePaused()

    #expect(pause.count == 0)
  }

  @Test("a paused session waits for Continuar, and the pause is counted")
  func pauseHolds() async throws {
    let pause = ComputerUsePause()
    pause.pause()
    pause.pause()
    #expect(pause.count == 1)

    let resumed = Flag()
    let waiter = Task {
      try await pause.waitWhilePaused()
      resumed.value = true
    }
    await Task.yield()
    #expect(!resumed.value)
    pause.resume()
    try await waiter.value

    #expect(resumed.value)
    #expect(!pause.isPaused)
  }

  @Test("a stop during a pause ends the wait with a cancellation")
  func pauseCancelled() async {
    let pause = ComputerUsePause()
    pause.pause()

    let waiter = Task { try await pause.waitWhilePaused() }
    await Task.yield()
    waiter.cancel()

    await #expect(throws: CancellationError.self) { try await waiter.value }
  }

  // MARK: - Taking over

  @Test("the person's own input takes over; Evie's tagged input does not")
  func takeoverByTag() {
    let rule = ComputerTakeoverRule()
    let now = ContinuousClock.now

    #expect(rule.isTakeover(.button, eventUserData: 0, at: now))
    #expect(rule.isTakeover(.key, eventUserData: 0, at: now))
    #expect(rule.isTakeover(.scroll, eventUserData: 0, at: now))
    #expect(rule.isTakeover(.pointerMoved(dx: 3, dy: 0), eventUserData: 0, at: now))
    #expect(!rule.isTakeover(.button, eventUserData: EvieSyntheticInput.tag, at: now))
    #expect(!rule.isTakeover(.key, eventUserData: EvieSyntheticInput.tag, at: now))
    #expect(!rule.isTakeover(.pointerMoved(dx: 4, dy: 4), eventUserData: EvieSyntheticInput.tag, at: now))
  }

  @Test("a pointer event that did not move is the window server's, not the person's")
  func stillPointer() {
    let rule = ComputerTakeoverRule()

    #expect(!rule.isTakeover(.pointerMoved(dx: 0, dy: 0), eventUserData: 0, at: .now))
  }

  @Test("while the person is asked something, their hand on the mouse is the answer")
  func heldWhileAsking() {
    var rule = ComputerTakeoverRule()
    let now = ContinuousClock.now
    rule.hold()
    rule.hold()

    #expect(!rule.isTakeover(.button, eventUserData: 0, at: now))
    rule.release(at: now)
    #expect(!rule.isTakeover(.button, eventUserData: 0, at: now + .seconds(5)))
    rule.release(at: now)
    #expect(!rule.isTakeover(.button, eventUserData: 0, at: now + .milliseconds(500)))
    #expect(rule.isTakeover(.button, eventUserData: 0, at: now + ComputerTakeoverRule.quietPeriod))
  }

  @Test("right after Continuar the hand leaving the button does not pause again")
  func quietAfterContinuar() {
    var rule = ComputerTakeoverRule()
    let now = ContinuousClock.now
    rule.quiet(from: now)

    #expect(!rule.isTakeover(.pointerMoved(dx: 2, dy: 1), eventUserData: 0, at: now + .milliseconds(300)))
    #expect(rule.isTakeover(.pointerMoved(dx: 2, dy: 1), eventUserData: 0, at: now + .seconds(2)))
  }

  // MARK: - The action log

  @Test("the log lists each step in the person's words, numbered, with no screen pictures")
  func actionLog() {
    let log = ComputerActionLog()
    log.record(.done, "Apertei “Nova Nota”.")
    log.record(.declined, "Enviar o e-mail “Oi”?")
    log.record(.refused, "A Evie não abre esse app.")

    #expect(log.entries.map(\.kind) == [.done, .declined, .refused])
    #expect(
      log.text == """
        1. Apertei “Nova Nota”.
        2. Você pulou: Enviar o e-mail “Oi”?
        3. Não fiz: A Evie não abre esse app.
        """)
  }

  @Test("an empty log says nothing was done")
  func emptyLog() {
    #expect(ComputerActionLog().text == "Nenhuma ação no Mac.")
  }

  @Test("a long result is cut to one line in the log")
  func logLineCut() {
    let log = ComputerActionLog()
    log.record(.done, "Primeira linha\nsegunda linha " + String(repeating: "x", count: 400))

    let line = try? #require(log.entries.first?.text)
    #expect(line == "Primeira linha")
  }
}
