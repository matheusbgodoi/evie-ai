import Foundation
import Testing

@testable import EvieCore

/// The containment tests matter more than the happy path.
///
/// Reading a file that exists is easy to get right. What has to be proven is that
/// every way out of the granted folder is closed, including the ones that only
/// appear between the check and the open.
@Suite("Evie scoped file reader")
struct EvieScopedFileReaderTests {
  @Test("lists a granted folder, newest names sorted naturally")
  func listsFolder() throws {
    let root = try makeRoot([
      "a.txt": "primeiro",
      "b.txt": "segundo",
      "sub/c.txt": "terceiro",
    ])
    defer { try? FileManager.default.removeItem(at: root) }

    let listing = try EvieScopedFileReader().list(root: root)

    #expect(listing.entries.map(\.name) == ["a.txt", "b.txt", "sub"])
    #expect(listing.entries.first { $0.name == "sub" }?.isDirectory == true)
    #expect(listing.entries.first { $0.name == "a.txt" }?.byteSize == 8)
    #expect(!listing.hasMore)
  }

  @Test("reads a file inside the granted folder")
  func readsFile() throws {
    let root = try makeRoot(["nota.txt": "Reunião às 14h com o time."])
    defer { try? FileManager.default.removeItem(at: root) }

    let excerpt = try EvieScopedFileReader().read(root: root, relativePath: "nota.txt")

    #expect(excerpt.text == "Reunião às 14h com o time.")
    #expect(!excerpt.isTruncated)
  }

  @Test("reads through a subfolder")
  func readsNestedFile() throws {
    let root = try makeRoot(["projetos/evie/leia.md": "# Evie"])
    defer { try? FileManager.default.removeItem(at: root) }

    let excerpt = try EvieScopedFileReader().read(
      root: root,
      relativePath: "projetos/evie/leia.md"
    )

    #expect(excerpt.text == "# Evie")
  }

  // MARK: - Escapes

