import Foundation
import Testing

@testable import EvieCore

@Suite("Evie commands")
struct EvieCommandTests {
  @Test("a lone slash offers everything there is")
  func offersAllOnSlash() {
    #expect(EvieCommandCatalogue.suggestions(for: "/").count == EvieCommandCatalogue.all.count)
    #expect(!EvieCommandCatalogue.suggestions(for: "/").isEmpty)
  }

  @Test("typing narrows to what matches")
  func narrowsByPrefix() {
    #expect(EvieCommandCatalogue.suggestions(for: "/pl").map(\.name) == ["/plano"])
    #expect(EvieCommandCatalogue.suggestions(for: "/PLA").map(\.name) == ["/plano"])
    #expect(EvieCommandCatalogue.suggestions(for: "/zzz").isEmpty)
  }

  /// Most of what anybody types is not a command, and a menu that appears over
  /// ordinary questions is worse than no menu.
  @Test("ordinary writing offers nothing")
  func staysOutOfTheWay() {
    for input in ["", "compare X e Y", "quanto é 2/3", "e-mail: a/b"] {
      #expect(EvieCommandCatalogue.suggestions(for: input).isEmpty, "sugeriu para \"\(input)\"")
    }
  }

  /// Once there is a space the command has been named and the rest is its
  /// question — suggesting through that would leave a menu over the field for as
  /// long as the question takes to write.
  @Test("the menu closes as soon as the argument starts")
  func closesOnArgument() {
    #expect(EvieCommandCatalogue.suggestions(for: "/plano ").isEmpty)
    #expect(EvieCommandCatalogue.suggestions(for: "/plano compare X e Y").isEmpty)
  }

  @Test("choosing a command leaves the caret where the question goes")
  func completionEndsWithASpace() throws {
    let command = try #require(EvieCommandCatalogue.all.first)

    #expect(command.completion == command.name + " ")
  }

  /// Return has to know whether it is completing or submitting, and a name typed
  /// out in full is already complete.
  @Test("a name typed in full is recognised as finished")
  func recognisesACompleteName() {
    #expect(EvieCommandCatalogue.isComplete("/plano"))
    #expect(EvieCommandCatalogue.isComplete("  /PLANO "))
    #expect(!EvieCommandCatalogue.isComplete("/pl"))
    #expect(!EvieCommandCatalogue.isComplete("/plano X"))
  }

  /// Every command in the catalogue has to be one the app answers to, or the
  /// menu offers something that does nothing.
  @Test("every command offered is one she actually runs")
  func catalogueMatchesReality() {
    for command in EvieCommandCatalogue.all {
      #expect(command.name.hasPrefix("/"))
      #expect(!command.summary.isEmpty)
    }
    #expect(EvieCommandCatalogue.all.contains { $0.name == EviePlanCommand.name })
    // The one that runs it and the one that shows it read the same constant.
    #expect(EviePlanCommand.question(in: EviePlanCommand.name + " x") == "x")
  }
}
