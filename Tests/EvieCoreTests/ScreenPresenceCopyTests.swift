import Foundation
import Testing

@testable import EvieCore

@Suite("Screen presence copy")
struct ScreenPresenceCopyTests {
  @Test("the click line quotes the element Evie is about to press")
  func clickNamesTheElement() {
    #expect(ScreenPresenceCopy.acting(label: "Enviar") == "Evie vai clicar em ‘Enviar’")
  }

  @Test("a click with no usable label says only that she will click")
  func clickWithoutLabel() {
    #expect(ScreenPresenceCopy.acting(label: nil) == "Evie vai clicar")
    #expect(ScreenPresenceCopy.acting(label: "  \n\t ") == "Evie vai clicar")
  }

  @Test("a label's line breaks and runs of spaces collapse to single spaces")
  func labelWhitespaceCollapses() {
    #expect(
      ScreenPresenceCopy.acting(label: "  Salvar\n  como…  ") == "Evie vai clicar em ‘Salvar como…’")
  }

  @Test("a long label is cut at 32 characters with an ellipsis, so the pill keeps its size")
  func longLabelIsTruncated() {
    let label = String(repeating: "a", count: 40)

    let line = ScreenPresenceCopy.acting(label: label)

    #expect(line == "Evie vai clicar em ‘\(String(repeating: "a", count: 31))…’")
  }

  @Test("truncation never splits a composed character")
  func truncationKeepsGraphemes() {
    // Each flag is one character made of two scalars; 40 of them overflow.
    let label = String(repeating: "🇧🇷", count: 40)

    let line = ScreenPresenceCopy.acting(label: label)

    #expect(line.contains(String(repeating: "🇧🇷", count: 31) + "…’"))
    #expect(line.count == "Evie vai clicar em ‘’".count + 32)
  }

  @Test("observing names the step, and the budget when it is known")
  func observingStep() {
    #expect(ScreenPresenceCopy.observing(step: 3, of: nil) == "Evie está observando · passo 3")
    #expect(ScreenPresenceCopy.observing(step: 3, of: 25) == "Evie está observando · passo 3/25")
  }

  @Test("typing names the app, or falls back when it has no name")
  func typingNamesTheApp() {
    #expect(ScreenPresenceCopy.typing(app: "Notas") == "Evie está digitando em Notas")
    #expect(ScreenPresenceCopy.typing(app: " ") == "Evie está digitando")
  }
}
