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

  /// The allowlist, against the launcher types a denylist kept missing.
  @Test(
    "only documents open: Terminal files, workflows, scripts and bundles do not",
    arguments: ["ajuste.terminal", "Automação.workflow", "rotina.scpt", "Extra.bundle", "Pasta"]
  )
  func allowlistRefuses(_ name: String) async throws {
    let (root, toolbox) = try fixture()
    let item = root.url.appendingPathComponent(name)
    if name.hasSuffix(".bundle") || name == "Pasta" {
      try FileFixtures.write("x", to: item.appendingPathComponent("Contents/Info.plist"))
    } else {
      try FileFixtures.write("conteúdo", to: item)
    }
    let opener = RecordingOpener()

    let (opened, action) = await EvieOpenTool.run(
      call(.open, name), roots: [root], toolbox: toolbox, opener: opener)
    #expect(opened.isFailure, "\(name) não deveria abrir")
    #expect(action == nil)
    #expect(opened.content.contains("reveal_in_finder"))
    #expect(await opener.opened.isEmpty)

    // Revealing runs nothing, so a bundle or a folder can still be shown.
    let (revealed, _) = await EvieOpenTool.run(
      call(.reveal, name), roots: [root], toolbox: toolbox, opener: opener)
    #expect(!revealed.isFailure)
  }

  /// A browser runs the script in these, and `public.content` admitted them.
  @Test(
    "web documents are never opened, only revealed",
    arguments: ["pagina.html", "pagina.HTM", "desenho.svg", "salvo.webarchive", "feed.xml", "a.xhtml"]
  )
  func webDocumentsRefused(_ name: String) async throws {
    let plain = EvieItemStatus(isDirectory: false, byteSize: 1, isExecutable: false)
    #expect(EvieOpenTool.refusal(forName: name, status: plain) != nil, "\(name)")

    let (root, toolbox) = try fixture()
    try FileFixtures.write("<script>alert(1)</script>", to: root.url.appendingPathComponent(name))
    let opener = RecordingOpener()
    let (opened, _) = await EvieOpenTool.run(
      call(.open, name), roots: [root], toolbox: toolbox, opener: opener)
    let (revealed, _) = await EvieOpenTool.run(
      call(.reveal, name), roots: [root], toolbox: toolbox, opener: opener)

    #expect(opened.isFailure)
    #expect(!revealed.isFailure)
    #expect(await opener.opened.isEmpty)
  }

  @Test("a plain PDF, and content the system knows, open; an unknown extension does not")
  func allowlistAdmits() {
    let plain = EvieItemStatus(isDirectory: false, byteSize: 1, isExecutable: false)
    #expect(EvieOpenTool.refusal(forName: "aula.pdf", status: plain) == nil)
    #expect(EvieOpenTool.refusal(forName: "AULA.PDF", status: plain) == nil)
    #expect(EvieOpenTool.isOpenableDocument("foto.jpg"))
    #expect(!EvieOpenTool.isOpenableDocument("coisa.xyzzy"))
    #expect(!EvieOpenTool.isOpenableDocument("semextensao"))
    #expect(!EvieOpenTool.isOpenableDocument("tela.saver"))
    #expect(!EvieOpenTool.isOpenableDocument("servico.xpc"))
    #expect(!EvieOpenTool.isOpenableDocument("biblioteca.jar"))
    #expect(!EvieOpenTool.isOpenableDocument("script.sh"))
    #expect(!EvieOpenTool.isOpenableDocument("codigo.swift"))
    // Through the narrow fallback: an image type not in the explicit list.
    #expect(EvieOpenTool.isOpenableDocument("foto.jp2"))
  }

  @Test("every listed kind that runs or installs is refused by name")
  func refusedExtensions() {
    let plain = EvieItemStatus(isDirectory: false, byteSize: 1, isExecutable: false)
    for name in [
      "a.app", "a.command", "a.sh", "a.pkg", "a.dmg", "a.terminal", "a.mobileconfig",
      "a.webloc", "a.SH", "a.scpt", "a.terminal", "a.workflow", "a.action", "a.prefPane",
      "a.saver", "a.bundle", "a.plugin", "a.kext", "a.shortcut", "a.xpc", "a.jar",
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
