import Foundation
import Testing

@testable import EvieCore

@Suite("Evie voice design")
struct EvieVoiceDesignTests {
  @Test("reads a description written in Portuguese")
  func parsesPortuguese() {
    let design = EvieVoiceDesign.parse("voz feminina jovem, grave e enérgica")

    #expect(design.gender == "female")
    #expect(design.age == "young adult")
    #expect(design.pitch == "low pitch")
    #expect(design.style == "energetic")
  }

  @Test("accents and case do not matter")
  func foldsAccents() {
    let plain = EvieVoiceDesign.parse("FEMININA ENERGICA")
    let accented = EvieVoiceDesign.parse("feminina enérgica")

    #expect(plain == accented)
    #expect(plain.gender == "female")
  }

  @Test("English works too, since the engine's own vocabulary is English")
  func parsesEnglish() {
    let design = EvieVoiceDesign.parse("young adult female, low pitch, calm")

    #expect(design.gender == "female")
    #expect(design.pitch == "low pitch")
    #expect(design.style == "calm")
  }

  @Test("produces the instruction the engine expects")
  func buildsInstruction() {
    let design = EvieVoiceDesign.parse("homem idoso, voz grave")

    #expect(design.instruction == "male, elderly, low pitch")
  }

  @Test("a description with nothing recognisable says so rather than guessing")
  func emptyDescription() {
    let design = EvieVoiceDesign.parse("uma voz bonita")

    #expect(design.isEmpty)
    #expect(design.summary.contains("Não reconheci"))
  }

  /// The engine silently drops what it does not understand. Saying which words
  /// were dropped is the difference between "the voice came out generic" and
  /// knowing why.
  @Test("reports the words it could not use")
  func reportsIgnoredWords() {
    let ignored = EvieVoiceDesign.ignoredWords(in: "feminina, confiante, irreverente")

    #expect(ignored.contains("confiante"))
    #expect(ignored.contains("irreverente"))
    #expect(!ignored.contains("feminina"))
  }

  @Test("what was understood is shown back in Portuguese")
  func summarisesInPortuguese() {
    let summary = EvieVoiceDesign.parse("mulher jovem de voz grave").summary

    #expect(summary.contains("feminina"))
    #expect(summary.contains("jovem"))
    #expect(summary.contains("grave"))
  }

  @Test("age is read even when a gender word comes first")
  func readsEveryCategory() {
    let design = EvieVoiceDesign.parse("mulher idosa")

    #expect(design.gender == "female")
    #expect(design.age == "elderly")
  }
}
