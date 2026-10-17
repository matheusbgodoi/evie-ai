import Foundation
import Testing

@testable import EvieCore

@Suite("Bounded inbox pagination")
struct EvieMailPaginationTests {
  private func output(scanned: Int, next: Int, capped: Int = 0, records: String = "") -> String {
    let fs = String(EvieMailCalendar.fieldSeparator)
    return records
      + [EvieMailCalendar.mailPageMarker, String(scanned), String(next), String(capped)]
      .joined(separator: fs) + String(EvieMailCalendar.recordSeparator)
  }

  @Test("an empty matching page still has a bounded continuation and partial scope")
  func emptyPage() throws {
    let page = try EvieMailCalendar.parseMailPage(output(scanned: 80, next: 160), offset: 80)
    #expect(page.messages.isEmpty)
    #expect(page.scannedCount == 80)
    #expect(page.nextOffset == 160)
    let description = EvieMailCalendar.describe(page, matching: "inexistente")
    #expect(description.contains("parcial"))
    #expect(description.contains("offset=160"))
    #expect(description.contains("Não conclua ausência"))
  }

  @Test("the upper index bound is explicit and cannot overflow")
  func upperBound() throws {
    let page = try EvieMailCalendar.parseMailPage(
      output(scanned: 1, next: -1, capped: 1), offset: 9999)
    #expect(page.reachedIndexLimit)
    #expect(page.nextOffset == nil)
    #expect(EvieMailCalendar.describe(page, unreadOnly: true).contains("10.000"))
    for invalid in ["-1", "10000", "1.5", String(Int.max), "abc"] {
      #expect(throws: (any Error).self) { try EvieMailCalendar.resolveMailOffset(invalid) }
    }
    #expect(try EvieMailCalendar.resolveMailOffset(nil) == 0)
  }

  @Test("untrusted malformed or impossible pagination is rejected")
  func invalidMetadata() {
    for value in [
      output(scanned: 81, next: 81), output(scanned: 0, next: 0),
      output(scanned: 5, next: 100), output(scanned: 1, next: -1, capped: 1), "",
    ] {
      #expect(throws: (any Error).self) { try EvieMailCalendar.parseMailPage(value, offset: 0) }
    }
  }

  @Test("body records remain messages and the metadata footer is excluded")
  func records() throws {
    let fs = String(EvieMailCalendar.fieldSeparator)
    let record =
      ["sender", "subject", "2026-10-17-12-0", "Inbox", "body"]
      .joined(separator: fs) + String(EvieMailCalendar.recordSeparator)
    let page = try EvieMailCalendar.parseMailPage(
      output(scanned: 2, next: 2, records: record), offset: 0)
    #expect(page.messages.count == 1)
    #expect(page.messages.first?.subject == "subject")
  }

  @Test("legacy readers retain first-page compatibility without inventing a continuation")
  func legacyReader() async throws {
    let reader = LegacyMailReader()
    let page = try await reader.searchMailPage(term: "term", count: 3, offset: 0)
    #expect(page.scannedCount == nil)
    #expect(page.nextOffset == nil)
    #expect(EvieMailCalendar.describe(page, matching: "term").contains("parcial"))
    await #expect(throws: (any Error).self) {
      try await reader.searchMailPage(term: "term", count: 3, offset: 80)
    }
  }

  @Test("both tools advertise continuation")
  func toolSchema() {
    for definition in EvieMailCalendarTool.definitions.prefix(2) {
      #expect(definition.parameters.contains { $0.name == "offset" })
    }
  }
}

private struct LegacyMailReader: EvieMailCalendarReading {
  func readMail(count: Int, unreadOnly: Bool) async throws -> [EvieMailMessage] { [] }
  func searchMail(term: String, count: Int) async throws -> [EvieMailMessage] { [] }
  func readCalendar(from: Date, to: Date, limit: Int) async throws -> [EvieCalendarEvent] { [] }
  func listCalendars() async throws -> [String] { [] }
  func listMailAccounts() async throws -> [String] { [] }
}
