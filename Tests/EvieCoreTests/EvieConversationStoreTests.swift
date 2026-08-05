import Foundation
import Testing

@testable import EvieCore

@Suite("Evie conversation store")
struct EvieConversationStoreTests {
  @Test("creates, lists, loads, updates, and deletes a conversation")
  func lifecycle() async throws {
    let fixture = try Fixture()
    defer { fixture.remove() }
    let initialDate = Date(timeIntervalSinceReferenceDate: 1_000.123_456)
    let updateDate = Date(timeIntervalSinceReferenceDate: 2_000.654_321)
    let identifier = UUID(uuidString: "00000000-0000-0000-0000-000000000001")!
    let clock = SequenceClock([initialDate, updateDate])
    let store = EvieConversationStore(directoryURL: fixture.directoryURL) {
      clock.next()
    }

    var conversation = try await store.create(id: identifier, title: "  First chat  ")
    #expect(conversation.id == identifier)
    #expect(conversation.title == "First chat")
    #expect(conversation.createdAt == initialDate)
    #expect(conversation.updatedAt == initialDate)

    conversation.messages.append(
      ChatMessage(
        id: UUID(uuidString: "00000000-0000-0000-0000-000000000002")!,
        role: .user,
        content: "Synthetic question",
        createdAt: updateDate
      )
    )
    conversation = try await store.save(conversation)

    let loaded = try await store.load(id: identifier)
    #expect(loaded == conversation)
    #expect(loaded.updatedAt == updateDate)
    #expect(loaded.messages.count == 1)

    let summaries = try await store.list()
    #expect(summaries == [EvieConversationSummary(conversation: conversation)])

    try await store.delete(id: identifier)
    await #expect(throws: EvieConversationStore.StoreError.conversationNotFound(identifier)) {
      try await store.load(id: identifier)
    }
  }

  @Test("never persists hidden system or developer prompts")
  func hiddenPromptsStayInMemory() async throws {
    let fixture = try Fixture()
    defer { fixture.remove() }
    let timestamp = Date(timeIntervalSince1970: 3_000)
    let identifier = UUID(uuidString: "00000000-0000-0000-0000-000000000010")!
    let store = EvieConversationStore(directoryURL: fixture.directoryURL) { timestamp }

    let persisted = try await store.create(
      id: identifier,
      title: "Policy boundary",
      messages: [
        ChatMessage(role: .system, content: "HIDDEN-SYSTEM-SENTINEL", createdAt: timestamp),
        ChatMessage(role: .developer, content: "HIDDEN-DEVELOPER-SENTINEL", createdAt: timestamp),
        ChatMessage(role: .user, content: "Visible fixture", createdAt: timestamp),
      ]
    )

    #expect(persisted.messages.map(\.role) == [.user])
    let record = try Data(contentsOf: fixture.recordURL(for: identifier))
    let encoded = String(decoding: record, as: UTF8.self)
    #expect(!encoded.contains("HIDDEN-SYSTEM-SENTINEL"))
    #expect(!encoded.contains("HIDDEN-DEVELOPER-SENTINEL"))
  }

  @Test("uses user-only directory and record permissions")
  func permissions() async throws {
    let fixture = try Fixture()
    defer { fixture.remove() }
    let identifier = UUID(uuidString: "00000000-0000-0000-0000-000000000020")!
    let store = EvieConversationStore(directoryURL: fixture.directoryURL)

    _ = try await store.create(id: identifier, title: "Permissions")

    #expect(try fixture.permissions(at: fixture.directoryURL) == 0o700)
    #expect(try fixture.permissions(at: fixture.recordURL(for: identifier)) == 0o600)
  }

  @Test("sorts newest first with a stable identifier tie-breaker")
  func deterministicOrdering() async throws {
    let fixture = try Fixture()
    defer { fixture.remove() }
    let timestamp = Date(timeIntervalSince1970: 4_000)
    let store = EvieConversationStore(directoryURL: fixture.directoryURL) { timestamp }
    let first = UUID(uuidString: "00000000-0000-0000-0000-000000000031")!
    let second = UUID(uuidString: "00000000-0000-0000-0000-000000000030")!

    _ = try await store.create(id: first, title: "First")
    _ = try await store.create(id: second, title: "Second")

    let summaries = try await store.list()
    #expect(summaries.map(\.id) == [second, first])
  }

  @Test("rejects malformed content without exposing it in the error")
  func malformedRecordIsRedacted() async throws {
    let fixture = try Fixture()
    defer { fixture.remove() }
    let identifier = UUID(uuidString: "00000000-0000-0000-0000-000000000040")!
    let secretLikeSentinel = "PRIVATE-FIXTURE-MUST-NOT-LEAK"
    try fixture.prepare()
    try Data("{\"payload\":\"\(secretLikeSentinel)\"}".utf8).write(
      to: fixture.recordURL(for: identifier)
    )
    let store = EvieConversationStore(directoryURL: fixture.directoryURL)

    do {
      _ = try await store.load(id: identifier)
      Issue.record("Expected malformed record failure")
    } catch {
      #expect(error as? EvieConversationStore.StoreError == .malformedRecord)
      #expect(!String(describing: error).contains(secretLikeSentinel))
      #expect(!error.localizedDescription.contains(secretLikeSentinel))
    }
  }

  @Test("scan contains one malformed record without hiding readable conversations")
  func scanContainsMalformedRecord() async throws {
    let fixture = try Fixture()
    defer { fixture.remove() }
    let timestamp = Date(timeIntervalSinceReferenceDate: 4_500)
    let readableIdentifier = UUID(uuidString: "00000000-0000-0000-0000-000000000045")!
    let malformedIdentifier = UUID(uuidString: "00000000-0000-0000-0000-000000000046")!
    let store = EvieConversationStore(directoryURL: fixture.directoryURL) { timestamp }
    let readable = try await store.create(id: readableIdentifier, title: "Readable fixture")
    try Data("{\"private_fixture\":\"must-not-escape\"}".utf8).write(
      to: fixture.recordURL(for: malformedIdentifier)
    )

    let scan = try await store.scan()

    #expect(scan.conversations == [EvieConversationSummary(conversation: readable)])
    #expect(scan.unavailableRecordCount == 1)
    await #expect(throws: EvieConversationStore.StoreError.malformedRecord) {
      try await store.load(id: malformedIdentifier)
    }
  }

  @Test("rejects unsupported schemas deterministically")
  func unsupportedSchema() async throws {
    let fixture = try Fixture()
    defer { fixture.remove() }
    let identifier = UUID(uuidString: "00000000-0000-0000-0000-000000000050")!
    try fixture.prepare()
    try Data("{\"schema_version\":99}".utf8).write(to: fixture.recordURL(for: identifier))
    let store = EvieConversationStore(directoryURL: fixture.directoryURL)

    await #expect(throws: EvieConversationStore.StoreError.unsupportedSchemaVersion(99)) {
      try await store.load(id: identifier)
    }
  }

  @Test("does not rewrite a caller's unsupported schema")
  func refusesUnsupportedSave() async throws {
    let fixture = try Fixture()
    defer { fixture.remove() }
    let store = EvieConversationStore(directoryURL: fixture.directoryURL)
    let conversation = EvieConversation(schemaVersion: 2, title: "Future fixture")

    await #expect(throws: EvieConversationStore.StoreError.unsupportedSchemaVersion(2)) {
      try await store.save(conversation)
    }
    #expect(!FileManager.default.fileExists(atPath: fixture.recordURL(for: conversation.id).path))
  }

  @Test("rejects hidden policy messages injected into an existing record")
  func rejectsPersistedHiddenPrompt() async throws {
    let fixture = try Fixture()
    defer { fixture.remove() }
    let timestamp = Date(timeIntervalSinceReferenceDate: 5_500)
    let identifier = UUID(uuidString: "00000000-0000-0000-0000-000000000055")!
    let injected = EvieConversation(
      id: identifier,
      title: "Injected policy",
      createdAt: timestamp,
      messages: [
        ChatMessage(role: .system, content: "POLICY-FIXTURE", createdAt: timestamp)
      ]
    )
    try fixture.prepare()
    let encoder = JSONEncoder()
    try encoder.encode(injected).write(to: fixture.recordURL(for: identifier))
    let store = EvieConversationStore(directoryURL: fixture.directoryURL)

    await #expect(
      throws: EvieConversationStore.StoreError.invalidConversation(.hiddenPromptPresent)
    ) {
      try await store.load(id: identifier)
    }
  }

  @Test("rejects a record whose embedded identifier differs from its filename")
  func identifierMismatch() async throws {
    let fixture = try Fixture()
    defer { fixture.remove() }
    let timestamp = Date(timeIntervalSince1970: 6_000)
    let storedIdentifier = UUID(uuidString: "00000000-0000-0000-0000-000000000060")!
    let requestedIdentifier = UUID(uuidString: "00000000-0000-0000-0000-000000000061")!
    let store = EvieConversationStore(directoryURL: fixture.directoryURL) { timestamp }
    let conversation = try await store.create(id: storedIdentifier, title: "Mismatch")
    let data = try Data(contentsOf: fixture.recordURL(for: storedIdentifier))
    try data.write(to: fixture.recordURL(for: requestedIdentifier))
    #expect(conversation.id == storedIdentifier)

    await #expect(throws: EvieConversationStore.StoreError.malformedRecord) {
      try await store.load(id: requestedIdentifier)
    }
  }

  @Test("rejects duplicate message identifiers")
  func duplicateMessages() async throws {
    let fixture = try Fixture()
    defer { fixture.remove() }
    let timestamp = Date(timeIntervalSince1970: 7_000)
    let messageIdentifier = UUID(uuidString: "00000000-0000-0000-0000-000000000070")!
    let store = EvieConversationStore(directoryURL: fixture.directoryURL) { timestamp }
    var conversation = EvieConversation(
      title: "Duplicate",
      createdAt: timestamp,
      messages: [
        ChatMessage(id: messageIdentifier, role: .user, content: "One", createdAt: timestamp),
        ChatMessage(id: messageIdentifier, role: .assistant, content: "Two", createdAt: timestamp),
      ]
    )

    conversation.updatedAt = timestamp
    await #expect(
      throws: EvieConversationStore.StoreError.invalidConversation(
        .duplicateMessageIdentifier
      )
    ) {
      try await store.save(conversation)
    }
  }

  @Test("serializes concurrent mutations through the actor")
  func concurrentCreates() async throws {
    let fixture = try Fixture()
    defer { fixture.remove() }
    let timestamp = Date(timeIntervalSince1970: 8_000)
    let store = EvieConversationStore(directoryURL: fixture.directoryURL) { timestamp }
    let identifiers = (1...24).map { value in
      UUID(uuidString: String(format: "00000000-0000-0000-0000-%012d", value))!
    }

    try await withThrowingTaskGroup(of: Void.self) { group in
      for identifier in identifiers {
        group.addTask {
          _ = try await store.create(id: identifier, title: "Concurrent fixture")
        }
      }
      try await group.waitForAll()
    }

    let summaries = try await store.list()
    #expect(Set(summaries.map(\.id)) == Set(identifiers))
    #expect(summaries.count == identifiers.count)
  }

  @Test("atomic replacement leaves no temporary files")
  func atomicReplacement() async throws {
    let fixture = try Fixture()
    defer { fixture.remove() }
    let initialDate = Date(timeIntervalSince1970: 9_000)
    let updateDate = Date(timeIntervalSince1970: 10_000)
    let clock = SequenceClock([initialDate, updateDate])
    let store = EvieConversationStore(directoryURL: fixture.directoryURL) {
      clock.next()
    }
    var conversation = try await store.create(title: "Initial")

    conversation.title = "Updated"
    let updated = try await store.save(conversation)
    let files = try FileManager.default.contentsOfDirectory(
      at: fixture.directoryURL,
      includingPropertiesForKeys: nil
    )

    #expect(try await store.load(id: updated.id).title == "Updated")
    #expect(files.filter { $0.pathExtension == "tmp" }.isEmpty)
    #expect(files.filter { $0.pathExtension == "json" }.count == 1)
  }
}

extension EvieConversationStoreTests {
  fileprivate final class SequenceClock: @unchecked Sendable {
    private let lock = NSLock()
    private var values: [Date]
    private var index = 0

    init(_ values: [Date]) {
      self.values = values
    }

    func next() -> Date {
      lock.withLock {
        let value = values[min(index, values.count - 1)]
        index += 1
        return value
      }
    }
  }

  fileprivate struct Fixture {
    let directoryURL: URL

    init() throws {
      directoryURL = FileManager.default.temporaryDirectory
        .appendingPathComponent("evie-conversations-\(UUID().uuidString)", isDirectory: true)
    }

    func prepare() throws {
      try FileManager.default.createDirectory(
        at: directoryURL,
        withIntermediateDirectories: true
      )
    }

    func recordURL(for identifier: UUID) -> URL {
      directoryURL.appendingPathComponent(
        "\(identifier.uuidString.lowercased()).json",
        isDirectory: false
      )
    }

    func permissions(at url: URL) throws -> Int {
      let attributes = try FileManager.default.attributesOfItem(atPath: url.path)
      return (attributes[.posixPermissions] as? NSNumber)?.intValue ?? -1
    }

    func remove() {
      try? FileManager.default.removeItem(at: directoryURL)
    }
  }
}
