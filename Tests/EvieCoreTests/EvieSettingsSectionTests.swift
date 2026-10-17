import Foundation
import Testing

@testable import EvieCore

/// The settings window's sidebar and the sentences that point into it.
@Suite("Evie settings sections")
struct EvieSettingsSectionTests {
  @Test("the sidebar lists every section in the owner's order")
  func order() {
    #expect(
      EvieSettingsSection.allCases.map(\.title) == [
        "Geral", "Cérebro", "Tela e modo agente", "Arquivos e pastas", "Voz", "Atalhos",
        "O que ela sabe", "Aparência", "Permissões", "Avançado",
      ])
  }

  @Test("every section has its own symbol, so no two rows look alike")
  func symbols() {
    let symbols = EvieSettingsSection.allCases.map(\.systemImage)
    #expect(Set(symbols).count == symbols.count)
    #expect(symbols.allSatisfy { !$0.isEmpty })
  }

  @Test("a section's path is how other sentences name it")
  func path() {
    #expect(EvieSettingsSection.screenAndAgent.path == "Configurações › Tela e modo agente")
  }

  @Test("the agent-mode messages send the person to the section that holds the switch")
  func switchCopyPointsAtTheSection() {
    let off = EviePreferences(computerUseEnabled: false)

    #expect(
      ComputerUseSwitch.unavailableReason(preferences: off, environment: [:])
        == "O modo agente está desligado em Configurações › Tela e modo agente.")
    #expect(ComputerUseCopy.switchedOff.contains("Configurações › Tela e modo agente"))
  }

  @Test("the switch's paragraph names every way to stop, with the shortcut as bound")
  func explanationNamesTheStops() {
    let bound = ComputerUseCopy.settingsExplanation(stopShortcut: "⌥⇧Esc")
    let unbound = ComputerUseCopy.settingsExplanation(stopShortcut: nil)

    #expect(bound.contains("Para parar na hora: Esc, ⌥⇧Esc ou o botão Parar."))
    #expect(unbound.contains("Para parar na hora: Esc ou o botão Parar."))
    #expect(bound.contains("15 minutos"))
    #expect(bound.contains("Desligado, ela ainda olha a tela"))
    #expect(!bound.contains("\n"))
  }
}
