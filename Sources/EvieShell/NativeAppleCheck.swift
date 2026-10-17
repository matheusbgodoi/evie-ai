import AppIntents
import Foundation
import FoundationModels

/// Exercises the actual AppIntent.perform entry points with synthetic text.
/// No screen capture, model generation, input events, user data or permissions.
@MainActor
enum NativeAppleCheck {
  struct Report: Encodable {
    let success: Bool
    let checks: [String]
    let error: String?
  }

  static func report() async -> Report {
    do {
      return Report(success: true, checks: try await run(), error: nil)
    } catch {
      return Report(success: false, checks: [], error: error.localizedDescription)
    }
  }

  private enum Failure: LocalizedError {
    case check(String)

    var errorDescription: String? {
      if case .check(let message) = self { return message }
      return nil
    }
  }

  static func run(requireMetadata: Bool = true) async throws -> [String] {
    guard NativeAppleActions.handle == nil else {
      throw Failure.check("Execute a verificação em um processo separado da Evie aberta.")
    }
    defer { NativeAppleActions.handle = nil }

    do {
      _ = try await OpenEvieIntent().perform()
      throw Failure.check("Uma ação foi aceita antes de a interface estar pronta.")
    } catch NativeAppleError.notReady {}

    var received: [NativeAppleRequest] = []
    NativeAppleActions.handle = { received.append($0) }
    _ = try await OpenEvieIntent().perform()
    let prepare = PrepareEvieQuestionIntent()
    prepare.question = "  Pergunta sintética de integração.\n"
    _ = try await prepare.perform()
    _ = try await CaptureEvieScreenIntent().perform()
    guard
      received == [
        .openConversation,
        .prepareQuestion("Pergunta sintética de integração."),
        .captureScreen,
      ]
    else {
      throw Failure.check("As ações nativas não chegaram ao destino esperado.")
    }

    prepare.question = " \n "
    do {
      _ = try await prepare.perform()
      throw Failure.check("Uma pergunta vazia foi aceita.")
    } catch NativeAppleError.emptyQuestion {}
    prepare.question = String(repeating: "á", count: 8_000)
    _ = try await prepare.perform()
    prepare.question.append("á")
    do {
      _ = try await prepare.perform()
      throw Failure.check("Uma pergunta acima do limite foi aceita.")
    } catch NativeAppleError.questionTooLong {}
    guard received.count == 4 else {
      throw Failure.check("Uma pergunta inválida chegou à interface.")
    }

    NativeAppleActions.handle = { _ in throw NativeAppleError.busy }
    do {
      _ = try await OpenEvieIntent().perform()
      throw Failure.check("Uma interface ocupada aceitou uma ação nativa.")
    } catch NativeAppleError.busy {}

    var lines = [
      "PASS: os três AppIntent.perform encaminham as ações corretas.",
      "PASS: início incompleto, interface ocupada, texto vazio e limite Unicode.",
    ]
    let metadata = Bundle.main.bundleURL
      .appendingPathComponent("Contents/Resources/Metadata.appintents/extract.actionsdata")
    if FileManager.default.fileExists(atPath: metadata.path) {
      let raw = try Data(contentsOf: metadata)
      guard let document = try JSONSerialization.jsonObject(with: raw) as? [String: Any],
        let actions = document["actions"] as? [String: Any],
        Set(actions.keys)
          == Set([
            "OpenEvieIntent", "PrepareEvieQuestionIntent", "CaptureEvieScreenIntent",
          ]),
        let shortcuts = document["autoShortcuts"] as? [Any], shortcuts.count == 3
      else {
        throw Failure.check("Os metadados do bundle não contêm as três ações e atalhos.")
      }
      lines.append("PASS: bundle com metadados de 3 ações e 3 App Shortcuts.")
    } else if requireMetadata {
      throw Failure.check("Metadados ausentes. Compile o bundle com Scripts/evie-app build.")
    }

    switch SystemLanguageModel.default.availability {
    case .available:
      lines.append("Foundation Models: disponível neste Mac.")
    case .unavailable(let reason):
      switch reason {
      case .appleIntelligenceNotEnabled:
        lines.append("Foundation Models: Apple Intelligence desativada nos Ajustes do Sistema.")
      case .deviceNotEligible:
        lines.append("Foundation Models: este Mac não é compatível.")
      case .modelNotReady:
        lines.append("Foundation Models: modelo do sistema ainda não está pronto.")
      @unknown default:
        lines.append("Foundation Models: indisponível por motivo do sistema.")
      }
    @unknown default:
      lines.append("Foundation Models: estado desconhecido do sistema.")
    }
    lines.append("Siri e Atalhos: ações públicas App Intents; nenhum serviço privado é utilizado.")
    return lines
  }
}
