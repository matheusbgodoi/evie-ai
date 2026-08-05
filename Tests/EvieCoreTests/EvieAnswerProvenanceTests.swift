import Foundation
import Testing

@testable import EvieCore

@Suite("Evie answer provenance")
struct EvieAnswerProvenanceTests {
  /// The case that matters most, and the one a model is least likely to admit to
  /// on its own: nothing was consulted, so the answer is memory and may be wrong.
  @Test("an answer from memory alone says so, and says it may be wrong")
  func memoryAloneIsWarned() {
    let provenance = EvieAnswerProvenance.from(toolCalls: [])

    #expect(provenance.usedOnlyItsOwnKnowledge)
    #expect(provenance.note.contains("só o que eu já sabia"))
    #expect(provenance.note.contains("erro"))
  }

  @Test("reading the user's files is reported as such")
  func localKnowledge() {
    let provenance = EvieAnswerProvenance.from(
      toolCalls: ["list_roots", "search_content", "read_file"]
    )

    #expect(provenance.usedLocalKnowledge)
    #expect(!provenance.usedWeb)
    #expect(provenance.note.contains("anotações"))
    #expect(!provenance.note.contains("erro"))
  }

  /// Finding out which folders exist is not the same as having looked in one. If
  /// it counted, every turn would claim to have used his notes.
  @Test("listing the folders alone is not using them")
  func listingRootsIsNotConsulting() {
    let provenance = EvieAnswerProvenance.from(toolCalls: ["list_roots"])

    #expect(!provenance.usedLocalKnowledge)
    #expect(provenance.usedOnlyItsOwnKnowledge)
  }

  @Test("the web is reported with the sites actually opened")
  func webWithCitations() {
    let provenance = EvieAnswerProvenance.from(
      toolCalls: ["search_web", "read_page"],
      readAddresses: ["https://www.exemplo.com/artigo", "https://outro.org/p"]
    )

    #expect(provenance.usedWeb)
    #expect(provenance.note.contains("exemplo.com"))
    #expect(provenance.note.contains("outro.org"))
    // The `www.` is noise in a one-line label.
    #expect(!provenance.note.contains("www."))
  }

  @Test("searching without opening anything cites nothing")
  func searchWithoutReading() {
    let provenance = EvieAnswerProvenance.from(toolCalls: ["search_web"])

    #expect(provenance.usedWeb)
    #expect(provenance.citedPages.isEmpty)
    #expect(provenance.note == "Usei a web")
  }

  @Test("both sources are reported together")
  func bothSources() {
    let provenance = EvieAnswerProvenance.from(
      toolCalls: ["search_content", "search_web", "read_page"],
      readAddresses: ["https://exemplo.com"]
    )

    #expect(provenance.note.contains("anotações"))
    #expect(provenance.note.contains("web"))
    #expect(provenance.note.contains("exemplo.com"))
  }

  @Test("the same site opened twice is named once")
  func deduplicatesHosts() {
    let provenance = EvieAnswerProvenance.from(
      toolCalls: ["read_page"],
      readAddresses: [
        "https://exemplo.com/a", "https://exemplo.com/b", "https://exemplo.com/c",
      ]
    )

    #expect(provenance.note.components(separatedBy: "exemplo.com").count == 2)
  }

  /// The label is one line under an answer, not a bibliography.
  @Test("a long list of sites is cut rather than run on")
  func boundsCitations() {
    let provenance = EvieAnswerProvenance.from(
      toolCalls: ["read_page"],
      readAddresses: (0..<12).map { "https://site\($0).com" }
    )

    #expect(provenance.note.count < 120)
  }

  @Test("proposing a memory is not consulting anything")
  func memoryToolIsNotASource() {
    let provenance = EvieAnswerProvenance.from(toolCalls: ["propose_memory"])

    #expect(provenance.usedOnlyItsOwnKnowledge)
  }
}
