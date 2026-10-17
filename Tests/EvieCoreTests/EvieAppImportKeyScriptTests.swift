import Foundation
import Testing

/// `Scripts/evie-app import-pc-key`, run for real with a stand-in for
/// `security`, so no keychain is touched.
///
/// The key must reach Evie's item through a pipe and never through an
/// argument: anything in an argv is readable by every process on the Mac for as
/// long as the command runs (`ps -o args`). The stand-in records its arguments
/// and its standard input separately, which is exactly the line being tested.
/// `HOME` is the sandbox, so the installed app the item is tied to is the
/// sandbox's own `Applications/Evie.app`.
@Suite("Evie app PC key import")
struct EvieAppImportKeyScriptTests {
  private let key = "sk-stand-in-0123456789abcdef"

  @Test("the key goes into a new item through stdin, tied to the installed app, never in argv")
  func importsThroughStdin() throws {
    let sandbox = try ImportSandbox(sourceKey: key, installsApp: true)

    let run = try sandbox.runImport()

    #expect(run.status == 0)
    let calls = try sandbox.securityCalls()
    #expect(calls.count == 3)
    #expect(calls.first == "find-generic-password -s local-ai-3090 -a gateway-api-key -w")
    // Whatever item held the name goes first, and the add has no -U: an item
    // someone else made would keep its own access list through an update.
    #expect(
      calls.dropFirst().first
        == "delete-generic-password -s com.matheusbgodoi.evie.model -a pc-3090")
    let app = sandbox.root.appendingPathComponent("Applications/Evie.app").path
    #expect(
      calls.last
        == "add-generic-password -s com.matheusbgodoi.evie.model -a pc-3090 "
        + "-l Evie — chave do modelo (models.example.invalid) -T \(app) -w"
    )
    // `-w` last, with no value: `security` then reads the secret, twice, from
    // stdin.
    #expect(try sandbox.addInput() == "\(key)\n\(key)\n")
    #expect(!calls.joined(separator: "\n").contains(key))
    #expect(!run.output.contains(key))
  }

  @Test("with no item under Evie's name yet, the delete finding nothing is not an error")
  func importsWithNoEarlierItem() throws {
    let sandbox = try ImportSandbox(sourceKey: key, installsApp: true, deleteStatus: 44)

    let run = try sandbox.runImport()

    #expect(run.status == 0)
    #expect(
      try sandbox.securityCalls().map { $0.components(separatedBy: " ").first } == [
        "find-generic-password", "delete-generic-password", "add-generic-password",
      ])
    #expect(try sandbox.addInput() == "\(key)\n\(key)\n")
  }

  @Test("an item under Evie's name that cannot be deleted gets no key")
  func refusesWhenTheOldItemStays() throws {
    let sandbox = try ImportSandbox(sourceKey: key, installsApp: true, deleteStatus: 51)

    let run = try sandbox.runImport()

    #expect(run.status != 0)
    #expect(
      try sandbox.securityCalls().map { $0.components(separatedBy: " ").first } == [
        "find-generic-password", "delete-generic-password",
      ])
    #expect(!run.output.contains(key))
  }

  @Test("an add that finds the item back is a failure, not a success")
  func refusesWhenTheItemReturns() throws {
    let sandbox = try ImportSandbox(sourceKey: key, installsApp: true, addStatus: 45)

    let run = try sandbox.runImport()

    #expect(run.status != 0)
    #expect(!run.output.contains("Saved the PC key"))
    #expect(!run.output.contains(key))
  }

  @Test("with Evie not installed nothing is read or written")
  func refusesWithoutTheInstalledApp() throws {
    let sandbox = try ImportSandbox(sourceKey: key, installsApp: false)

    let run = try sandbox.runImport()

    #expect(run.status != 0)
    #expect(try sandbox.securityCalls().isEmpty)
    #expect(run.output.contains("Scripts/evie-app install"))
  }

  @Test("with no PC configuration item nothing is written")
  func refusesWithoutTheSourceItem() throws {
    let sandbox = try ImportSandbox(sourceKey: nil, installsApp: true)

    let run = try sandbox.runImport()

    #expect(run.status != 0)
    #expect(
      try sandbox.securityCalls().map { $0.components(separatedBy: " ").first } == [
        "find-generic-password"
      ])
    #expect(run.output.contains("local-ai-3090"))
  }

  @Test("a source item holding more than one line is refused, and not echoed")
  func refusesAMultilineKey() throws {
    let sandbox = try ImportSandbox(sourceKey: "\(key)\nsecond-line", installsApp: true)

    let run = try sandbox.runImport()

    #expect(run.status != 0)
    #expect(try sandbox.securityCalls().count == 1)
    #expect(!run.output.contains(key))
  }
}

