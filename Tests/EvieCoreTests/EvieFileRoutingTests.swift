import Foundation
import Testing

@testable import EvieCore

/// Plain requests about the Mac's files reach the tool-using loop, even with no
/// folder granted, and are not mistaken for a look at the screen or an
/// instruction to drive the Mac.
@Suite("Evie file routing")
struct EvieFileRoutingTests {
  private let pc = EvieTurnPlan(
    profile: EvieModelProfileSet.builtIn.profile(id: EvieModelProfile.pcProfileID)!,
    readiness: .ready
  )

  static let requests = [
    "salva isso na minha mesa como resumo.docx",
    "analisa a pasta Downloads",
    "o que tem na minha mesa?",
    "lê o PDF X na pasta Y e me resume",
    "escreve um relatório e salva em Documentos",
  ]

  @Test("an everyday file request routes to the tools with nothing granted", arguments: requests)
  func routesToTheLoop(_ request: String) {
    #expect(EvieFileIntent.isPresent(in: request))
    #expect(
      pc.route(
        hasRoots: false,
        searchesTheWeb: false,
        readsMailAndCalendar: false,
        asksAboutFiles: EvieFileIntent.isPresent(in: request)
      ) == .agentLoop(offersTools: true)
    )
    #expect(!EvieScreenIntent.isPresent(in: request), "não é um pedido para olhar a tela")
    #expect(
      !ComputerUseIntent.isPresent(in: request, apps: StubAppResolver()),
      "não é uma instrução para controlar o Mac"
    )
  }

  @Test("conversation that is not about files still streams directly")
  func conversationStaysDirect() {
    for question in ["oi, tudo bem?", "quanto é 15% de 3400?", "me conta uma piada"] {
      #expect(!EvieFileIntent.isPresent(in: question), "\(question)")
      #expect(
        pc.route(
          hasRoots: false, searchesTheWeb: false, readsMailAndCalendar: false,
          asksAboutFiles: EvieFileIntent.isPresent(in: question)) == .directStream
      )
    }
  }

  @Test("a picture still never rides with tools, file request or not")
  func pictureStaysToolLess() {
    #expect(
      pc.route(
        hasRoots: false, searchesTheWeb: false, readsMailAndCalendar: false,
        carriesPicture: true, asksAboutFiles: true) == .directStream
    )
  }

  @Test("a file name with an extension counts as a file request")
  func namedFiles() {
    #expect(EvieFileIntent.isPresent(in: "me resume o aula3.pptx"))
    #expect(EvieFileIntent.isPresent(in: "cadê o contrato.pdf?"))
  }

  @Test("direct saving needs the request and no picture")
  func directSaving() {
    #expect(EvieTurnPlan.savesDocumentsDirectly(true, carriesPicture: false))
    #expect(!EvieTurnPlan.savesDocumentsDirectly(true, carriesPicture: true))
    #expect(!EvieTurnPlan.savesDocumentsDirectly(false, carriesPicture: false))
  }

  @Test("the persona offers the folders a click away and the document tool")
  func persona() {
    var capabilities = EvieCapabilitySnapshot.textOnly
    capabilities.worksWithDocuments = true
    let prompt = EviePersona.evie.systemPrompt(capabilities: capabilities)

    #expect(prompt.contains("propose_document"))
    #expect(prompt.contains("nunca diga que já salvou"))
    #expect(prompt.contains("mesa, documentos"))
    #expect(!prompt.contains("abrir pastas e arquivos do Mac"))

    let plain = EviePersona.evie.systemPrompt(capabilities: .textOnly)
    #expect(!plain.contains("propose_document"))
    #expect(plain.contains("abrir pastas e arquivos do Mac"))
  }
}
