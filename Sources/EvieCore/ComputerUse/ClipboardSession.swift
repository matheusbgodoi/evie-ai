import Foundation

/// One type's bytes on one pasteboard item.
public struct PasteboardRepresentation: Sendable, Equatable {
  public let type: String
  public let data: Data

  public init(type: String, data: Data) {
    self.type = type
    self.data = data
  }
}

/// One pasteboard item with every type it carried, in the order the app that
/// wrote it gave them — the order a reader takes as preference.
public struct PasteboardItemSnapshot: Sendable, Equatable {
  public let representations: [PasteboardRepresentation]

  public init(representations: [PasteboardRepresentation]) {
    self.representations = representations
  }

  /// A plain-text item.
  public init(text: String) {
    self.init(representations: [
      PasteboardRepresentation(type: ClipboardSession.plainTextType, data: Data(text.utf8))
    ])
  }

  public var types: [String] {
    representations.map(\.type)
  }

  /// Its plain text, if it has some.
  public var string: String? {
    representations.first { $0.type == ClipboardSession.plainTextType }
      .flatMap { String(data: $0.data, encoding: .utf8) }
  }
}

/// The general pasteboard, as `ClipboardSession` uses it: `NSPasteboard` in
/// the shell, memory in the tests.
@MainActor
public protocol EviePasteboard: AnyObject {
  /// Bumped by every write, whoever made it.
  var changeCount: Int { get }
  func items() -> [PasteboardItemSnapshot]
  /// Clears the pasteboard, writes `items` and returns the new change count.
  func replace(with items: [PasteboardItemSnapshot]) -> Int
}

/// Evie's use of the clipboard, which belongs to the person.
///
/// To paste a text she saves every item with every type, puts the text on
/// marked `org.nspasteboard.TransientType` and `ConcealedType` — the
/// convention clipboard managers follow to skip an entry and keep it out of
/// their history — posts ⌘V, and 400 ms later puts the person's items back,
/// but only if the change count is still the one her write produced: if it
/// moved, someone copied something in between, and that copy is now theirs
/// to keep. The wait runs to its end even when the session is stopped,
/// because the app reads the pasteboard when it handles ⌘V, after the event
/// was posted; restoring early would paste the person's own clipboard into
/// it.
@MainActor
public final class ClipboardSession {
  public nonisolated static let restoreDelay: TimeInterval = 0.4
  public nonisolated static let plainTextType = "public.utf8-plain-text"
  public nonisolated static let transientType = "org.nspasteboard.TransientType"
  public nonisolated static let concealedType = "org.nspasteboard.ConcealedType"

  public typealias Sleep = @MainActor (TimeInterval) async throws -> Void

  private let pasteboard: any EviePasteboard
  private let sleep: Sleep

  public init(
    pasteboard: any EviePasteboard,
    sleep: @escaping Sleep = { try await Task.sleep(for: .seconds($0)) }
  ) {
    self.pasteboard = pasteboard
    self.sleep = sleep
  }

  /// Puts `text` on the clipboard for `paste` (which posts ⌘V), then
  /// restores what was there.
  public func withTransientText<Result>(
    _ text: String,
    _ paste: () async throws -> Result
  ) async throws -> Result {
    let saved = pasteboard.items()
    let ours = pasteboard.replace(with: [
      PasteboardItemSnapshot(representations: [
        PasteboardRepresentation(type: Self.plainTextType, data: Data(text.utf8)),
        PasteboardRepresentation(type: Self.transientType, data: Data()),
        PasteboardRepresentation(type: Self.concealedType, data: Data()),
      ])
    ])
    let outcome: Swift.Result<Result, any Error>
    do {
      outcome = .success(try await paste())
    } catch {
      outcome = .failure(error)
    }
    await waitOutCancellation(Self.restoreDelay)
    if pasteboard.changeCount == ours {
      _ = pasteboard.replace(with: saved)
    }
    return try outcome.get()
  }

  /// `clipboard_write`: a text the person is to keep, so it is plain and is
  /// not restored.
  public func writeForPerson(_ text: String) {
    _ = pasteboard.replace(with: [PasteboardItemSnapshot(text: text)])
  }

  /// `clipboard_read`: the first item's plain text.
  public func readText() -> String? {
    pasteboard.items().first?.string
  }

  /// The wait, in a task of its own so a cancelled session cannot cut it
  /// short.
  private func waitOutCancellation(_ seconds: TimeInterval) async {
    let sleep = self.sleep
    await Task { @MainActor in try? await sleep(seconds) }.value
  }
}
