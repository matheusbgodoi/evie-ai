import AppKit
import Foundation
import PDFKit
import Testing

@testable import EvieCore

@Suite("Evie document proposals")
struct EvieDocumentProposalTests {
  @Test("a well-formed call becomes a proposal and saves nothing")
  func parses() throws {
    let call = EvieToolCall(
      id: "c",
      name: "propose_document",
      argumentsJSON: #"""
        {"title":"Resumo da aula","format":"docx","destination":"mesa",
         "subfolder":"Faculdade/Ética","content":"# Resumo\n\nKant e o dever."}
        """#
    )

    let proposal = try EvieDocumentTool.proposal(from: call).get()

    #expect(proposal.format == .docx)
    #expect(proposal.destination == "mesa")
    #expect(proposal.subfolder == "Faculdade/Ética")
    #expect(proposal.fileName() == "Resumo da aula.docx")
    #expect(proposal.place(rootName: "Mesa") == "Mesa › Faculdade › Ética")
    #expect(proposal.preview.contains("Kant e o dever."))
    #expect(!proposal.preview.contains("#"))
  }

  @Test("the format is read the ways a model writes it, or from the title")
  func formats() throws {
    #expect(EvieDocumentFormat(spoken: ".DOCX") == .docx)
    #expect(EvieDocumentFormat(spoken: "Word") == .docx)
    #expect(EvieDocumentFormat(spoken: "markdown") == .markdown)
    #expect(EvieDocumentFormat(spoken: "texto") == .text)
    #expect(EvieDocumentFormat(spoken: "pptx") == nil)

    let untyped = EvieToolCall(
      id: "c", name: "propose_document",
      argumentsJSON: #"{"title":"resumo.docx","destination":"mesa","content":"oi"}"#)
    let proposal = try EvieDocumentTool.proposal(from: untyped).get()
    #expect(proposal.format == .docx)
    #expect(proposal.fileName() == "resumo.docx")
  }

  @Test("a missing piece or a way out of the folder is refused with a reason")
  func rejections() {
    func reason(_ json: String) -> EvieDocumentTool.RejectionReason? {
      let call = EvieToolCall(id: "c", name: "propose_document", argumentsJSON: json)
      if case .failure(let reason) = EvieDocumentTool.proposal(from: call) {
        return reason
      }
      return nil
    }
    #expect(reason(#"{"format":"md","destination":"mesa","content":"x"}"#) == .missingTitle)
    #expect(
      reason(#"{"title":"a","format":"odp","destination":"mesa","content":"x"}"#)
        == .unknownFormat("odp"))
    #expect(reason(#"{"title":"a","format":"md","content":"x"}"#) == .missingDestination)
    #expect(reason(#"{"title":"a","format":"md","destination":"mesa"}"#) == .missingContent)
    #expect(
      reason(#"{"title":"a","format":"md","destination":"mesa","subfolder":"../..","content":"x"}"#)
        == .invalidSubfolder("../.."))
    #expect(
      reason(#"{"title":"a","format":"md","destination":"mesa","subfolder":".ssh","content":"x"}"#)
        == .invalidSubfolder(".ssh"))
  }

  /// APFS treats these as the denied folders themselves.
  @Test("a subfolder that is a denied name in another case or spelling is refused")
  func foldedSubfolders() {
    for subfolder in [".SSH/x", ".Env.local", "LIBRARY/Mail", "Li\u{0300}brary"] {
      #expect(
        EvieDocumentTool.normalisedSubfolder(subfolder) == .failure(.invalidSubfolder(subfolder)),
        "\(subfolder) deveria ser recusada"
      )
    }
  }

  @Test("a document is never written into a differently cased denied folder")
  func creatorRefusesFoldedNames() throws {
    let root = EvieFileRoot(
      id: "r1", displayName: "Mesa", path: try FileFixtures.directory("folded").path)
    try FileManager.default.createDirectory(
      at: root.url.appendingPathComponent(".ssh"), withIntermediateDirectories: true)
    let proposal = EvieDocumentProposal(
      title: "authorized_keys", format: .text, destination: "r1", subfolder: ".SSH",
      markdown: "x")

    #expect(throws: EvieDocumentCreator.CreateError.self) {
      try EvieDocumentCreator().create(proposal, in: root)
    }
    #expect(
      try FileManager.default.contentsOfDirectory(atPath: root.url.appendingPathComponent(".ssh").path)
        .isEmpty)
  }

  @Test("a title becomes a safe file name, never empty and never hidden")
  func fileNames() {
    func name(_ title: String, _ format: EvieDocumentFormat = .pdf) -> String {
      EvieDocumentProposal(title: title, format: format, destination: "mesa", markdown: "x")
        .fileName()
    }
    #expect(name("Relatório: 1/2") == "Relatório 1 2.pdf")
    #expect(name("..env") == "env.pdf")
    #expect(name("   ") == "Documento.pdf")
    #expect(name("ata.PDF") == "ata.pdf")
    #expect(
      EvieDocumentProposal(title: "ata", format: .markdown, destination: "m", markdown: "x")
        .fileName(attempt: 3) == "ata (3).md")
  }

  @Test("a card is good for fifteen minutes")
  func expiry() {
    let made = Date(timeIntervalSince1970: 1_000)
    let proposal = EvieDocumentProposal(
      title: "a", format: .markdown, destination: "mesa", markdown: "x", proposedAt: made)
    #expect(!proposal.hasExpired(at: made.addingTimeInterval(14 * 60)))
    #expect(proposal.hasExpired(at: made.addingTimeInterval(16 * 60)))
  }
}

@Suite("Evie document intent")
struct EvieDocumentIntentTests {
  @Test("the person's own request to save is recognised")
  func recognises() {
    #expect(EvieDocumentIntent.isPresent(in: "salva isso na minha mesa como resumo.docx"))
    #expect(EvieDocumentIntent.isPresent(in: "Salve um resumo em PDF"))
    #expect(EvieDocumentIntent.isPresent(in: "cria um arquivo com a lista"))
    #expect(EvieDocumentIntent.isPresent(in: "grava na mesa"))
    #expect(EvieDocumentIntent.isPresent(in: "escreve um relatório e salva em Documentos"))
  }

  @Test("questions, adjectives and refusals are not a request to save")
  func ignores() {
    #expect(!EvieDocumentIntent.isPresent(in: "o que tem na minha mesa?"))
    #expect(!EvieDocumentIntent.isPresent(in: "tem um erro grave no texto"))
    #expect(!EvieDocumentIntent.isPresent(in: "me resume o PDF, não salva nada"))
    #expect(!EvieDocumentIntent.isPresent(in: "o Salvador é bonito"))
    #expect(!EvieDocumentIntent.isPresent(in: ""))
  }
}

@Suite("Evie document rendering and creation")
struct EvieDocumentCreatorTests {
  static let markdown = """
    # Relatório de Sociologia

    Um parágrafo com **negrito** e *itálico*, e acentuação: ação, ênfase.

    - primeiro ponto
    - segundo ponto

    1. passo um
    """

  func proposal(
    _ format: EvieDocumentFormat,
    title: String = "Relatório",
    subfolder: String = "",
    markdown: String = Self.markdown
  ) -> EvieDocumentProposal {
    EvieDocumentProposal(
      title: title, format: format, destination: "r1", subfolder: subfolder, markdown: markdown)
  }

  func root() throws -> EvieFileRoot {
    EvieFileRoot(id: "r1", displayName: "Mesa", path: try FileFixtures.directory("create").path)
  }

  /// The verification the owner asked for: the file is a real Office Open XML
  /// package, and reading it back with the system's importer gives the text.
  @Test("a .docx is a real Word package that reads back with its text and bold")
  func docxRoundTrip() throws {
    let root = try root()
    let receipt = try EvieDocumentCreator().create(proposal(.docx), in: root)

    let data = try Data(contentsOf: receipt.url)
    // A zip, with the parts Word looks for by name.
    #expect(data.prefix(2) == Data("PK".utf8))
    let latin = String(decoding: data, as: UTF8.self)
    #expect(latin.contains("word/document.xml"))
    #expect(latin.contains("[Content_Types].xml"))

    let read = try NSAttributedString(
      url: receipt.url,
      options: [.documentType: NSAttributedString.DocumentType.officeOpenXML],
      documentAttributes: nil
    )
    #expect(read.string.contains("Relatório de Sociologia"))
    #expect(read.string.contains("acentuação: ação, ênfase."))
    #expect(read.string.contains("segundo ponto"))
    #expect(!read.string.contains("**"))

    let boldRange = (read.string as NSString).range(of: "negrito")
    let font = read.attribute(.font, at: boldRange.location, effectiveRange: nil) as? NSFont
    #expect(font?.fontDescriptor.symbolicTraits.contains(.bold) == true)
  }

  @Test("an .rtf reads back with its text")
  func rtfRoundTrip() throws {
    let receipt = try EvieDocumentCreator().create(proposal(.rtf), in: try root())
    let read = try NSAttributedString(
      url: receipt.url,
      options: [.documentType: NSAttributedString.DocumentType.rtf],
      documentAttributes: nil
    )
    #expect(read.string.contains("primeiro ponto"))
    #expect(String(decoding: try Data(contentsOf: receipt.url), as: UTF8.self).hasPrefix("{\\rtf"))
  }

  @Test("a .pdf has a text layer with the words, and long text runs onto more pages")
  func pdf() throws {
    let receipt = try EvieDocumentCreator().create(proposal(.pdf), in: try root())
    let document = try #require(PDFDocument(url: receipt.url))
    #expect(document.string?.contains("Relatório de Sociologia") == true)
    #expect(document.string?.contains("ênfase") == true)
    #expect(document.documentAttributes?[PDFDocumentAttribute.titleAttribute] as? String == "Relatório")

    let long = (1...400).map { "Linha \($0) de um trabalho comprido." }.joined(separator: "\n\n")
    let longReceipt = try EvieDocumentCreator().create(
      proposal(.pdf, title: "Longo", markdown: long), in: try root())
    let longDocument = try #require(PDFDocument(url: longReceipt.url))
    #expect(longDocument.pageCount > 1)
    #expect(longDocument.string?.contains("Linha 400 de um trabalho comprido.") == true)
  }

  @Test(".md keeps the Markdown and .txt drops it")
  func plainFormats() throws {
    let root = try root()
    let markdown = try EvieDocumentCreator().create(proposal(.markdown), in: root)
    let text = try EvieDocumentCreator().create(proposal(.text), in: root)

    #expect(try String(contentsOf: markdown.url, encoding: .utf8) == Self.markdown + "\n")
    let plain = try String(contentsOf: text.url, encoding: .utf8)
    #expect(plain.contains("• primeiro ponto"))
    #expect(!plain.contains("**"))
  }

  @Test("a name already taken becomes nome (2), and the original is untouched")
  func neverOverwrites() throws {
    let root = try root()
    let existing = root.url.appendingPathComponent("Relatório.md")
    try FileFixtures.write("do Matheus, não mexer", to: existing)

    let second = try EvieDocumentCreator().create(proposal(.markdown), in: root)
    let third = try EvieDocumentCreator().create(proposal(.markdown), in: root)

    #expect(second.fileName == "Relatório (2).md")
    #expect(third.fileName == "Relatório (3).md")
    #expect(try String(contentsOf: existing, encoding: .utf8) == "do Matheus, não mexer")
  }

  @Test("a missing subfolder is created inside the folder")
  func createsSubfolder() throws {
    let root = try root()
    let receipt = try EvieDocumentCreator().create(
      proposal(.markdown, subfolder: "Faculdade/Ética"), in: root)

    #expect(receipt.relativePath == "Faculdade/Ética/Relatório.md")
    #expect(FileManager.default.fileExists(atPath: receipt.url.path))
  }

  @Test("a symlinked subfolder cannot carry the file out of the folder")
  func symlinkedSubfolder() throws {
    let root = try root()
    let outside = try FileFixtures.directory("outside")
    try FileManager.default.createSymbolicLink(
      at: root.url.appendingPathComponent("atalho"),
      withDestinationURL: outside
    )

    #expect(throws: EvieDocumentCreator.CreateError.escapesRoot("atalho")) {
      try EvieDocumentCreator().create(proposal(.markdown, subfolder: "atalho"), in: root)
    }
    #expect(try FileManager.default.contentsOfDirectory(atPath: outside.path).isEmpty)
  }

  @Test("an existing symlink with the file's name is a taken name, never followed")
  func symlinkedName() throws {
    let root = try root()
    let outside = try FileFixtures.directory("outside-file")
    let target = outside.appendingPathComponent("alvo.md")
    try FileFixtures.write("intocado", to: target)
    try FileManager.default.createSymbolicLink(
      at: root.url.appendingPathComponent("Relatório.md"),
      withDestinationURL: target
    )

    let receipt = try EvieDocumentCreator().create(proposal(.markdown), in: root)

    #expect(receipt.fileName == "Relatório (2).md")
    #expect(try String(contentsOf: target, encoding: .utf8) == "intocado")
  }

  @Test("an expired card writes nothing")
  func expired() throws {
    let root = try root()
    var old = proposal(.markdown)
    old.proposedAt = Date().addingTimeInterval(-EvieDocumentProposal.validity - 1)

    #expect(throws: EvieDocumentCreator.CreateError.expired) {
      try EvieDocumentCreator().create(old, in: root)
    }
    #expect(try FileManager.default.contentsOfDirectory(atPath: root.path).isEmpty)
  }
}
