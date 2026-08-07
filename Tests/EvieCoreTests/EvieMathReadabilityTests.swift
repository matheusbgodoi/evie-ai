import Foundation
import Testing

@testable import EvieCore

/// Nothing with LaTeX in it may reach the screen or the clipboard.
///
/// The examples are taken from a real search of this user's own notes, where
/// every one of them appeared with its dollars showing.
@Suite("Evie maths readability")
struct EvieMathReadabilityTests {
  private func rendered(_ source: String) -> String {
    EvieRichText(source).plainText
  }

  @Test("the maths people actually write loses its dollars")
  func convertsOrdinaryMaths() {
    for source in [
      "$y=f(x)$ — curva",
      "$f_x$ e $f_y$ — uma direção de cada vez",
      "$f''$ — concavidade",
      "$+$ é Laplace, $-$ é onda",
      "256 níveis (pois $2^8 = 256$)",
      "Ao derivar em $y$, tudo que só depende de $x$ vira zero",
      "$z=f(x,y)$ — superfície",
    ] {
      let out = rendered(source)
      #expect(!out.contains("$"), "sobrou cifrão em: \(out)")
    }
  }

  /// The case the old rule existed to protect, and the reason it cannot simply
  /// be dropped.
  @Test("Brazilian currency is left alone")
  func keepsCurrency() {
    #expect(rendered("custa R$ 1.234,56").contains("R$ 1.234,56"))
    // Two amounts in one sentence: naive pairing would swallow everything
    // between them.
    let both = rendered("custa R$ 10 e vende por R$ 20")
    #expect(both.contains("R$ 10"))
    #expect(both.contains("R$ 20"))
    #expect(both.contains("e vende por"))
  }

  @Test("backslash commands still become symbols")
  func convertsCommands() {
    let out = rendered("de $\\mathbb{R}$ para $\\mathbb{R}^2$, com $\\alpha$")

    #expect(!out.contains("\\"))
    #expect(!out.contains("$"))
  }

  /// A lone dollar with no partner is not an opening delimiter.
  @Test("an unpaired dollar is not maths")
  func leavesUnpairedDollars() {
    #expect(rendered("o preço é $ e não sei").contains("$"))
  }

  /// Two dollars far apart in prose were never a pair.
  @Test("dollars a paragraph apart are not a pair")
  func refusesLongSpans() {
    let long = "$" + String(repeating: "palavra ", count: 40) + "$"

    #expect(rendered(long).contains("$"))
  }

  /// What is copied must be what is read.
  @Test("the clipboard matches the screen")
  func clipboardMatchesScreen() {
    let text = EvieRichText("A curva $y=f(x)$ tem $f'(x)$ como derivada.")

    #expect(!text.plainText.contains("$"))
    #expect(!text.plainText.contains("\\"))
  }
}

/// A vault is full of writing meant for an editor, not for a reader. What a
/// search shows has to be the note, not its source.
@Suite("Evie note readability")
struct EvieNoteReadabilityTests {
  @Test("a wikilink shows what it says, not its brackets")
  func unwrapsWikilinks() {
    let out = EvieVaultSearchReport.readable(
      "Ver [[Cálculo Diferencial e Integral II]] e [[EU|meu perfil]]."
    )

    #expect(out == "Ver Cálculo Diferencial e Integral II e meu perfil.")
  }

  @Test("front matter is not part of the note")
  func dropsFrontMatter() {
    let out = EvieVaultSearchReport.readable(
      """
      ---
      tipo: resumo
      tags: [puc-sp, calculo-2]
      ---
      O arco: de R para R2.
      """
    )

    #expect(out == "O arco: de R para R2.")
    #expect(!out.contains("tags"))
  }

  /// A rule in the middle of a note is writing, not metadata.
  @Test("a horizontal rule mid-note survives")
  func keepsMidNoteRules() {
    let out = EvieVaultSearchReport.readable("Primeira parte.\n\n---\n\nSegunda parte.")

    #expect(out.contains("Primeira parte"))
    #expect(out.contains("Segunda parte"))
  }

  @Test("a table separator carries nothing once the table is gone")
  func dropsTableRules() {
    let out = EvieVaultSearchReport.readable("| Cálculo I | Cálculo II |\n|---|---|\n| a | b |")

    #expect(!out.contains("|---|"))
    #expect(out.contains("Cálculo I"))
  }

  @Test("an ordinary note is left exactly as written")
  func leavesProseAlone() {
    let prose = "Caminhos só refutam limite; nunca confirmam."

    #expect(EvieVaultSearchReport.readable(prose) == prose)
  }
}
