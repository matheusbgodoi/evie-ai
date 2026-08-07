import AppKit
import EvieCore
import Foundation

/// The checks around shipping a new version, storing what gets dropped on her,
/// and putting the window on screen.
extension EvieDiagnostics {
  static func updateCheck() async {
    let running = Bundle.main.bundleURL
    print("rodando: \(running.path)")
    print("versão instalada: \(EvieUpdater.installedVersion?.description ?? "nenhuma")")
    print("é um bundle: \(EvieUpdater.isRunningFromBundle)")

    switch (try? EvieBundleSignature.leafCertificateHash(ofBundleAt: running)) ?? nil {
    case .some(let hash):
      print("certificado desta cópia: \(hash.prefix(8).map { String(format: "%02x", $0) }.joined())…")
    case .none:
      print("certificado desta cópia: NENHUM (ad-hoc) — nenhuma atualização seria aceita")
    }

    // Against tampered copies of this exact bundle, so the table in
    // EvieBundleSignature is a measurement rather than a claim.
    print("")
    print("verificação contra cópias adulteradas:")
    let workspace = URL(fileURLWithPath: NSTemporaryDirectory())
      .appendingPathComponent("evie-update-check-\(ProcessInfo.processInfo.processIdentifier)")
    defer { try? FileManager.default.removeItem(at: workspace) }
    try? FileManager.default.createDirectory(at: workspace, withIntermediateDirectories: true)

    for (label, tamper) in tamperings {
      let copy = workspace.appendingPathComponent("\(label).app")
      try? FileManager.default.removeItem(at: copy)
      guard (try? FileManager.default.copyItem(at: running, to: copy)) != nil else {
        print("  \(label): não consegui copiar")
        continue
      }
      tamper(copy)
      do {
        try EvieBundleSignature.verify(candidateAt: copy, matchesSignerOf: running)
        print("  \(label): ACEITOU — investigar")
      } catch {
        print("  \(label): recusado — \((error as? LocalizedError)?.errorDescription ?? "\(error)")")
      }
    }
    // The control: an untouched copy must be accepted, or the check is only
    // refusing everything and proving nothing.
    let clean = workspace.appendingPathComponent("intacta.app")
    try? FileManager.default.copyItem(at: running, to: clean)
    do {
      try EvieBundleSignature.verify(candidateAt: clean, matchesSignerOf: running)
      print("  cópia intacta: aceita (controle)")
    } catch {
      print("  cópia intacta: RECUSADA — \(error)")
    }

    print("")
    let updater = EvieUpdater()
    await updater.check(force: true)
    print("feed: \(updater.state)")
  }

  /// The ways a downloaded bundle could have been interfered with.
  private static var tamperings: [(String, (URL) -> Void)] {
    [
      (
        "info-plist-alterado",
        { copy in
          let plist = copy.appendingPathComponent("Contents/Info.plist")
          guard var text = try? String(contentsOf: plist, encoding: .utf8) else { return }
          text = text.replacingOccurrences(of: "<string>APPL</string>", with: "<string>APPX</string>")
          try? text.write(to: plist, atomically: true, encoding: .utf8)
        }
      ),
      (
        "recurso-adicionado",
        { copy in
          let extra = copy.appendingPathComponent("Contents/Resources/injetado.sh")
          try? "malicioso".write(to: extra, atomically: true, encoding: .utf8)
        }
      ),
      (
        "reassinado-adhoc",
        { copy in
          let sign = Process()
          sign.executableURL = URL(fileURLWithPath: "/usr/bin/codesign")
          sign.arguments = ["--force", "--deep", "-s", "-", copy.path]
          sign.standardError = FileHandle.nullDevice
          sign.standardOutput = FileHandle.nullDevice
          try? sign.run()
          sign.waitUntilExit()
        }
      ),
    ]
  }

  /// Stores real files and reports what they cost.
  ///
  /// Quits from in here rather than through the registry's usual wrapper so that
  /// the request keeps its original position relative to the `defer` above it.
  static func mediaCheck(paths: [String]) async {
    setvbuf(stdout, nil, _IOLBF, 0)
    let folder = URL(fileURLWithPath: NSTemporaryDirectory())
      .appendingPathComponent("evie-media-check-\(ProcessInfo.processInfo.processIdentifier)")
    defer { try? FileManager.default.removeItem(at: folder) }
    let store = EvieMediaStore(directoryURL: folder)
    for path in paths where !path.hasPrefix("--") {
      let url = URL(fileURLWithPath: path)
      let before =
        ((try? FileManager.default.attributesOfItem(atPath: url.path))?[.size] as? Int) ?? 0
      guard let stored = store.store(url, originalName: url.lastPathComponent, messageID: nil)
      else {
        print("\(url.lastPathComponent): não consegui guardar")
        continue
      }
      let ratio = before > 0 ? Double(stored.byteCount) / Double(before) : 1
      print(
        String(
          format: "%@: %d KB → %d KB (%.0f%% do original)",
          url.lastPathComponent, before / 1024, stored.byteCount / 1024, ratio * 100
        )
      )
    }
    print(String(format: "pasta inteira: %d KB", store.totalBytes() / 1024))
    NSApp.terminate(nil)
  }

  static func presentationCheck(coordinator: AppCoordinator) async {
    var report: [String] = []
    try? await Task.sleep(for: .milliseconds(400))
    report.append("depois de abrir: \(coordinator.presentationDiagnostics)")

    coordinator.diagnosticHide()
    try? await Task.sleep(for: .milliseconds(40))
    coordinator.diagnosticShow()
    try? await Task.sleep(for: .milliseconds(400))
    report.append("depois de esconder e reabrir rápido: \(coordinator.presentationDiagnostics)")

    coordinator.diagnosticHide()
    try? await Task.sleep(for: .milliseconds(400))
    report.append("depois de esconder: \(coordinator.presentationDiagnostics)")

    coordinator.diagnosticShow()
    try? await Task.sleep(for: .milliseconds(400))
    report.append("depois de reabrir: \(coordinator.presentationDiagnostics)")

    writeLog(report, named: "presentation-check.txt")
  }
}
