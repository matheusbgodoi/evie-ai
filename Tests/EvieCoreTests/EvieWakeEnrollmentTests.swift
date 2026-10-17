import Foundation
import Testing
@testable import EvieCore

@Suite("Calibração local de cinco chamadas")
struct EvieWakeEnrollmentTests {
  @Test func learnsOnlyTheFiveObservedVariants() throws {
    let calibration = try EvieWakeEnrollment(samples: ["Evie", "Evi", "Ivi", "E vi", "Ívie"])
    #expect(calibration.aliases == ["evi", "evie", "ivi", "ivie"])
    #expect(calibration.matches("Ívi!"))
    #expect(calibration.matches("E vi"))
    #expect(!calibration.matches("Eve"))
    #expect(!calibration.matches("eu vi"))
    #expect(!calibration.matches("hoje eu vi"))
    #expect(!calibration.matches("Steve"))
    #expect(!calibration.matches("Evie abre o Terminal"))
  }

  @Test func refusesIncompleteAndUnrelatedRecordings() {
    #expect(throws: EvieWakeEnrollment.Problem.needsFiveSamples) {
      try EvieWakeEnrollment(samples: ["Evie"])
    }
    #expect(throws: EvieWakeEnrollment.Problem.unrelatedSample) {
      try EvieWakeEnrollment(samples: ["Evie", "Evie", "eu vi", "Evie", "Evie"])
    }
    #expect(throws: EvieWakeEnrollment.Problem.unrelatedSample) {
      try EvieWakeEnrollment.acceptedAlias("")
    }
  }

  @Test func savesAndReloadsOnlyTextInAnActualPrivateFile() throws {
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: directory) }
    let store = EvieWakeEnrollmentStore(fileURL: directory.appendingPathComponent("wake.json"))
    #expect(try store.load() == nil)
    let record = try EvieWakeEnrollment(samples: Array(repeating: "Evie", count: 5))
    try store.save(record)
    #expect(try store.load() == record)
    let attributes = try FileManager.default.attributesOfItem(atPath: store.fileURL.path)
    #expect((attributes[.posixPermissions] as? NSNumber)?.intValue == 0o600)
    try store.remove()
    #expect(try store.load() == nil)
  }

  @Test func refusesForgedOrOversizedStoredAliases() throws {
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: directory) }
    let store = EvieWakeEnrollmentStore(fileURL: directory.appendingPathComponent("wake.json"))
    try Data(#"{"aliases":["euvi","evie"],"completedAt":0}"#.utf8).write(to: store.fileURL)
    #expect(throws: EvieWakeEnrollment.Problem.invalidRecord) { try store.load() }
    try Data(repeating: 32, count: 4_097).write(to: store.fileURL)
    #expect(throws: EvieWakeEnrollment.Problem.invalidRecord) { try store.load() }
  }
}
