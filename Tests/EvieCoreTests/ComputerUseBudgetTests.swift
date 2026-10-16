import Foundation
import Testing

@testable import EvieCore

@Suite("Computer use budget")
struct ComputerUseBudgetTests {
  let start = ComputerUseFixture.start

  @Test("the limits are the spec's, and the wall clock is the grant's lifetime")
  func limits() {
    #expect(ComputerUseBudget.maximumActions == 25)
    #expect(ComputerUseBudget.wallClock == 15 * 60)
    #expect(ComputerUseBudget.wallClock == CapabilityContractLimits.maximumProposalLifetime)
    #expect(ComputerUseBudget.wallClock == EvieAgentModeBroker.grantLifetime)
    #expect(ComputerUseBudget.minimumInterval == 0.25)
    #expect(ComputerUseBudget.maximumConsecutiveSetbacks == 3)
    #expect(ComputerUseBudget.maximumTypedCharacters == 2_000)
  }

  @Test("twenty-five actions, then the person is needed")
  func actionLimit() {
    var budget = ComputerUseBudget(startedAt: start)
    var now = start
    for _ in 0..<25 {
      #expect(budget.verdict(at: now) == .proceed)
      budget.recordAction(at: now)
      now += 1
    }
    #expect(budget.verdict(at: now) == .exhausted(.actions))
    #expect(ComputerUseBudget.Exhaustion.actions.message.contains("25"))
  }

  @Test("fifteen minutes, then the person is needed")
  func wallClockLimit() {
    let budget = ComputerUseBudget(startedAt: start)
    #expect(budget.verdict(at: start + 15 * 60 - 1) == .proceed)
    #expect(budget.verdict(at: start + 15 * 60) == .exhausted(.time))
  }

  @Test("three no-change or failed results in a row, then the person is needed")
  func setbacks() {
    var budget = ComputerUseBudget(startedAt: start)
    budget.record(.noChange)
    budget.record(.failed)
    #expect(budget.verdict(at: start) == .proceed)
    budget.record(.changed)
    budget.record(.noChange)
    budget.record(.noChange)
    #expect(budget.verdict(at: start) == .proceed)
    budget.record(.noChange)
    #expect(budget.verdict(at: start) == .exhausted(.setbacks))
  }

  @Test("at least 250 ms between actions")
  func interval() {
    var budget = ComputerUseBudget(startedAt: start)
    budget.recordAction(at: start)
    #expect(budget.verdict(at: start + 0.1) == .wait(until: start + 0.25))
    #expect(budget.verdict(at: start + 0.25) == .proceed)
    #expect(budget.nextActionAllowedAt == start + 0.25)
  }
}
