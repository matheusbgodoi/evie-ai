import Foundation
import Testing

@testable import EvieCore

@Suite("Unsaved profile draft rebase")
struct EvieProfileDraftRebaseTests {
  private let baseline = EvieProfileDraft(EvieModelProfile.builtInPC)

  @Test("an unchanged draft follows every latest saved field")
  func untouchedFieldsFollowLatest() {
    var latest = baseline
    latest.displayName = "Saved label"
    latest.endpoint = "https://fresh.example.invalid/v1"
    latest.model = "fresh-model"
    latest.contextTokens = 100_000
    latest.maxCompletionTokens = 1_000
    latest.defaultReasoning = .low
    latest.usesServerTemperature.toggle()
    latest.temperature = 0.4
    latest.usesServerTopP.toggle()
    latest.topP = 0.6
    latest.requestTimeout = 200
    #expect(baseline.rebased(onto: latest, since: baseline) == latest)
  }

  @Test("unsaved edits win field by field while other fields follow the fresh file")
  func editsSurviveWithoutRestoringStaleValues() {
    var pending = baseline
    pending.displayName = "Typed label"
    pending.model = "unsaved-model"
    pending.contextTokens = 90_000
    pending.defaultReasoning = .medium
    pending.temperature = 0.3
    pending.usesServerTopP = false
    var latest = baseline
    latest.displayName = "Other writer label"
    latest.endpoint = "https://fresh.example.invalid/v1"
    latest.model = "other-model"
    latest.maxCompletionTokens = 1_000
    latest.usesServerTemperature = false
    latest.topP = 0.7
    latest.requestTimeout = 200
    var expected = pending
    expected.endpoint = latest.endpoint
    expected.maxCompletionTokens = latest.maxCompletionTokens
    expected.usesServerTemperature = latest.usesServerTemperature
    expected.topP = latest.topP
    expected.requestTimeout = latest.requestTimeout
    #expect(pending.rebased(onto: latest, since: baseline) == expected)
  }

  @Test("all edited fields, even unfinished input, remain unsaved and typed")
  func everyEditableFieldIsPreserved() {
    var pending = baseline
    pending.displayName = "Unfinished name"
    pending.endpoint = "https://"
    pending.model = ""
    pending.contextTokens = 17
    pending.maxCompletionTokens = 99
    pending.defaultReasoning = .xhigh
    pending.usesServerTemperature.toggle()
    pending.temperature = -5
    pending.usesServerTopP.toggle()
    pending.topP = -3
    pending.requestTimeout = -1
    #expect(pending.rebased(onto: baseline, since: baseline) == pending)
  }
}
