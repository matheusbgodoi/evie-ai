import Foundation
import Testing

/// `Scripts/evie-app identity`, run for real with stand-ins for `security` and
/// `mktemp`, so no keychain is touched and the scratch directory is one the test
/// can inspect.
///
/// The step writes an unencrypted private key (`openssl req -nodes`) and a p12
/// with a fixed password into a scratch directory. Under `set -e` a failed
/// `security import`, or a trust prompt the person cancels, used to end the
/// script before its `rm -rf`, leaving the signing key on disk. The real
/// `/usr/bin/openssl` runs, so the key really is written each time.
///
/// `HOME` is the sandbox too: even if the stand-in were bypassed, the keychain
/// path the script passes to `security` would not exist.
@Suite("Evie app signing identity")
struct EvieAppIdentityScriptTests {
  @Test(
    "a failed step leaves no key or certificate behind",
    arguments: ["import", "add-trusted-cert", "none"]
  )
  func scratchDirectoryIsRemoved(failingStep: String) throws {
    let sandbox = try IdentitySandbox()

    let status = try sandbox.runIdentity(failingStep: failingStep)

    // With every step passing the stand-in still lists no identity, so the
    // script's own check fails it; the scratch directory must go in all cases.
    #expect(status != 0)
    let calls = try sandbox.securityCalls()
    #expect(calls.contains { $0.hasPrefix("import ") })
    if failingStep != "import" {
      #expect(calls.contains { $0.hasPrefix("add-trusted-cert ") })
    }
    #expect(try sandbox.scratchDirectoriesMade() == 1, "o mktemp de teste não foi usado")
    #expect(try sandbox.scratchLeftovers().isEmpty)
  }
}

private struct IdentitySandbox {
  let root: URL
  var bin: URL { root.appendingPathComponent("bin", isDirectory: true) }
  var scratch: URL { root.appendingPathComponent("scratch", isDirectory: true) }
  var securityLog: URL { root.appendingPathComponent("security.log") }
  var mktempLog: URL { root.appendingPathComponent("mktemp.log") }

  init() throws {
    root = FileManager.default.temporaryDirectory
      .appendingPathComponent(UUID().uuidString, isDirectory: true)
    try FileManager.default.createDirectory(at: bin, withIntermediateDirectories: true)
    try FileManager.default.createDirectory(at: scratch, withIntermediateDirectories: true)
    try install(
      "security",
      """
      #!/bin/zsh
      print -r -- "$*" >> \(securityLog.path)
      case "$1" in
        find-identity) print "     0 valid identities found"; exit 0 ;;
        import|add-trusted-cert) [[ "$1" != "${EVIE_TEST_FAILING_STEP}" ]] ;;
        *) exit 1 ;;
      esac
      """
    )
    try install(
      "mktemp",
      """
      #!/bin/zsh
      dir=\(scratch.path)/work.$$
      /bin/mkdir -m 700 "${dir}" && print -r -- "${dir}" >> \(mktempLog.path) && print -r -- "${dir}"
      """
    )
  }

  private func install(_ name: String, _ source: String) throws {
    let url = bin.appendingPathComponent(name)
    try source.write(to: url, atomically: true, encoding: .utf8)
    try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: url.path)
  }

  func runIdentity(failingStep: String) throws -> Int32 {
    let script = URL(fileURLWithPath: #filePath)
      .deletingLastPathComponent()
      .deletingLastPathComponent()
      .deletingLastPathComponent()
      .appendingPathComponent("Scripts/evie-app")
    let process = Process()
    process.executableURL = URL(fileURLWithPath: "/bin/zsh")
    process.arguments = [script.path, "identity"]
    process.environment = [
      "HOME": root.path,
      "PATH": "\(bin.path):/usr/bin:/bin:/usr/sbin:/sbin",
      "EVIE_TEST_FAILING_STEP": failingStep,
    ]
    process.standardInput = FileHandle.nullDevice
    process.standardOutput = FileHandle.nullDevice
    process.standardError = FileHandle.nullDevice
    try process.run()
    process.waitUntilExit()
    return process.terminationStatus
  }

  func securityCalls() throws -> [String] {
    try String(contentsOf: securityLog, encoding: .utf8)
      .split(separator: "\n").map(String.init)
  }

  func scratchDirectoriesMade() throws -> Int {
    guard FileManager.default.fileExists(atPath: mktempLog.path) else { return 0 }
    return try String(contentsOf: mktempLog, encoding: .utf8)
      .split(separator: "\n").count
  }

  func scratchLeftovers() throws -> [String] {
    try FileManager.default.subpathsOfDirectory(atPath: scratch.path)
  }
}
