import Foundation
import Testing

@testable import EvieCore

@Suite("Clipboard session")
@MainActor
struct ClipboardSessionTests {
  /// A pasteboard in memory: every write bumps the change count, as
  /// `NSPasteboard` does.
  @MainActor
  final class MemoryPasteboard: EviePasteboard {
    var changeCount = 7
    var stored: [PasteboardItemSnapshot]
    private(set) var writes: [[PasteboardItemSnapshot]] = []

    init(_ items: [PasteboardItemSnapshot] = []) {
      stored = items
    }

    func items() -> [PasteboardItemSnapshot] {
      stored
    }

    func replace(with items: [PasteboardItemSnapshot]) -> Int {
      stored = items
      writes.append(items)
      changeCount += 1
      return changeCount
    }

    /// Someone else copies something.
    func copyElsewhere(_ text: String) {
      stored = [PasteboardItemSnapshot(text: text)]
      changeCount += 1
    }
  }

  static let rich = [
    PasteboardItemSnapshot(representations: [
      PasteboardRepresentation(type: "public.rtf", data: Data("{\\rtf1 oi}".utf8)),
      PasteboardRepresentation(type: "public.utf8-plain-text", data: Data("oi".utf8)),
    ]),
    PasteboardItemSnapshot(representations: [
      PasteboardRepresentation(type: "public.png", data: Data([0x89, 0x50, 0x4E, 0x47]))
    ]),
  ]

  @Test("the text goes on marked transient and concealed, and every saved item comes back")
  func restoresEverything() async throws {
    let pasteboard = MemoryPasteboard(Self.rich)
    var delays: [TimeInterval] = []
    let session = ClipboardSession(pasteboard: pasteboard, sleep: { delays.append($0) })
    var seenDuringPaste: [PasteboardItemSnapshot] = []

    try await session.withTransientText("ação ✓") {
      seenDuringPaste = pasteboard.items()
    }

    let written = try #require(seenDuringPaste.first)
    #expect(seenDuringPaste.count == 1)
    #expect(written.string == "ação ✓")
    #expect(written.types.contains(ClipboardSession.transientType))
    #expect(written.types.contains(ClipboardSession.concealedType))
    #expect(delays == [ClipboardSession.restoreDelay])
    #expect(pasteboard.stored == Self.rich)
  }

  @Test("a copy made by someone else during the wait is left alone")
  func someoneElseCopied() async throws {
    let pasteboard = MemoryPasteboard(Self.rich)
    let session = ClipboardSession(
      pasteboard: pasteboard, sleep: { _ in pasteboard.copyElsewhere("do Matheus") })

    try await session.withTransientText("colar isto") {}

    #expect(pasteboard.stored == [PasteboardItemSnapshot(text: "do Matheus")])
    #expect(pasteboard.writes.count == 1)
  }

  @Test("an empty clipboard is left empty")
  func emptyStaysEmpty() async throws {
    let pasteboard = MemoryPasteboard()
    let session = ClipboardSession(pasteboard: pasteboard, sleep: { _ in })

    try await session.withTransientText("x") {}

    #expect(pasteboard.stored.isEmpty)
    #expect(pasteboard.writes.count == 2)
  }

  @Test("the clipboard comes back when the paste fails, after the same wait")
  func restoresAfterFailure() async {
    struct Failed: Error {}
    let pasteboard = MemoryPasteboard(Self.rich)
    var delays: [TimeInterval] = []
    let session = ClipboardSession(pasteboard: pasteboard, sleep: { delays.append($0) })

    await #expect(throws: Failed.self) {
      try await session.withTransientText("x") { throw Failed() }
    }

    #expect(delays == [ClipboardSession.restoreDelay])
    #expect(pasteboard.stored == Self.rich)
  }

  @Test("a cancelled session still waits before restoring, so the paste cannot read the person's clipboard")
  func cancelledStillWaits() async throws {
    let pasteboard = MemoryPasteboard(Self.rich)
    var waited = false
    let session = ClipboardSession(
      pasteboard: pasteboard,
      sleep: { _ in
        try await Task.sleep(for: .milliseconds(30))
        waited = true
      })

    let task = Task { @MainActor in
      try await session.withTransientText("x") {
        withUnsafeCurrentTask { $0?.cancel() }
      }
    }
    _ = await task.result

    #expect(waited)
    #expect(pasteboard.stored == Self.rich)
  }

  @Test("text the model copies for the person stays, as plain text")
  func writeForThePerson() {
    let pasteboard = MemoryPasteboard(Self.rich)
    let session = ClipboardSession(pasteboard: pasteboard, sleep: { _ in })

    session.writeForPerson("um parágrafo")

    #expect(pasteboard.stored == [PasteboardItemSnapshot(text: "um parágrafo")])
    #expect(session.readText() == "um parágrafo")
  }

  @Test("reading takes the plain text of the first item")
  func readsPlainText() {
    let session = ClipboardSession(pasteboard: MemoryPasteboard(Self.rich), sleep: { _ in })

    #expect(session.readText() == "oi")
    #expect(
      ClipboardSession(pasteboard: MemoryPasteboard(), sleep: { _ in }).readText() == nil)
  }
}
