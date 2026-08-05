import Foundation
import Testing

@testable import EvieCore

@Suite("Evie memory")
struct EvieMemoryTests {
  // MARK: - The boundary that matters

  /// The whole design in one assertion: she can ask, and asking is all she can
  /// do. A tool that could write would make prompt injection able to plant a
  /// permanent fact.
  @Test("the memory tool changes nothing — it only proposes")
  func theToolOnlyProposes() {
    let definition = EvieMemoryTool.definition

    #expect(definition.name == "propose_memory")
    #expect(definition.name.contains("propose"))
    for verb in ["write", "save", "store", "remember_", "delete", "forget"] {
      #expect(!definition.name.contains(verb))
    }
    #expect(definition.parameters.map(\.name) == ["fact"])
  }

  // MARK: - Storing

  @Test("round-trips what was confirmed")
  func roundTrip() throws {
    let store = EvieMemoryStore(fileURL: temporaryFileURL())

    let entries = try store.remember("Prefere reuniões de manhã.", in: [])
    try store.save(entries)

    let loaded = store.load()
    #expect(loaded.count == 1)
    #expect(loaded.first?.text == "Prefere reuniões de manhã.")
  }

  @Test("restricts the file to the current user")
  func permissions() throws {
    let fileURL = temporaryFileURL()
    let store = EvieMemoryStore(fileURL: fileURL)

    try store.save(try store.remember("Algo.", in: []))

    let attributes = try FileManager.default.attributesOfItem(atPath: fileURL.path)
    #expect((attributes[.posixPermissions] as? NSNumber)?.intValue == 0o600)
  }

  /// Forgetting is recoverable; acting on a half-decoded fact is not.
  @Test("a damaged or future file remembers nothing")
  func failsClosed() throws {
    let fileURL = temporaryFileURL()
    try FileManager.default.createDirectory(
      at: fileURL.deletingLastPathComponent(),
      withIntermediateDirectories: true
    )

    try Data("{ not json".utf8).write(to: fileURL)
    #expect(EvieMemoryStore(fileURL: fileURL).load().isEmpty)

    try Data(#"{"schema_version": 99, "entries": []}"#.utf8).write(to: fileURL)
    #expect(EvieMemoryStore(fileURL: fileURL).load().isEmpty)
  }

  @Test("an empty memory is refused")
  func refusesEmpty() {
    let store = EvieMemoryStore(fileURL: temporaryFileURL())

    #expect(throws: EvieMemoryStore.MemoryError.empty) {
      _ = try store.remember("   \n ", in: [])
    }
  }

  /// A memory is a sentence, because every one of them is read back into every
  /// prompt. A paragraph belongs in the vault.
  @Test("something too long to be a fact is refused")
  func refusesLong() {
    let store = EvieMemoryStore(fileURL: temporaryFileURL())
    let long = String(repeating: "a", count: EvieMemoryStore.maximumEntryLength + 1)

    #expect(throws: EvieMemoryStore.MemoryError.tooLong) {
      _ = try store.remember(long, in: [])
    }
  }

  @Test("the same fact confirmed twice is stored once")
  func deduplicates() throws {
    let store = EvieMemoryStore(fileURL: temporaryFileURL())

    let once = try store.remember("Prefere reuniões de manhã.", in: [])
    let twice = try store.remember("prefere REUNIOES de manha.", in: once)

    #expect(twice.count == 1)
  }

  @Test("refuses more than it will read back")
  func enforcesCeiling() throws {
    let store = EvieMemoryStore(fileURL: temporaryFileURL())
    var entries: [EvieMemoryEntry] = []
    for index in 0..<EvieMemoryStore.maximumEntries {
      entries = try store.remember("Fato número \(index).", in: entries)
    }

    #expect(throws: EvieMemoryStore.MemoryError.full) {
      _ = try store.remember("Um a mais.", in: entries)
    }
  }

  @Test("forgetting removes exactly one")
  func forgets() throws {
    let store = EvieMemoryStore(fileURL: temporaryFileURL())
    let entries = try store.remember("B.", in: try store.remember("A.", in: []))
    let target = try #require(entries.first { $0.text == "A." })

    let updated = store.forget(id: target.id, in: entries)

    #expect(updated.count == 1)
    #expect(updated.first?.text == "B.")
  }

  // MARK: - Reading it back

  @Test("nothing remembered adds nothing to the instructions")
  func noRecallWhenEmpty() {
    #expect(EvieMemoryStore.recallBlock(from: []) == nil)
  }

  @Test("what is remembered comes back, newest first")
  func recallsNewestFirst() throws {
    let old = EvieMemoryEntry(text: "Antigo.", createdAt: Date(timeIntervalSince1970: 1))
    let new = EvieMemoryEntry(text: "Recente.", createdAt: Date(timeIntervalSince1970: 2))

    let block = try #require(EvieMemoryStore.recallBlock(from: [old, new]))

    let recentIndex = try #require(block.range(of: "Recente."))
    let oldIndex = try #require(block.range(of: "Antigo."))
    #expect(recentIndex.lowerBound < oldIndex.lowerBound)
  }

  /// Everything remembered is paid for on every single turn, so the budget has to
  /// be enforced in characters rather than in entries.
  @Test("recall is bounded by characters, not by count")
  func recallIsBounded() {
    let entries = (0..<200).map { index in
      EvieMemoryEntry(
        text: String(repeating: "x", count: 100),
        createdAt: Date(timeIntervalSince1970: Double(index))
      )
    }

    let block = EvieMemoryStore.recallBlock(from: entries) ?? ""

    #expect(block.count < EvieMemoryStore.maximumRecalledCharacters + 400)
  }

  @Test("the recalled block tells her not to announce that she is remembering")
  func recallIsQuiet() throws {
    let block = try #require(
      EvieMemoryStore.recallBlock(from: [EvieMemoryEntry(text: "Algo.")])
    )

    #expect(block.contains("sem anunciar"))
    #expect(block.contains("Algo."))
  }
}

extension EvieMemoryTests {
  fileprivate func temporaryFileURL() -> URL {
    FileManager.default.temporaryDirectory
      .appendingPathComponent(UUID().uuidString, isDirectory: true)
      .appendingPathComponent("memory.json", isDirectory: false)
  }
}
