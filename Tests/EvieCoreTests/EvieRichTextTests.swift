import Foundation
import Testing

@testable import EvieCore

@Suite("Evie rich text")
struct EvieRichTextTests {
  @Test("a heading becomes a heading block without its hashes")
  func parsesHeadings() {
    let text = EvieRichText("### **Resumo**\n\nUm parágrafo.")

    #expect(text.blocks.count == 2)
    #expect(text.blocks.first == .heading(level: 3, text: "Resumo"))
    #expect(text.blocks.last == .paragraph("Um parágrafo."))
  }

  @Test("a bold-only line is treated as the heading it is trying to be")
  func promotesBoldOnlyLines() {
    // Models write "**1. Segmentação:**" on its own line meaning a heading.
    let text = EvieRichText("**1. Segmentação:**\nÉ o processo de dividir.")

    #expect(text.blocks.first == .heading(level: 4, text: "1. Segmentação:"))
    #expect(text.blocks.last == .paragraph("É o processo de dividir."))
  }

  @Test("bullets keep their nesting and lose their markers")
  func parsesBullets() {
    let text = EvieRichText(
      """
      *   **Técnicas citadas:**
          *   **Limiarização:** Agrupamento por intensidade.
          -   Detecção de bordas.
      """
    )

    #expect(text.blocks.count == 3)
    #expect(text.blocks[0] == .bullet(level: 0, text: "**Técnicas citadas:**"))
    #expect(
      text.blocks[1] == .bullet(level: 1, text: "**Limiarização:** Agrupamento por intensidade."))
    #expect(text.blocks[2] == .bullet(level: 1, text: "Detecção de bordas."))
  }

  @Test("numbered lists keep their numbers")
  func parsesNumberedLists() {
    let text = EvieRichText("1. Primeiro passo\n2. Segundo passo")

    #expect(text.blocks[0] == .numbered(level: 0, number: 1, text: "Primeiro passo"))
    #expect(text.blocks[1] == .numbered(level: 0, number: 2, text: "Segundo passo"))
  }

  @Test("a horizontal rule is a rule, not three dashes of text")
  func parsesRules() {
    let text = EvieRichText("Antes\n\n---\n\nDepois")

    #expect(text.blocks.contains(.rule))
    #expect(!text.plainText.contains("---"))
  }

  @Test("fenced code survives untouched")
  func preservesCode() {
    let text = EvieRichText(
      """
      Exemplo:

      ```swift
      let x = **não é negrito**
      ```
      """
    )

    #expect(text.blocks.last == .code(language: "swift", text: "let x = **não é negrito**"))
    // Inside code, markers are content and must not be stripped.
    #expect(text.plainText.contains("**não é negrito**"))
  }

  @Test("consecutive lines of a paragraph stay together")
  func joinsWrappedLines() {
    let text = EvieRichText("Uma frase longa\nque continua na linha seguinte.")

    #expect(text.blocks.count == 1)
    #expect(text.blocks.first == .paragraph("Uma frase longa que continua na linha seguinte."))
  }

  // MARK: - LaTeX

  @Test("inline LaTeX becomes the character it was standing in for")
  func convertsLatex() {
    let text = EvieRichText("Isolar $\\rightarrow$ Descrever $\\rightarrow$ Analisar.")

    #expect(text.plainText == "Isolar → Descrever → Analisar.")
    #expect(!text.plainText.contains("$"))
    #expect(!text.plainText.contains("\\"))
  }

  @Test("the other LaTeX delimiters are handled too")
  func convertsOtherDelimiters() {
    #expect(EvieRichText("a \\(\\times\\) b").plainText == "a × b")
    #expect(EvieRichText("x \\[\\leq\\] y").plainText == "x ≤ y")
  }

  @Test("an unknown LaTeX command loses its plumbing but keeps its word")
  func degradesUnknownLatex() {
    let text = EvieRichText("valor $\\sigma_{total}$ final")

    #expect(!text.plainText.contains("$"))
    #expect(!text.plainText.contains("\\"))
    #expect(text.plainText.contains("final"))
  }

  @Test("a lone dollar sign is money, not mathematics")
  func leavesCurrencyAlone() {
    let text = EvieRichText("O total é R$ 1.234,56 hoje.")

    #expect(text.plainText == "O total é R$ 1.234,56 hoje.")
  }

  // MARK: - Plain text for copying

  @Test("copied text carries no markdown syntax at all")
  func plainTextIsClean() {
    let text = EvieRichText(
      """
      ### **Resumo**

      O texto aborda a **Segmentação** e a *Descrição*.

      *   **Técnicas:** limiarização e `watershed`.
      """
    )

    let plain = text.plainText
    #expect(!plain.contains("#"))
    #expect(!plain.contains("**"))
    #expect(!plain.contains("`"))
    #expect(plain.contains("Resumo"))
    #expect(plain.contains("Segmentação"))
    #expect(plain.contains("Descrição"))
    #expect(plain.contains("• Técnicas: limiarização e watershed."))
  }

  @Test("nested bullets are indented rather than flattened when copied")
  func plainTextIndentsNesting() {
    let text = EvieRichText("* Um\n    * Dois")

    #expect(text.plainText == "• Um\n    • Dois")
  }

  @Test("an empty answer produces nothing rather than an empty bullet")
  func handlesEmptyInput() {
    #expect(EvieRichText("").blocks.isEmpty)
    #expect(EvieRichText("   \n\n  ").plainText.isEmpty)
  }

  @Test("inline emphasis is kept in the blocks so it can be rendered")
  func keepsInlineMarkersForRendering() {
    let text = EvieRichText("O **negrito** continua marcado.")

    #expect(text.blocks.first == .paragraph("O **negrito** continua marcado."))
  }

  @Test("a stray heading marker mid-sentence is left alone")
  func ignoresMidSentenceHashes() {
    let text = EvieRichText("Use a tag #importante no final.")

    #expect(text.blocks.first == .paragraph("Use a tag #importante no final."))
  }
}

