import Foundation
import Testing

@testable import EvieCore

@Suite("Evie root registry")
struct EvieRootRegistryTests {
  @Test("round-trips a grant")
  func roundTrip() throws {
    let fileURL = temporaryFileURL()
    let registry = EvieRootRegistry(fileURL: fileURL)
    let root = EvieFileRoot(displayName: "Downloads", path: "/Users/alguem/Downloads")

    try registry.save([root])
    let loaded = registry.load()

    #expect(loaded.count == 1)
    #expect(loaded.first?.id == root.id)
    #expect(loaded.first?.path == root.path)
  }

  @Test("restricts the file to the current user")
  func permissions() throws {
    let fileURL = temporaryFileURL()

    try EvieRootRegistry(fileURL: fileURL).save([
      EvieFileRoot(displayName: "Documentos", path: "/Users/alguem/Documents")
    ])

    let attributes = try FileManager.default.attributesOfItem(atPath: fileURL.path)
    let directory = try FileManager.default.attributesOfItem(
      atPath: fileURL.deletingLastPathComponent().path
    )
    #expect((attributes[.posixPermissions] as? NSNumber)?.intValue == 0o600)
    #expect((directory[.posixPermissions] as? NSNumber)?.intValue == 0o700)
  }

  /// Failing closed matters more here than anywhere else: an unreadable registry
  /// must mean Evie can see nothing, never everything.
  @Test("a damaged or future file grants nothing rather than everything")
  func failsClosed() throws {
    let fileURL = temporaryFileURL()
    try FileManager.default.createDirectory(
      at: fileURL.deletingLastPathComponent(),
      withIntermediateDirectories: true
    )

    try Data("{ not json".utf8).write(to: fileURL)
    #expect(EvieRootRegistry(fileURL: fileURL).load().isEmpty)

    try Data(#"{"schema_version": 99, "roots": []}"#.utf8).write(to: fileURL)
    #expect(EvieRootRegistry(fileURL: fileURL).load().isEmpty)
  }

  @Test("a missing file simply grants nothing")
  func missingFile() {
    #expect(EvieRootRegistry(fileURL: temporaryFileURL()).load().isEmpty)
  }

  @Test("identifiers are short, opaque, and distinct")
  func identifiers() {
    let identifiers = Set((0..<200).map { _ in EvieFileRoot.makeIdentifier() })

    #expect(identifiers.count == 200)
    #expect(identifiers.allSatisfy { $0.count == 8 })
    #expect(identifiers.allSatisfy { !$0.contains("/") })
  }

  // MARK: - Overlapping grants

  @Test("granting the same folder twice is refused")
  func refusesDuplicates() throws {
    let registry = EvieRootRegistry(fileURL: temporaryFileURL())
    let existing = [EvieFileRoot(displayName: "Downloads", path: "/tmp/evie-test/Downloads")]

    #expect(throws: EvieRootRegistry.RegistryError.self) {
      _ = try registry.grant(
        EvieFileRoot(displayName: "Downloads de novo", path: "/tmp/evie-test/Downloads/"),
        to: existing
      )
    }
  }

  @Test("granting a folder inside a granted one is refused")
  func refusesNestedGrant() throws {
    let registry = EvieRootRegistry(fileURL: temporaryFileURL())
    let existing = [EvieFileRoot(displayName: "Casa", path: "/tmp/evie-test")]

    #expect(throws: EvieRootRegistry.RegistryError.self) {
      _ = try registry.grant(
        EvieFileRoot(displayName: "Downloads", path: "/tmp/evie-test/Downloads"),
        to: existing
      )
    }
  }

  /// The reverse case is not an error but it must not leave two doors to the same
  /// file, because revoking one would leave the other open.
  @Test("granting a parent replaces the children it contains")
  func parentReplacesChildren() throws {
    let registry = EvieRootRegistry(fileURL: temporaryFileURL())
    let existing = [
      EvieFileRoot(displayName: "Downloads", path: "/tmp/evie-test/Downloads"),
      EvieFileRoot(displayName: "Documentos", path: "/tmp/evie-test/Documents"),
      EvieFileRoot(displayName: "Outro", path: "/tmp/outro"),
    ]

    let updated = try registry.grant(
      EvieFileRoot(displayName: "Casa", path: "/tmp/evie-test"),
      to: existing
    )

    #expect(updated.count == 2)
    #expect(updated.contains { $0.displayName == "Casa" })
    #expect(updated.contains { $0.displayName == "Outro" })
    #expect(!updated.contains { $0.displayName == "Downloads" })
  }

  @Test("a trailing slash is the same folder")
  func canonicalisesPaths() {
    #expect(
      EvieRootRegistry.canonicalPath("/tmp/evie/") == EvieRootRegistry.canonicalPath("/tmp/evie")
    )
  }

  @Test("refuses more roots than it will keep")
  func enforcesCeiling() throws {
    let registry = EvieRootRegistry(fileURL: temporaryFileURL())
    let many = (0..<EvieRootRegistry.maximumRoots + 1).map { index in
      EvieFileRoot(displayName: "P\(index)", path: "/tmp/evie-test/p\(index)")
    }

    #expect(throws: EvieRootRegistry.RegistryError.tooManyRoots) {
      try registry.save(many)
    }
  }

  // MARK: - Revoking

  @Test("revoking removes exactly one grant")
  func revokes() throws {
    let registry = EvieRootRegistry(fileURL: temporaryFileURL())
    let keep = EvieFileRoot(displayName: "Documentos", path: "/tmp/a")
    let drop = EvieFileRoot(displayName: "Downloads", path: "/tmp/b")

    let updated = try registry.revoke(id: drop.id, from: [keep, drop])

    #expect(updated.map(\.id) == [keep.id])
  }

  @Test("revoking something that was never granted is an error, not a silent success")
  func revokeUnknown() {
    let registry = EvieRootRegistry(fileURL: temporaryFileURL())

    #expect(throws: EvieRootRegistry.RegistryError.notFound("nada")) {
      _ = try registry.revoke(id: "nada", from: [])
    }
  }
}

extension EvieRootRegistryTests {
  fileprivate func temporaryFileURL() -> URL {
    FileManager.default.temporaryDirectory
      .appendingPathComponent(UUID().uuidString, isDirectory: true)
      .appendingPathComponent("roots.json", isDirectory: false)
  }
}
