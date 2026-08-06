import Foundation
import Testing

@testable import EvieCore

@Suite("Evie wake phrase")
struct EvieWakePhraseTests {
  private let phrase = "Ei, Evie"

  /// The reported failure: she never came. "Evie" is not a Portuguese word, so a
  /// pt-BR recogniser returns whatever real words fit the sound, and exact
  /// matching never fires.
  @Test("the ways a pt-BR recogniser writes an invented name all wake her")
  func toleratesMishearings() {
    for heard in [
      "ei evie",
      "Ei, Evie!",
      "ei ivi",
      "ei evi",
      "ei eve",
      "ei e vi",
      "ei ivie",
      "hei evie",
    ] {
      #expect(
        EvieWakePhrase.matches(heard, phrases: phrase),
        "deveria acordar com \"\(heard)\""
      )
    }
  }

  /// Where a recogniser puts a word boundary inside a name it has never seen is
  /// arbitrary, so it is not compared at all.
  @Test("word boundaries inside the name are ignored")
  func ignoresSpacing() {
    #expect(EvieWakePhrase.normalize("Ei, Evie!") == EvieWakePhrase.normalize("e i e v i e"))
  }

  @Test("ordinary speech does not wake her")
  func doesNotFireOnSpeech() {
    for heard in [
      "preciso revisar o contrato hoje",
      "vou almoçar agora",
      "a reunião com a Eurofarma ficou para quinta",
      "que horas são",
      "eu vi o filme ontem",
      // Deliberately close, and the reason the threshold has a measured margin
      // rather than a comfortable-looking round number.
      "seis e meia",
      "aquele vinho",
      "hoje eu vi",
      "o time venceu",
      "ele vive aqui",
    ] {
      #expect(
        !EvieWakePhrase.matches(heard, phrases: phrase),
        "não deveria acordar com \"\(heard)\""
      )
    }
  }

  /// Anchored at the end, or a transcript that once contained the phrase keeps
  /// matching for as long as it is held and she wakes on every later syllable.
  @Test("only what was just said counts")
  func matchesOnlyTheTail() {
    #expect(EvieWakePhrase.matches("então eu disse ei evie", phrases: phrase))
    #expect(
      !EvieWakePhrase.matches(
        "ei evie me lembra de comprar pão e depois ligar para o contador",
        phrases: phrase
      )
    )
  }

  /// The first separator tried was the comma, which broke the single most
  /// obvious phrase: "Ei, Evie" split in two and she listened for a bare "Evie".
  @Test("a comma is part of the phrase, not a separator")
  func commaIsNotASeparator() {
    #expect(EvieWakePhrase.phrases(in: "Ei, Evie") == ["eievie"])
  }

  /// No amount of fuzzy matching beats being able to add what the recogniser
  /// actually produced.
  @Test("several phrases can be accepted at once")
  func acceptsVariants() {
    let configured = "Ei, Evie; Oi Evie; Escuta"

    #expect(EvieWakePhrase.matches("oi evie", phrases: configured))
    #expect(EvieWakePhrase.matches("escuta", phrases: configured))
    #expect(EvieWakePhrase.matches("ei evie", phrases: configured))
    #expect(!EvieWakePhrase.matches("tchau", phrases: configured))
  }

  /// At three characters, "close enough" is one wrong letter out of three, and
  /// ordinary speech trips it constantly.
  @Test("a phrase too short to be safe is refused rather than accepted")
  func refusesShortPhrases() {
    #expect(EvieWakePhrase.phrases(in: "oi").isEmpty)
    #expect(EvieWakePhrase.phrases(in: "ei").isEmpty)
    #expect(!EvieWakePhrase.matches("oi", phrases: "oi"))
    #expect(!EvieWakePhrase.phrases(in: "evie").isEmpty)
  }

  @Test("nothing configured wakes nothing")
  func emptyConfiguration() {
    #expect(!EvieWakePhrase.matches("ei evie", phrases: ""))
    #expect(!EvieWakePhrase.matches("ei evie", phrases: "   "))
    #expect(!EvieWakePhrase.matches("", phrases: phrase))
  }

  @Test("distance is measured the way it is defined")
  func editDistanceIsCorrect() {
    #expect(EvieWakePhrase.editDistance(Array("evie"), Array("evie")) == 0)
    #expect(EvieWakePhrase.editDistance(Array("evie"), Array("ivie")) == 1)
    #expect(EvieWakePhrase.editDistance(Array(""), Array("evie")) == 4)
    #expect(EvieWakePhrase.editDistance(Array("gato"), Array("rato")) == 1)
  }
}
