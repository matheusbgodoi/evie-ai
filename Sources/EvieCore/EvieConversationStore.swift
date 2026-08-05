import Darwin
import Foundation

/// Actor-isolated, local JSON persistence for Evie's visible conversation history.
///
/// Every conversation is stored separately so one malformed record has a stable,
/// bounded failure mode. The actor protects callers within this process; a future
/// supervisor remains responsible for cross-process ownership.
public actor EvieConversationStore {
  public enum ValidationFailure: String, Error, Equatable, Sendable {
    case emptyTitle
    case titleTooLong
    case invalidTimestamp
    case updatedBeforeCreated
    case messageAfterConversationUpdate
    case duplicateMessageIdentifier
    case hiddenPromptPresent
  }

  public enum StoreError: Error, Equatable, Sendable {
    case conversationAlreadyExists(UUID)
    case conversationNotFound(UUID)
    case invalidConversation(ValidationFailure)
    case malformedRecord
    case storageUnavailable
    case unsupportedSchemaVersion(Int)
    case writeFailed
    case deleteFailed
  }

  public static var defaultDirectoryURL: URL {
    let applicationSupport =
      FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
      ?? FileManager.default.homeDirectoryForCurrentUser
      .appendingPathComponent("Library/Application Support", isDirectory: true)

    return
      applicationSupport
      .appendingPathComponent("Evie", isDirectory: true)
      .appendingPathComponent("Conversations", isDirectory: true)
  }

  public let directoryURL: URL

  private static let directoryPermissions = 0o700
  private static let filePermissions = 0o600
  private static let maximumTitleLength = 200

  private let fileManager: FileManager
  private let now: @Sendable () -> Date

  public init(
    directoryURL: URL = EvieConversationStore.defaultDirectoryURL,
    fileManager: FileManager = .default,
    now: @escaping @Sendable () -> Date = { Date() }
  ) {
    self.directoryURL = directoryURL.standardizedFileURL
    self.fileManager = fileManager
    self.now = now
  }

  /// Lists every readable conversation newest-first.
  ///
  /// Use ``scan()`` when the caller must surface an opaque count of unavailable
  /// records. This convenience deliberately returns the readable subset.
  public func list() throws -> [EvieConversationSummary] {
    try scan().conversations
  }

  /// Scans records independently so one unavailable record cannot hide the rest.
  public func scan() throws -> EvieConversationScan {
    try prepareDirectory()

    let fileURLs: [URL]
    do {
      fileURLs = try fileManager.contentsOfDirectory(
        at: directoryURL,
        includingPropertiesForKeys: [.isRegularFileKey, .isSymbolicLinkKey],
        options: [.skipsHiddenFiles, .skipsSubdirectoryDescendants]
      )
    } catch {
      throw StoreError.storageUnavailable
    }

    let recordURLs =
      fileURLs
      .filter { $0.pathExtension == "json" }
      .sorted { $0.lastPathComponent < $1.lastPathComponent }

    var summaries: [EvieConversationSummary] = []
    var unavailableRecordCount = 0
    for fileURL in recordURLs {
      let stem = fileURL.deletingPathExtension().lastPathComponent
      guard
        let identifier = UUID(uuidString: stem),
        stem == canonicalIdentifier(identifier)
      else {
        unavailableRecordCount += 1
        continue
      }

      do {
        let conversation = try decodeRecord(at: fileURL, expectedIdentifier: identifier)
        summaries.append(EvieConversationSummary(conversation: conversation))
      } catch {
        unavailableRecordCount += 1
      }
    }

    let sorted = summaries.sorted { left, right in
      if left.updatedAt != right.updatedAt {
        return left.updatedAt > right.updatedAt
      }
      return canonicalIdentifier(left.id) < canonicalIdentifier(right.id)
    }
    return EvieConversationScan(
      conversations: sorted,
      unavailableRecordCount: unavailableRecordCount
    )
  }

  /// Creates and persists a conversation with a caller-selectable stable ID.
  public func create(
    id: UUID = UUID(),
    title: String,
    messages: [ChatMessage] = []
  ) throws -> EvieConversation {
    try prepareDirectory()
    let fileURL = recordURL(for: id)
    guard !fileManager.fileExists(atPath: fileURL.path) else {
      throw StoreError.conversationAlreadyExists(id)
    }

    let timestamp = now()
    let conversation = EvieConversation(
      id: id,
      title: title,
      createdAt: timestamp,
      updatedAt: timestamp,
      messages: messages
    )
    return try persist(conversation, updatingTimestamp: false)
  }

  public func load(id: UUID) throws -> EvieConversation {
    try prepareDirectory()
    let fileURL = recordURL(for: id)
    guard fileManager.fileExists(atPath: fileURL.path) else {
      throw StoreError.conversationNotFound(id)
    }
    return try decodeRecord(at: fileURL, expectedIdentifier: id)
  }

  /// Atomically creates or replaces a conversation record.
  ///
  /// Runtime-only system/developer prompts are removed before validation and are
  /// never written to disk. The returned value is the canonical persisted value.
  @discardableResult
  public func save(_ conversation: EvieConversation) throws -> EvieConversation {
    try prepareDirectory()
    return try persist(conversation, updatingTimestamp: true)
  }

  public func delete(id: UUID) throws {
    try prepareDirectory()
    let fileURL = recordURL(for: id)
    guard fileManager.fileExists(atPath: fileURL.path) else {
      throw StoreError.conversationNotFound(id)
    }
    try ensureRegularRecord(at: fileURL)

    do {
      try fileManager.removeItem(at: fileURL)
    } catch {
      throw StoreError.deleteFailed
    }
  }
}