  @Test("refuses a path that climbs out with ..")
  func refusesParentTraversal() throws {
    let root = try makeRoot(["dentro.txt": "ok"])
    defer { try? FileManager.default.removeItem(at: root) }

    #expect(throws: EvieScopedFileReader.ReaderError.escapesRoot("../../etc/hosts")) {
      _ = try EvieScopedFileReader().read(root: root, relativePath: "../../etc/hosts")
    }
  }

  @Test("refuses an absolute path")
  func refusesAbsolutePath() throws {
    let root = try makeRoot(["dentro.txt": "ok"])
    defer { try? FileManager.default.removeItem(at: root) }

    #expect(throws: EvieScopedFileReader.ReaderError.escapesRoot("/etc/hosts")) {
      _ = try EvieScopedFileReader().read(root: root, relativePath: "/etc/hosts")
    }
  }

  /// The interesting one. The path is entirely inside the root and contains no
  /// `..` — the escape is in the filesystem, not in the string.
  @Test("refuses a symlink that points outside the granted folder")
  func refusesEscapingSymlink() throws {
    let root = try makeRoot(["dentro.txt": "ok"])
    defer { try? FileManager.default.removeItem(at: root) }
    try FileManager.default.createSymbolicLink(
      atPath: root.appendingPathComponent("fuga").path,
      withDestinationPath: "/etc/hosts"
    )

    #expect(throws: EvieScopedFileReader.ReaderError.escapesRoot("fuga")) {
      _ = try EvieScopedFileReader().read(root: root, relativePath: "fuga")
    }
  }

  /// A symlink in the *middle* of the path is the version people forget.
  @Test("refuses a symlinked folder partway along the path")
  func refusesEscapingIntermediateSymlink() throws {
    let root = try makeRoot(["dentro.txt": "ok"])
    defer { try? FileManager.default.removeItem(at: root) }
    try FileManager.default.createSymbolicLink(
      atPath: root.appendingPathComponent("etc").path,
      withDestinationPath: "/etc"
    )

    #expect(throws: EvieScopedFileReader.ReaderError.escapesRoot("etc/hosts")) {
      _ = try EvieScopedFileReader().read(root: root, relativePath: "etc/hosts")
    }
  }

  // MARK: - Denylist

  @Test("refuses credentials even inside a granted folder")
  func refusesDeniedNames() throws {
    let root = try makeRoot([
      "normal.txt": "ok",
      ".env": "VALOR_SINTETICO=1",
      // Deliberately not shaped like a real key: this fixture only has to
      // exist, and a credential scanner should never have to think about it.
      "chave.pem": "conteudo-sintetico-de-teste",
    ])
    defer { try? FileManager.default.removeItem(at: root) }

    #expect(throws: EvieScopedFileReader.ReaderError.denied(".env")) {
      _ = try EvieScopedFileReader().read(root: root, relativePath: ".env")
    }
    #expect(throws: EvieScopedFileReader.ReaderError.denied("chave.pem")) {
      _ = try EvieScopedFileReader().read(root: root, relativePath: "chave.pem")
    }
  }

  @Test("hides denied entries from listings and counts them")
  func withholdsDeniedEntriesFromListings() throws {
    let root = try makeRoot([
      "normal.txt": "ok",
      ".env": "VALOR_SINTETICO=1",
      "id_rsa": "conteudo-sintetico",
    ])
    defer { try? FileManager.default.removeItem(at: root) }

    let listing = try EvieScopedFileReader().list(root: root)

    #expect(listing.entries.map(\.name) == ["normal.txt"])
    #expect(listing.withheldCount == 2)
  }

  @Test("refuses a denied folder anywhere along the path")
  func refusesDeniedIntermediateComponent() throws {
    let root = try makeRoot([".ssh/config": "Host *"])
    defer { try? FileManager.default.removeItem(at: root) }

    #expect(throws: EvieScopedFileReader.ReaderError.denied(".ssh")) {
      _ = try EvieScopedFileReader().read(root: root, relativePath: ".ssh/config")
    }
  }

  @Test("recognises every shape of denied name")
  func classifiesDeniedNames() {
    #expect(EvieScopedFileReader.isDenied(".env"))
    #expect(EvieScopedFileReader.isDenied(".env.production"))
    #expect(EvieScopedFileReader.isDenied("id_ed25519"))
    #expect(EvieScopedFileReader.isDenied("servidor.pem"))
    #expect(EvieScopedFileReader.isDenied("cofre.kdbx"))
    #expect(!EvieScopedFileReader.isDenied("relatorio.pdf"))
    #expect(!EvieScopedFileReader.isDenied("environment.md"))
  }

  /// Granting the whole home folder must not hand over Mail, Messages, browser
  /// cookies, or the OAuth tokens applications leave in Application Support.
  @Test("the Library folder is refused, so a home grant does not include it")
  func withholdsLibrary() throws {
    #expect(EvieScopedFileReader.isDenied("Library"))

    let home = try makeRoot([
      "Library/Mail/V10/mensagem.emlx": "De: banco\nAssunto: sua senha\n",
      "nota.txt": "visível\n",
    ])
    defer { try? FileManager.default.removeItem(at: home) }

    let listing = try EvieScopedFileReader().list(root: home)
    #expect(!listing.entries.contains { $0.name == "Library" })
    #expect(listing.entries.contains { $0.name == "nota.txt" })
    #expect(listing.withheldCount == 1)

    #expect(throws: EvieScopedFileReader.ReaderError.denied("Library")) {
      _ = try EvieScopedFileReader().read(
        root: home,
        relativePath: "Library/Mail/V10/mensagem.emlx"
      )
    }
  }

  // MARK: - Limits

  @Test("truncates a long file and says that it did")
  func truncatesLongFiles() throws {
    let root = try makeRoot(["grande.txt": String(repeating: "a", count: 5_000)])
    defer { try? FileManager.default.removeItem(at: root) }

    var reader = EvieScopedFileReader()
    reader.maximumReadBytes = 1_000
    let excerpt = try reader.read(root: root, relativePath: "grande.txt")

    #expect(excerpt.text.count == 1_000)
    #expect(excerpt.byteSize == 5_000)
    #expect(excerpt.isTruncated)
  }

  @Test("refuses a binary file rather than returning noise")
  func refusesBinaryFiles() throws {
    let root = try makeRoot([:])
    defer { try? FileManager.default.removeItem(at: root) }
    try Data([0x89, 0x50, 0x4E, 0x47, 0x00, 0x01, 0x02]).write(
      to: root.appendingPathComponent("imagem.bin")
    )

    #expect(throws: EvieScopedFileReader.ReaderError.notText("imagem.bin")) {
      _ = try EvieScopedFileReader().read(root: root, relativePath: "imagem.bin")
    }
  }

  @Test("pages a large folder instead of returning all of it")
  func pagesLargeFolders() throws {
    var files: [String: String] = [:]
    for index in 0..<10 {
      files[String(format: "arquivo-%02d.txt", index)] = "x"
    }
    let root = try makeRoot(files)
    defer { try? FileManager.default.removeItem(at: root) }

    var reader = EvieScopedFileReader()
    reader.pageSize = 4

    let first = try reader.list(root: root)
    #expect(first.entries.count == 4)
    #expect(first.hasMore)
    #expect(first.entries.first?.name == "arquivo-00.txt")

    let second = try reader.list(root: root, offset: 8)
    #expect(second.entries.count == 2)
    #expect(!second.hasMore)
    #expect(second.entries.first?.name == "arquivo-08.txt")
  }

  @Test("reports a missing file by name")
  func reportsMissingFiles() throws {
    let root = try makeRoot([:])
    defer { try? FileManager.default.removeItem(at: root) }

    #expect(throws: EvieScopedFileReader.ReaderError.notFound("ausente.txt")) {
      _ = try EvieScopedFileReader().read(root: root, relativePath: "ausente.txt")
    }
  }

  @Test("does not pretend a folder is a file")
  func refusesReadingADirectory() throws {
    let root = try makeRoot(["sub/a.txt": "x"])
    defer { try? FileManager.default.removeItem(at: root) }

    #expect(throws: EvieScopedFileReader.ReaderError.isADirectory("sub")) {
      _ = try EvieScopedFileReader().read(root: root, relativePath: "sub")
    }
  }

  @Test("reports a root that has gone away")
  func reportsMissingRoot() {
    let missing = URL(fileURLWithPath: "/tmp/\(UUID().uuidString)")

    #expect(throws: EvieScopedFileReader.ReaderError.self) {
      _ = try EvieScopedFileReader().list(root: missing)
    }
  }
}

extension EvieScopedFileReaderTests {
  fileprivate func makeRoot(_ files: [String: String]) throws -> URL {
    let root = FileManager.default.temporaryDirectory
      .appendingPathComponent(UUID().uuidString, isDirectory: true)
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)

    for (path, contents) in files {
      let url = root.appendingPathComponent(path)
      try FileManager.default.createDirectory(
        at: url.deletingLastPathComponent(),
        withIntermediateDirectories: true
      )
      try contents.write(to: url, atomically: true, encoding: .utf8)
    }
    return root
  }
}
