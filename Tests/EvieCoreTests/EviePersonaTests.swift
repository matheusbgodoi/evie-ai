import Foundation
import Testing

@testable import EvieCore

@Suite("Evie persona")
struct EviePersonaTests {
  @Test("names its creator and how he is addressed")
  func namesCreator() {
    let prompt = EviePersona.evie.systemPrompt(capabilities: .textOnly)

    #expect(prompt.contains("Matheus Barboza de Godoi"))
    #expect(prompt.contains("Matheus"))
    #expect(prompt.contains("masculino"))
    #expect(prompt.contains("você"))
  }

  @Test("never leaks the inference backend into the model's own instructions")
  func hidesBackendNames() {
    for capabilities in [EvieCapabilitySnapshot.textOnly, .allEnabled] {
      let prompt = EviePersona.evie.systemPrompt(capabilities: capabilities)
      for name in ["Gemma", "TurboFieldfare", "127.0.0.1", "OpenAI", "OmniVoice"] {
        #expect(!prompt.contains(name), "prompt leaked \(name)")
      }
    }
  }

  @Test("declares text-only limits when nothing else is enabled")
  func describesTextOnlyLimits() {
    let prompt = EviePersona.evie.systemPrompt(capabilities: .textOnly)

    #expect(prompt.contains("ainda não"))
    #expect(prompt.contains("arquivos"))
    #expect(!prompt.contains("Você pode ler arquivos"))
  }

  @Test("announces a capability only once it is actually enabled")
  func describesEnabledCapabilities() {
    var capabilities = EvieCapabilitySnapshot.textOnly
    capabilities.readsLocalFiles = true

    let prompt = EviePersona.evie.systemPrompt(capabilities: capabilities)

    #expect(prompt.contains("Você pode ler arquivos"))
    #expect(prompt.contains("apagar"))
  }

  @Test("keeps the spoken-answer instruction tied to the voice switch")
  func describesSpeech() {
    var capabilities = EvieCapabilitySnapshot.textOnly
    #expect(!EviePersona.evie.systemPrompt(capabilities: capabilities).contains("em voz alta"))

    capabilities.speaksAnswers = true
    #expect(EviePersona.evie.systemPrompt(capabilities: capabilities).contains("em voz alta"))
  }

  @Test("produces the same prompt for the same capabilities")
  func isDeterministic() {
    // The moment is fixed here: the prompt now carries the current date, so two
    // calls that straddle a minute boundary differ by design rather than by
    // accident, and the determinism worth testing is everything else.
    let moment = Date(timeIntervalSince1970: 1_786_123_920)
    let first = EviePersona.evie.systemPrompt(capabilities: .allEnabled, now: moment)
    let second = EviePersona.evie.systemPrompt(capabilities: .allEnabled, now: moment)

    #expect(first == second)
  }

  @Test("treats external content as data rather than instructions")
  func statesUntrustedContentRule() {
    let prompt = EviePersona.evie.systemPrompt(capabilities: .allEnabled)

    #expect(prompt.contains("não confiável"))
  }
}