extension EvieConversationStore.StoreError: LocalizedError {
  public var errorDescription: String? {
    switch self {
    case .conversationAlreadyExists:
      "A conversation with that identifier already exists."
    case .conversationNotFound:
      "The requested conversation does not exist."
    case .invalidConversation(let reason):
      "The conversation is invalid (\(reason.rawValue))."
    case .malformedRecord:
      "A stored conversation record is malformed."
    case .storageUnavailable:
      "The local conversation store is unavailable."
    case .unsupportedSchemaVersion(let version):
      "The conversation schema version \(version) is not supported."
    case .writeFailed:
      "The conversation could not be saved."
    case .deleteFailed:
      "The conversation could not be deleted."
    }
  }
}

extension EvieConversationStore {
  private struct RecordHeader: Decodable {
    var schemaVersion: Int

    private enum CodingKeys: String, CodingKey {
      case schemaVersion = "schema_version"
    }
  }

  private func persist(
    _ conversation: EvieConversation,
    updatingTimestamp: Bool
  ) throws -> EvieConversation {
    guard conversation.schemaVersion == EvieConversation.currentSchemaVersion else {
      throw StoreError.unsupportedSchemaVersion(conversation.schemaVersion)
    }

    var persisted = conversation
    persisted.title = persisted.title.trimmingCharacters(in: .whitespacesAndNewlines)
    persisted.messages.removeAll { message in
      message.role == .system || message.role == .developer
    }

    if updatingTimestamp {
      let latestMessageDate = persisted.messages.map(\.createdAt).max() ?? persisted.createdAt
      persisted.updatedAt = max(
        persisted.createdAt,
        persisted.updatedAt,
        latestMessageDate,
        now()
      )
    } else if let latestMessageDate = persisted.messages.map(\.createdAt).max() {
      persisted.updatedAt = max(persisted.updatedAt, latestMessageDate)
    }

    try validate(persisted)

    let data: Data
    do {
      let encoder = JSONEncoder()
      encoder.outputFormatting = [.sortedKeys]
      data = try encoder.encode(persisted)
    } catch {
      throw StoreError.writeFailed
    }

    try writeAtomically(data, to: recordURL(for: persisted.id))
    return persisted
  }

  private func decodeRecord(
    at fileURL: URL,
    expectedIdentifier: UUID
  ) throws -> EvieConversation {
    try ensureRegularRecord(at: fileURL)

    let data: Data
    do {
      data = try Data(contentsOf: fileURL, options: [.mappedIfSafe])
    } catch {
      throw StoreError.storageUnavailable
    }

    let decoder = JSONDecoder()

    let header: RecordHeader
    do {
      header = try decoder.decode(RecordHeader.self, from: data)
    } catch {
      throw StoreError.malformedRecord
    }

    guard header.schemaVersion == EvieConversation.currentSchemaVersion else {
      throw StoreError.unsupportedSchemaVersion(header.schemaVersion)
    }

    let conversation: EvieConversation
    do {
      conversation = try decoder.decode(EvieConversation.self, from: data)
    } catch {
      throw StoreError.malformedRecord
    }

    guard conversation.id == expectedIdentifier else {
      throw StoreError.malformedRecord
    }

    try validate(conversation)
    return conversation
  }