/// The answer that prompted this work, verbatim from the screen.
@Suite("Evie rich text — the real answer")
struct EvieRichTextRegressionTests {
  private let answer = """
    Aqui está o resumo e a interpretação do texto que você enviou, Matheus.

    ### **Resumo**

    O texto aborda dois processos fundamentais no processamento de imagens, \
    especialmente na área médica: a **Segmentação** e a **Descrição de Imagens**.

    **1. Segmentação:**
    É o processo de dividir uma imagem em regiões com características similares.
    *   **Técnicas citadas:**
        *   **Limiarização:** Agrupamento por valores de intensidade.
        *   **Detecção de bordas:** Busca por variações bruscas de intensidade.

    ---

    ### **Interpretação**

    O texto estabelece uma linha de raciocínio lógico para o processamento \
    computacional de imagens: **Isolar $\\rightarrow$ Descrever $\\rightarrow$ Analisar.**
    """

  @Test("none of the syntax the user complained about survives")
  func stripsEverythingVisible() {
    let plain = EvieRichText(answer).plainText

    #expect(!plain.contains("###"))
    #expect(!plain.contains("**"))
    #expect(!plain.contains("$"))
    #expect(!plain.contains("\\rightarrow"))
    #expect(!plain.contains("---"))
    #expect(!plain.contains("*   "))
  }

  @Test("and the meaning survives intact")
  func keepsTheContent() {
    let plain = EvieRichText(answer).plainText

    #expect(plain.contains("Resumo"))
    #expect(plain.contains("Interpretação"))
    #expect(plain.contains("Segmentação"))
    #expect(plain.contains("Isolar → Descrever → Analisar."))
    #expect(plain.contains("• Técnicas citadas:"))
    #expect(plain.contains("    • Limiarização: Agrupamento por valores de intensidade."))
  }

  @Test("the structure the interface needs is there")
  func producesRenderableStructure() {
    let blocks = EvieRichText(answer).blocks

    #expect(blocks.contains(.heading(level: 3, text: "Resumo")))
    #expect(blocks.contains(.heading(level: 4, text: "1. Segmentação:")))
    #expect(blocks.contains(.rule))
    #expect(blocks.contains { if case .bullet(1, _) = $0 { return true } else { return false } })
  }
}

@Suite("Evie speech and clipboard cleanliness")
struct EvieSpokenTextTests {
  private let markdown = """
    ## O que é isso?

    É um **diagrama** de um projeto que usa o `ESP32` para controlar \
    *cinco* servomotores.

    - O ponto mais **crítico** é a alimentação
    - A ~~fonte~~ solução é uma externa

    ```swift
    let x = 1
    ```

    ---
    """

  /// Nothing anybody types to make text bold should ever be pronounced.
  @Test("markdown is never spoken")
  func speechCarriesNoMarkup() {
    let spoken = EvieRichText(markdown).spokenSentences.joined(separator: " ")

    for marker in ["##", "**", "`", "~~", "---", "- "] {
      #expect(!spoken.contains(marker), "falou \"\(marker)\"")
    }
    #expect(spoken.contains("diagrama"))
    #expect(spoken.contains("crítico"))
    // Code is not prose and reading it out loud is unbearable.
    #expect(!spoken.contains("let x"))
  }

  /// Pasting an answer anywhere should need no cleanup.
  @Test("what is copied is text, not source")
  func clipboardCarriesNoMarkup() {
    let copied = EvieRichText(markdown).plainText

    for marker in ["##", "**", "~~"] {
      #expect(!copied.contains(marker), "copiou \"\(marker)\"")
    }
    #expect(copied.contains("O que é isso?"))
    #expect(copied.contains("diagrama"))
  }
}