private struct ImportSandbox {
  let root: URL
  var bin: URL { root.appendingPathComponent("bin", isDirectory: true) }
  var securityLog: URL { root.appendingPathComponent("security.log") }
  var addInputLog: URL { root.appendingPathComponent("add-input.log") }
  var sourceFile: URL { root.appendingPathComponent("source-key") }

  init(sourceKey: String?, installsApp: Bool, deleteStatus: Int = 0, addStatus: Int = 0) throws {
    root = FileManager.default.temporaryDirectory
      .appendingPathComponent(UUID().uuidString, isDirectory: true)
    try FileManager.default.createDirectory(at: bin, withIntermediateDirectories: true)
    if installsApp {
      try FileManager.default.createDirectory(
        at: root.appendingPathComponent("Applications/Evie.app/Contents", isDirectory: true),
        withIntermediateDirectories: true
      )
    }
    if let sourceKey {
      try sourceKey.write(to: sourceFile, atomically: true, encoding: .utf8)
    }
    // Prints the source item like `security … -w` does (the secret and a line
    // break), exits 44 like `security` when there is none, answers a delete
    // and an add with the statuses given (44: no such item; 45: it exists),
    // and keeps what an `add-generic-password` reads from stdin apart from its
    // arguments.
    let source = """
      #!/bin/zsh
      print -r -- "$*" >> \(securityLog.path)
      case "$1" in
        find-generic-password)
          [[ -f \(sourceFile.path) ]] || exit 44
          /bin/cat \(sourceFile.path); print ""
          ;;
        delete-generic-password)
          exit \(deleteStatus)
          ;;
        add-generic-password)
          /bin/cat >> \(addInputLog.path)
          exit \(addStatus)
          ;;
        *) exit 1 ;;
      esac
      """
    let url = bin.appendingPathComponent("security")
    try source.write(to: url, atomically: true, encoding: .utf8)
    try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: url.path)
  }

  func runImport() throws -> (status: Int32, output: String) {
    let script = URL(fileURLWithPath: #filePath)
      .deletingLastPathComponent()
      .deletingLastPathComponent()
      .deletingLastPathComponent()
      .appendingPathComponent("Scripts/evie-app")
    let process = Process()
    process.executableURL = URL(fileURLWithPath: "/bin/zsh")
    process.arguments = [script.path, "import-pc-key"]
    process.environment = [
      "HOME": root.path,
      "PATH": "\(bin.path):/usr/bin:/bin:/usr/sbin:/sbin",
    ]
    let output = Pipe()
    process.standardInput = FileHandle.nullDevice
    process.standardOutput = output
    process.standardError = output
    try process.run()
    let data = output.fileHandleForReading.readDataToEndOfFile()
    process.waitUntilExit()
    return (process.terminationStatus, String(decoding: data, as: UTF8.self))
  }

  func securityCalls() throws -> [String] {
    guard FileManager.default.fileExists(atPath: securityLog.path) else { return [] }
    return try String(contentsOf: securityLog, encoding: .utf8)
      .split(separator: "\n").map(String.init)
  }

  func addInput() throws -> String {
    try String(contentsOf: addInputLog, encoding: .utf8)
  }
}