  private func validate(_ conversation: EvieConversation) throws {
    guard conversation.schemaVersion == EvieConversation.currentSchemaVersion else {
      throw StoreError.unsupportedSchemaVersion(conversation.schemaVersion)
    }
    guard !conversation.title.isEmpty else {
      throw StoreError.invalidConversation(.emptyTitle)
    }
    guard conversation.title.count <= Self.maximumTitleLength else {
      throw StoreError.invalidConversation(.titleTooLong)
    }
    guard
      conversation.createdAt.timeIntervalSinceReferenceDate.isFinite,
      conversation.updatedAt.timeIntervalSinceReferenceDate.isFinite,
      conversation.messages.allSatisfy({ $0.createdAt.timeIntervalSinceReferenceDate.isFinite })
    else {
      throw StoreError.invalidConversation(.invalidTimestamp)
    }
    guard conversation.updatedAt >= conversation.createdAt else {
      throw StoreError.invalidConversation(.updatedBeforeCreated)
    }
    guard conversation.messages.allSatisfy({ $0.createdAt <= conversation.updatedAt }) else {
      throw StoreError.invalidConversation(.messageAfterConversationUpdate)
    }

    var messageIdentifiers = Set<UUID>()
    guard conversation.messages.allSatisfy({ messageIdentifiers.insert($0.id).inserted }) else {
      throw StoreError.invalidConversation(.duplicateMessageIdentifier)
    }
    guard conversation.messages.allSatisfy({ $0.role != .system && $0.role != .developer }) else {
      throw StoreError.invalidConversation(.hiddenPromptPresent)
    }
  }

  private func prepareDirectory() throws {
    guard directoryURL.isFileURL else {
      throw StoreError.storageUnavailable
    }

    var isDirectory: ObjCBool = false
    let exists = fileManager.fileExists(atPath: directoryURL.path, isDirectory: &isDirectory)

    do {
      if exists {
        guard isDirectory.boolValue else {
          throw StoreError.storageUnavailable
        }
      } else {
        try fileManager.createDirectory(
          at: directoryURL,
          withIntermediateDirectories: true,
          attributes: [.posixPermissions: Self.directoryPermissions]
        )
      }
      try fileManager.setAttributes(
        [.posixPermissions: Self.directoryPermissions],
        ofItemAtPath: directoryURL.path
      )
    } catch let error as StoreError {
      throw error
    } catch {
      throw StoreError.storageUnavailable
    }
  }

  private func ensureRegularRecord(at fileURL: URL) throws {
    let values: URLResourceValues
    do {
      values = try fileURL.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey])
    } catch {
      throw StoreError.storageUnavailable
    }

    guard values.isRegularFile == true, values.isSymbolicLink != true else {
      throw StoreError.malformedRecord
    }

    do {
      try fileManager.setAttributes(
        [.posixPermissions: Self.filePermissions],
        ofItemAtPath: fileURL.path
      )
    } catch {
      throw StoreError.storageUnavailable
    }
  }

  private func writeAtomically(_ data: Data, to destinationURL: URL) throws {
    let temporaryURL = directoryURL.appendingPathComponent(
      ".write-\(UUID().uuidString.lowercased()).tmp",
      isDirectory: false
    )
    var handle: FileHandle?

    defer {
      try? handle?.close()
      if fileManager.fileExists(atPath: temporaryURL.path) {
        try? fileManager.removeItem(at: temporaryURL)
      }
    }

    guard
      fileManager.createFile(
        atPath: temporaryURL.path,
        contents: nil,
        attributes: [.posixPermissions: Self.filePermissions]
      )
    else {
      throw StoreError.writeFailed
    }

    do {
      handle = try FileHandle(forWritingTo: temporaryURL)
      try handle?.write(contentsOf: data)
      try handle?.synchronize()
      try handle?.close()
      handle = nil
      try fileManager.setAttributes(
        [.posixPermissions: Self.filePermissions],
        ofItemAtPath: temporaryURL.path
      )
    } catch {
      throw StoreError.writeFailed
    }

    let renameResult = temporaryURL.path.withCString { temporaryPath in
      destinationURL.path.withCString { destinationPath in
        Darwin.rename(temporaryPath, destinationPath)
      }
    }
    guard renameResult == 0 else {
      throw StoreError.writeFailed
    }

    do {
      try fileManager.setAttributes(
        [.posixPermissions: Self.filePermissions],
        ofItemAtPath: destinationURL.path
      )
    } catch {
      throw StoreError.writeFailed
    }
  }

  private func recordURL(for identifier: UUID) -> URL {
    directoryURL.appendingPathComponent(
      "\(canonicalIdentifier(identifier)).json",
      isDirectory: false
    )
  }

  private func canonicalIdentifier(_ identifier: UUID) -> String {
    identifier.uuidString.lowercased()
  }
}
