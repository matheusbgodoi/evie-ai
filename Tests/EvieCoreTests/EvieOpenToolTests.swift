import Foundation
import Testing

@testable import EvieCore

/// An opener that records instead of launching anything: no test opens a
/// window, an app or the Finder.
actor RecordingOpener: EvieFileOpening {
  private(set) var opened: [URL] = []
  private(set) var revealed: [URL] = []

  func open(_ url: URL) async -> Bool {
    opened.append(url)
    return true
  }

  func reveal(_ url: URL) async -> Bool {
    revealed.append(url)
    return true
  }
}

@Suite("Evie open and reveal")
struct EvieOpenToolTests {
  func fixture() throws -> (EvieFileRoot, EvieFileToolbox) {
    let home = try FileFixtures.home()
    let desktop = home.appendingPathComponent("Desktop")
    try FileFixtures.write(FileFixtures.pdf(text: "oi"), to: desktop.appendingPathComponent("resumo.pdf"))
    try FileFixtures.write("echo oi", to: desktop.appendingPathComponent("instalar.command"))
    try FileFixtures.write("#!/bin/sh", to: desktop.appendingPathComponent("rodar"))
    try FileManager.default.setAttributes(
      [.posixPermissions: 0o755], ofItemAtPath: desktop.appendingPathComponent("rodar").path)
    try FileFixtures.write("bin", to: desktop.appendingPathComponent("Jogo.app/Contents/MacOS/Jogo"))
    let root = EvieFileRoot(id: "d1", displayName: "Mesa", path: desktop.path)
    return (root, EvieFileToolbox(home: home))
  }

  func call(_ tool: EvieOpenTool, _ path: String, root: String = "d1") -> EvieToolCall {
    EvieToolCall(
      id: "c", name: tool.rawValue, argumentsJSON: #"{"root_id":"\#(root)","path":"\#(path)"}"#)
  }

  @Test("opens a document inside the folder and reports it for the transcript")
  func opensADocument() async throws {
    let (root, toolbox) = try fixture()
    let opener = RecordingOpener()

    let (result, action) = await EvieOpenTool.run(
      call(.open, "resumo.pdf"), roots: [root], toolbox: toolbox, opener: opener)

    #expect(!result.isFailure)
    #expect(await opener.opened.map(\.lastPathComponent) == ["resumo.pdf"])
    #expect(action == EvieFileAction(kind: .opened, path: "resumo.pdf", placeName: "Mesa"))
    #expect(action?.summary == "Abri resumo.pdf")
  }

  @Test(
    "refuses apps, scripts, installers and executables",
    arguments: ["instalar.command", "rodar", "Jogo.app"]
  )
  func refusesWhatRuns(_ name: String) async throws {
    let (root, toolbox) = try fixture()
    let opener = RecordingOpener()

    let (result, action) = await EvieOpenTool.run(
      call(.open, name), roots: [root], toolbox: toolbox, opener: opener)

    #expect(result.isFailure)
    #expect(action == nil)
    #expect(await opener.opened.isEmpty)
  }

  @Test("every listed kind that runs or installs is refused by name")
  func refusedExtensions() {
    let plain = EvieItemStatus(isDirectory: false, byteSize: 1, isExecutable: false)
    for name in [
      "a.app", "a.command", "a.sh", "a.pkg", "a.dmg", "a.terminal", "a.mobileconfig",
      "a.webloc", "a.SH", "a.scpt",
    ] {
      #expect(EvieOpenTool.refusal(forName: name, status: plain) != nil, "\(name)")
    }
    #expect(EvieOpenTool.refusal(forName: "resumo.pdf", status: plain) == nil)
    // A PDF copied from a USB stick with every bit set is still a PDF.
    let flagged = EvieItemStatus(isDirectory: false, byteSize: 1, isExecutable: true)
    #expect(EvieOpenTool.refusal(forName: "resumo.pdf", status: flagged) == nil)
    #expect(EvieOpenTool.refusal(forName: "binario", status: flagged) != nil)
  }

  @Test("nothing outside the folder is opened, by .. or by symlink")
  func refusesOutside() async throws {
    let (root, toolbox) = try fixture()
    let outside = try FileFixtures.directory("open-outside")
    try FileFixtures.write("x", to: outside.appendingPathComponent("fora.pdf"))
    try FileManager.default.createSymbolicLink(
      at: root.url.appendingPathComponent("atalho.pdf"),
      withDestinationURL: outside.appendingPathComponent("fora.pdf")
    )
    let opener = RecordingOpener()

    for path in ["../Documents", "atalho.pdf", "/etc/hosts"] {
      let (result, _) = await EvieOpenTool.run(
        call(.open, path), roots: [root], toolbox: toolbox, opener: opener)
      #expect(result.isFailure, "\(path)")
    }
    let (unknown, _) = await EvieOpenTool.run(
      call(.open, "resumo.pdf", root: "zz"), roots: [root], toolbox: toolbox, opener: opener)
    #expect(unknown.isFailure)
    #expect(await opener.opened.isEmpty)
  }

  @Test("an alias not granted yet opens nothing and names the card")
  func notGranted() async throws {
    let (root, toolbox) = try fixture()
    let opener = RecordingOpener()

    let (result, _) = await EvieOpenTool.run(
      call(.open, "x.pdf", root: "downloads"), roots: [root], toolbox: toolbox, opener: opener)

    #expect(result.isFailure)
    #expect(result.content.contains("Permitir que a Evie leia seus Downloads"))
    #expect(await opener.opened.isEmpty)
  }

  @Test("reveals in the Finder, an app included, since revealing runs nothing")
  func reveals() async throws {
    let (root, toolbox) = try fixture()
    let opener = RecordingOpener()

    let (result, action) = await EvieOpenTool.run(
      call(.reveal, "Jogo.app"), roots: [root], toolbox: toolbox, opener: opener)

    #expect(!result.isFailure)
    #expect(await opener.revealed.map(\.lastPathComponent) == ["Jogo.app"])
    #expect(action?.summary == "Mostrei Jogo.app no Finder")
  }
}
