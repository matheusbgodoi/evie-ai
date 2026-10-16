import Darwin
import Foundation
import Testing

@testable import EvieCore

/// The Mac brain's per-launch key (ADR 0017): made fresh for every start,
/// kept only in a 0600 file beside `brain.pid`, and read back only from a file
/// nobody else could have written or read.
@Suite("Local brain key")
struct LocalBrainKeyTests {
  @Test("a key is 32 random bytes in hex, and a new one for every launch")
  func keysAreFreshAndHex() {
    let first = LocalBrainKeyFile.makeKey()
    let second = LocalBrainKeyFile.makeKey()

    #expect(first.count == 64)
    #expect(first.allSatisfy { $0.isHexDigit && !$0.isUppercase })
    #expect(first != second)
  }

  @Test("the key is written for this user alone and read back")
  func writtenUserOnly() throws {
    let file = try Self.temporaryKeyFile()
    let key = LocalBrainKeyFile.makeKey()

    try file.write(key)

    #expect(try Self.permissions(of: file.url) == 0o600)
    #expect(file.read() == key)
  }

  @Test("writing again replaces the key, still for this user alone")
  func rewriteReplaces() throws {
    let file = try Self.temporaryKeyFile()
    try file.write(LocalBrainKeyFile.makeKey())
    let second = LocalBrainKeyFile.makeKey()

    try file.write(second)

    #expect(file.read() == second)
    #expect(try Self.permissions(of: file.url) == 0o600)
  }

  @Test("a file others could read, a symlink, or something that is not a key is not used")
  func untrustworthyFilesAreIgnored() throws {
    let key = LocalBrainKeyFile.makeKey()

    let readable = try Self.temporaryKeyFile()
    try file(readable, contents: key, permissions: 0o644)
    #expect(readable.read() == nil)

    let target = try Self.temporaryKeyFile()
    try target.write(key)
    let link = try Self.temporaryKeyFile()
    try FileManager.default.createSymbolicLink(at: link.url, withDestinationURL: target.url)
    #expect(link.read() == nil)

    for contents in ["", "abc", String(repeating: "g", count: 64), key + key, "Bearer " + key] {
      let malformed = try Self.temporaryKeyFile()
      try file(malformed, contents: contents, permissions: 0o600)
      #expect(malformed.read() == nil, "\(contents.prefix(12))")
    }

    #expect(try Self.temporaryKeyFile().read() == nil)
  }

  @Test("a trailing newline, as the script writes it, is not part of the key")
  func trailingNewline() throws {
    let key = LocalBrainKeyFile.makeKey()
    let written = try Self.temporaryKeyFile()
    try file(written, contents: key + "\n", permissions: 0o600)

    #expect(written.read() == key)
  }

  @Test("removing the file leaves no key to read")
  func removeForgets() throws {
    let file = try Self.temporaryKeyFile()
    try file.write(LocalBrainKeyFile.makeKey())

    file.remove()

    #expect(file.read() == nil)
    #expect(!FileManager.default.fileExists(atPath: file.url.path))
  }

  @Test("the standard file sits beside brain.pid")
  func standardLocation() {
    #expect(
      LocalBrainKeyFile.standard.url.path.hasSuffix(
        "Library/Application Support/Evie/Runtime/brain.key"))
  }

  @Test("a server enforces the key when it refuses a request without it and answers one with it")
  func keyEnforcement() {
    #expect(LocalBrainPolicy.enforcesKey(statusWithoutKey: 401, statusWithKey: 200))
    // Open to anyone: a server started without the key.
    #expect(!LocalBrainPolicy.enforcesKey(statusWithoutKey: 200, statusWithKey: 200))
    // Started with another key.
    #expect(!LocalBrainPolicy.enforcesKey(statusWithoutKey: 401, statusWithKey: 401))
    #expect(!LocalBrainPolicy.enforcesKey(statusWithoutKey: nil, statusWithKey: 200))
    #expect(!LocalBrainPolicy.enforcesKey(statusWithoutKey: 401, statusWithKey: nil))
  }

  static func temporaryKeyFile() throws -> LocalBrainKeyFile {
    let directory = FileManager.default.temporaryDirectory
      .appendingPathComponent(UUID().uuidString, isDirectory: true)
    try FileManager.default.createDirectory(
      at: directory, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
    return LocalBrainKeyFile(url: directory.appendingPathComponent("brain.key"))
  }

  private static func permissions(of url: URL) throws -> Int? {
    let attributes = try FileManager.default.attributesOfItem(atPath: url.path)
    return (attributes[.posixPermissions] as? NSNumber)?.intValue
  }

  private func file(_ keyFile: LocalBrainKeyFile, contents: String, permissions: Int) throws {
    try Data(contents.utf8).write(to: keyFile.url)
    try FileManager.default.setAttributes(
      [.posixPermissions: permissions], ofItemAtPath: keyFile.url.path)
  }
}
