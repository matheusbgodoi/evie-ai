import Foundation
import Testing

@testable import EvieCore

@Suite("Evie file writer")
struct EvieFileWriterTests {
  // MARK: - What it does when everything is right

  @Test("renames a file")
  func renames() throws {
    let root = try makeRoot(["nota.txt": "conteúdo"])
    defer { try? FileManager.default.removeItem(at: root.url) }
    let writer = EvieFileWriter()
    let change = EvieFileChange(
      kind: .rename,
      rootID: root.id,
      path: "nota.txt",
      destination: "lembrete.txt"
    )

    let receipt = try writer.perform(change, in: root)

    #expect(receipt.resultingPath == "lembrete.txt")
    #expect(FileManager.default.fileExists(atPath: root.url.appendingPathComponent("lembrete.txt").path))
    #expect(!FileManager.default.fileExists(atPath: root.url.appendingPathComponent("nota.txt").path))
  }

  @Test("moves a file into a folder that already exists")
  func moves() throws {
    let root = try makeRoot(["nota.txt": "x", "arquivo/marcador.txt": "y"])
    defer { try? FileManager.default.removeItem(at: root.url) }

    let receipt = try EvieFileWriter().perform(
      EvieFileChange(
        kind: .move,
        rootID: root.id,
        path: "nota.txt",
        destination: "arquivo/nota.txt"
      ),
      in: root
    )

    #expect(receipt.resultingPath == "arquivo/nota.txt")
    #expect(
      FileManager.default.fileExists(
        atPath: root.url.appendingPathComponent("arquivo/nota.txt").path
      )
    )
  }

  /// The whole point of the deletion rule: it has to be walkable back without
  /// Evie being involved.
  @Test("deleting means the Trash, and the file is gone from the folder")
  func trashes() throws {
    let root = try makeRoot(["descartar.txt": "x"])
    defer { try? FileManager.default.removeItem(at: root.url) }

    _ = try EvieFileWriter().perform(
      EvieFileChange(kind: .trash, rootID: root.id, path: "descartar.txt"),
      in: root
    )

    #expect(
      !FileManager.default.fileExists(
        atPath: root.url.appendingPathComponent("descartar.txt").path
      )
    )
  }

  // MARK: - The refusals, which are the point

  /// `rename(2)` and `FileManager.moveItem` both destroy the destination without
  /// a word. That is silent data loss, and it is why this drops to `renamex_np`.
  @Test("a move never overwrites what is already there")
  func refusesToOverwrite() throws {
    let root = try makeRoot(["a.txt": "novo", "b.txt": "PRECIOSO"])
    defer { try? FileManager.default.removeItem(at: root.url) }

    #expect(throws: EvieFileWriter.WriteError.destinationExists("b.txt")) {
      _ = try EvieFileWriter().perform(
        EvieFileChange(kind: .rename, rootID: root.id, path: "a.txt", destination: "b.txt"),
        in: root
      )
    }

    let survived = try String(
      contentsOf: root.url.appendingPathComponent("b.txt"),
      encoding: .utf8
    )
    #expect(survived == "PRECIOSO")
  }

  /// An approval is for the file the user was shown. If it changed in between,
  /// the sentence they agreed to is no longer true.
  @Test("a file edited after approval is left alone")
  func refusesWhenTheFileChanged() throws {
    let root = try makeRoot(["nota.txt": "original"])
    defer { try? FileManager.default.removeItem(at: root.url) }
    let writer = EvieFileWriter()
    var change = EvieFileChange(
      kind: .rename,
      rootID: root.id,
      path: "nota.txt",
      destination: "outro.txt"
    )
    change.precondition = try writer.precondition(of: change, in: root)

    // The user edits it while the card sits on screen.
    try "algo bem diferente e mais longo".write(
      to: root.url.appendingPathComponent("nota.txt"),
      atomically: true,
      encoding: .utf8
    )

    #expect(throws: EvieFileWriter.WriteError.fileChanged) {
      _ = try writer.perform(change, in: root)
    }
    #expect(FileManager.default.fileExists(atPath: root.url.appendingPathComponent("nota.txt").path))
  }

  @Test("an approval that sat too long is refused rather than honoured")
  func refusesExpired() throws {
    let root = try makeRoot(["nota.txt": "x"])
    defer { try? FileManager.default.removeItem(at: root.url) }
    let change = EvieFileChange(
      kind: .trash,
      rootID: root.id,
      path: "nota.txt",
      proposedAt: Date(timeIntervalSinceNow: -EvieFileChange.validity - 10)
    )

    #expect(throws: EvieFileWriter.WriteError.expired) {
      _ = try EvieFileWriter().perform(change, in: root)
    }
  }

  @Test("nothing can be moved out of the authorised folder")
  func refusesEscape() throws {
    let root = try makeRoot(["nota.txt": "x"])
    defer { try? FileManager.default.removeItem(at: root.url) }
    let writer = EvieFileWriter()

    for destination in ["../fora.txt", "../../fora.txt", "/tmp/fora.txt"] {
      #expect(throws: EvieFileWriter.WriteError.self) {
        _ = try writer.perform(
          EvieFileChange(
            kind: .move,
            rootID: root.id,
            path: "nota.txt",
            destination: destination
          ),
          in: root
        )
      }
    }
    #expect(FileManager.default.fileExists(atPath: root.url.appendingPathComponent("nota.txt").path))
  }

  @Test("nothing outside the folder can be reached to move")
  func refusesEscapingSource() throws {
    let root = try makeRoot([:])
    defer { try? FileManager.default.removeItem(at: root.url) }

    #expect(throws: EvieFileWriter.WriteError.self) {
      _ = try EvieFileWriter().perform(
        EvieFileChange(kind: .trash, rootID: root.id, path: "../../../etc/hosts"),
        in: root
      )
    }
  }

  /// Authorising a folder is not authorising the credentials inside it, and that
  /// has to hold for moving exactly as it does for reading.
  @Test("a credential cannot be moved or trashed either")
  func refusesCredentials() throws {
    let root = try makeRoot([".env": "SENHA=x"])
    defer { try? FileManager.default.removeItem(at: root.url) }

    #expect(throws: EvieFileWriter.WriteError.denied(".env")) {
      _ = try EvieFileWriter().perform(
        EvieFileChange(kind: .trash, rootID: root.id, path: ".env"),
        in: root
      )
    }
    #expect(FileManager.default.fileExists(atPath: root.url.appendingPathComponent(".env").path))
  }

  /// Creating one silently would be a change nobody approved.
  @Test("a move into a folder that does not exist is refused, not created")
  func refusesMissingParent() throws {
    let root = try makeRoot(["nota.txt": "x"])
    defer { try? FileManager.default.removeItem(at: root.url) }

    #expect(throws: EvieFileWriter.WriteError.self) {
      _ = try EvieFileWriter().perform(
        EvieFileChange(
          kind: .move,
          rootID: root.id,
          path: "nota.txt",
          destination: "inexistente/nota.txt"
        ),
        in: root
      )
    }
    #expect(!FileManager.default.fileExists(atPath: root.url.appendingPathComponent("inexistente").path))
  }

  @Test("a file that is not there is reported rather than silently succeeding")
  func refusesMissingSource() throws {
    let root = try makeRoot([:])
    defer { try? FileManager.default.removeItem(at: root.url) }

    #expect(throws: EvieFileWriter.WriteError.notFound("some.txt")) {
      _ = try EvieFileWriter().perform(
        EvieFileChange(kind: .trash, rootID: root.id, path: "some.txt"),
        in: root
      )
    }
  }

  // MARK: - Reading a proposal

  @Test("a call becomes a proposal")
  func readsAProposal() throws {
    let call = EvieToolCall(
      id: "c1",
      name: "propose_change",
      argumentsJSON: #"{"action":"rename","root_id":"r1","path":"a.txt","destination":"b.txt"}"#
    )

    guard case .success(let change) = EvieChangeTool.proposal(from: call) else {
      Issue.record("não virou proposta")
      return
    }
    #expect(change.kind == .rename)
    #expect(change.rootID == "r1")
    #expect(change.destination == "b.txt")
  }

  @Test("an action that does not exist is refused by name")
  func refusesUnknownAction() {
    let call = EvieToolCall(
      id: "c1",
      name: "propose_change",
      argumentsJSON: #"{"action":"apagar_de_vez","root_id":"r1","path":"a.txt"}"#
    )

    guard case .failure(let reason) = EvieChangeTool.proposal(from: call) else {
      Issue.record("aceitou uma ação inexistente")
      return
    }
    #expect(reason.message.contains("trash"))
  }

  @Test("renaming without a destination is refused")
  func refusesMissingDestination() {
    let call = EvieToolCall(
      id: "c1",
      name: "propose_change",
      argumentsJSON: #"{"action":"rename","root_id":"r1","path":"a.txt"}"#
    )

    guard case .failure(let reason) = EvieChangeTool.proposal(from: call) else {
      Issue.record("aceitou rename sem destino")
      return
    }
    #expect(reason == .missingDestination)
  }

  /// The boundary the whole design rests on, asserted directly.
  @Test("the tool that proposes cannot be mistaken for one that acts")
  func theToolOnlyProposes() {
    #expect(EvieChangeTool.definition.name == "propose_change")
    #expect(EvieChangeTool.definition.name.hasPrefix("propose"))
    #expect(EvieChangeTool.definition.summary.contains("NÃO faz nada"))
  }

  @Test("a card says exactly what the button will do")
  func describesItself() {
    let trash = EvieFileChange(kind: .trash, rootID: "r", path: "docs/velho.pdf")
    let rename = EvieFileChange(
      kind: .rename,
      rootID: "r",
      path: "a.txt",
      destination: "b.txt"
    )

    #expect(trash.describe(rootName: "Downloads").contains("Lixo"))
    #expect(trash.detail(rootName: "Downloads").contains("recuperar"))
    #expect(rename.describe(rootName: "Downloads").contains("b.txt"))
  }
}

extension EvieFileWriterTests {
  fileprivate func makeRoot(_ files: [String: String]) throws -> EvieFileRoot {
    let directory = FileManager.default.temporaryDirectory
      .appendingPathComponent("evie-writer-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)

    for (path, contents) in files {
      let url = directory.appendingPathComponent(path)
      try FileManager.default.createDirectory(
        at: url.deletingLastPathComponent(),
        withIntermediateDirectories: true
      )
      try contents.write(to: url, atomically: true, encoding: .utf8)
    }
    return EvieFileRoot(displayName: "Teste", path: directory.path)
  }
}
