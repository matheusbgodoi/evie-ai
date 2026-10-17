import Foundation
import Testing

@testable import EvieCore

@Suite("Accessibility trust")
struct AccessibilityTrustTests {
  @Test("a grant made while waiting is noticed at the next poll")
  func noticesTheGrant() async {
    var polls = 0
    var naps = 0

    let trusted = await AccessibilityTrust.waitUntilTrusted(
      timeout: .seconds(10),
      isTrusted: {
        polls += 1
        return polls > 3
      },
      sleep: { _ in naps += 1 })

    #expect(trusted)
    #expect(naps == 3)
  }

  @Test("already trusted returns at once")
  func alreadyTrusted() async {
    var naps = 0

    let trusted = await AccessibilityTrust.waitUntilTrusted(
      timeout: .seconds(10), isTrusted: { true }, sleep: { _ in naps += 1 })

    #expect(trusted)
    #expect(naps == 0)
  }

  @Test("gives up after the timeout")
  func timesOut() async {
    var naps = 0

    let trusted = await AccessibilityTrust.waitUntilTrusted(
      timeout: .seconds(2), interval: .milliseconds(500), isTrusted: { false },
      sleep: { _ in naps += 1 })

    #expect(!trusted)
    #expect(naps == 4)
  }

  @Test("a cancelled wait answers not trusted")
  func cancelled() async {
    let trusted = await AccessibilityTrust.waitUntilTrusted(
      timeout: .seconds(10), isTrusted: { false }, sleep: { _ in throw CancellationError() })

    #expect(!trusted)
  }
}
