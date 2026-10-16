import Foundation
import Testing

@testable import EvieCore

@Suite("Computer app catalog")
struct ComputerAppCatalogTests {
  static let catalog = ComputerAppCatalog(apps: [
    ResolvedApp(bundleID: "com.apple.Notes", displayName: "Notas", otherNames: ["Notes"]),
    ResolvedApp(bundleID: "com.apple.TextEdit", displayName: "TextEdit"),
    ResolvedApp(
      bundleID: "com.apple.calculator", displayName: "Calculadora", otherNames: ["Calculator"]),
    ResolvedApp(bundleID: "com.example.notes2", displayName: "Notes", otherNames: ["Notes"]),
  ])

  @Test("the name the Finder shows wins, ignoring case, accents and .app")
  func displayName() {
    #expect(Self.catalog.resolve(name: "notas")?.bundleID == "com.apple.Notes")
    #expect(Self.catalog.resolve(name: "TEXTEDIT.app")?.bundleID == "com.apple.TextEdit")
    #expect(Self.catalog.resolve(name: " Calculadora ")?.bundleID == "com.apple.calculator")
  }

  @Test("another name is found when no app shows that name")
  func otherNames() {
    #expect(Self.catalog.resolve(name: "Calculator")?.bundleID == "com.apple.calculator")
  }

  @Test("a display name beats another app's alternative name")
  func displayNameFirst() {
    #expect(Self.catalog.resolve(name: "Notes")?.bundleID == "com.example.notes2")
  }

  @Test("a prefix or an empty name finds nothing")
  func wholeNamesOnly() {
    #expect(Self.catalog.resolve(name: "Not") == nil)
    #expect(Self.catalog.resolve(name: "  ") == nil)
    #expect(Self.catalog.resolve(name: "Terminal") == nil)
  }
}
