import AppKit
import EvieCore
import Foundation

/// The checks that read something off disk, look at it, or change it.
extension EvieDiagnostics {
  static func read(fileAt url: URL) async {
    do {
      let pages = try await EvieDocumentReader().read(fileAt: url)
      print(pages.promptEvidence)
    } catch {
      // Standard error, so piping the output of this flag into a prompt never
      // quietly includes the reason it failed as if it were the document.
      FileHandle.standardError.write(
        Data(
          ((error as? LocalizedError)?.errorDescription
            ?? error.localizedDescription).utf8)
      )
    }
  }

  static func see(imageAt url: URL) async {
    print("visão disponível: \(EvieVisionDescriber.isAvailable)")
    if let reason = EvieVisionDescriber.unavailableReason {
      print("motivo: \(reason)")
    }
    let started = Date()
    do {
      let seen = try await EvieVisionDescriber().describe(imageAt: url)
      print(String(format: "descrito em %.2f s:", Date().timeIntervalSince(started)))
      print("  \(seen)")
    } catch {
      print("falhou: \((error as? LocalizedError)?.errorDescription ?? "\(error)")")
    }
    // And the text in it, which is the other half.
    if let pages = try? await EvieDocumentReader().read(fileAt: url) {
      let text = pages.map(\.text).joined(separator: " ").prefix(200)
      print("texto reconhecido: \(text.isEmpty ? "(nenhum)" : String(text))")
    }
  }

  static func changeCheck() async {
    let directory = FileManager.default.temporaryDirectory
      .appendingPathComponent("evie-change-check", isDirectory: true)
    try? FileManager.default.removeItem(at: directory)
    try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    try? Data("rascunho velho\n".utf8)
      .write(to: directory.appendingPathComponent("rascunho-antigo.txt"))
    try? Data("importante\n".utf8)
      .write(to: directory.appendingPathComponent("contrato.pdf.txt"))
    defer { try? FileManager.default.removeItem(at: directory) }

    let roots = [
      EvieFileRoot(id: "chk00001", displayName: "Pasta de teste", path: directory.path)
    ]
    var capabilities = EvieCapabilitySnapshot.textOnly
    capabilities.readsLocalFiles = true
    let configuration = (try? EvieConfigurationLoader().load()) ?? EvieConfiguration()

    let question = "manda o rascunho-antigo.txt pro lixo"
    print("pergunta: \(question)")
    print("a mensagem dele pede mudança: \(EvieChangeIntent.isPresent(in: question))")

    do {
      let outcome = try await EvieAgentLoop(offersChanges: true).run(
        messages: [
          ChatMessage(
            role: .system,
            content: EviePersona.evie.systemPrompt(capabilities: capabilities)
          ),
          ChatMessage(role: .user, content: question),
        ],
        roots: roots,
        client: TurboFieldfareClient(configuration: configuration),
        emit: { event in
          if case .status(let message) = event { print("   · \(message)") }
        }
      )

      guard let change = outcome.changeProposals.first else {
        print("NÃO propôs mudança nenhuma. Resposta: \(outcome.answer.prefix(200))")
        return
      }
      print("propôs: \(change.describe(rootName: "Pasta de teste"))")
      print("  identidade capturada: \(change.precondition != nil)")
      print("  arquivo ainda lá antes de aprovar: "
        + "\(FileManager.default.fileExists(atPath: directory.appendingPathComponent("rascunho-antigo.txt").path))")

      let receipt = try EvieFileWriter().perform(change, in: roots[0])
      print("aprovado e feito: \(receipt.change.kind.rawValue)")
      print("  arquivo sumiu da pasta: "
        + "\(!FileManager.default.fileExists(atPath: directory.appendingPathComponent("rascunho-antigo.txt").path))")
      print("  o outro arquivo continua: "
        + "\(FileManager.default.fileExists(atPath: directory.appendingPathComponent("contrato.pdf.txt").path))")
    } catch {
      print("FALHOU: \((error as? LocalizedError)?.errorDescription ?? "\(error)")")
    }
  }
}
