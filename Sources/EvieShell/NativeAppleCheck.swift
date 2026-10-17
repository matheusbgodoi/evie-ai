import AppIntents
import EvieCore
import Foundation
import FoundationModels
import Security

/// Exercises the compiled native entry points with synthetic text.
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
      try await performOpen()
      throw Failure.check("Uma ação foi aceita antes de a interface estar pronta.")
    } catch NativeAppleError.notReady {}

    var received: [NativeAppleRequest] = []
    NativeAppleActions.handle = { received.append($0) }
    try await performOpen()
    try await performPrepare("  Pergunta sintética de integração.\n")
    try await performCapture()
    guard
      received == [
        .openConversation,
        .prepareQuestion("Pergunta sintética de integração."),
        captureRequest,
      ]
    else {
      throw Failure.check("As ações nativas não chegaram ao destino esperado.")
    }

    do {
      try await performPrepare(" \n ")
      throw Failure.check("Uma pergunta vazia foi aceita.")
    } catch NativeAppleError.emptyQuestion {}
    try await performPrepare(
      String(repeating: "á", count: EvieNativeURLRequest.maximumQuestionCharacters))
    do {
      try await performPrepare(
        String(repeating: "á", count: EvieNativeURLRequest.maximumQuestionCharacters + 1))
      throw Failure.check("Uma pergunta acima do limite foi aceita.")
    } catch NativeAppleError.questionTooLong {}
    guard received.count == 4 else {
      throw Failure.check("Uma pergunta inválida chegou à interface.")
    }

    NativeAppleActions.handle = { _ in throw NativeAppleError.busy }
    do {
      try await performOpen()
      throw Failure.check("Uma interface ocupada aceitou uma ação nativa.")
    } catch NativeAppleError.busy {}

    var lines = [
      "PASS: três entradas nativas encaminham as ações corretas sem enviar uma pergunta.",
      "PASS: início incompleto, interface ocupada, texto vazio e limite Unicode.",
      "Modo nativo: " + NativeAppleCapability.mode,
    ]
    if requireMetadata {
      guard
        Bundle.main.object(forInfoDictionaryKey: "EvieNativeAppleMode") as? String
          == NativeAppleCapability.mode
      else {
        throw Failure.check("O modo nativo compilado não corresponde ao bundle.")
      }
    }
    let metadata = Bundle.main.bundleURL
      .appendingPathComponent("Contents/Resources/Metadata.appintents/extract.actionsdata")
    #if EVIE_DIRECT_APP_INTENTS
      if requireMetadata {
        guard hasAppleDeveloperIdentity() else {
          throw Failure.check(
            "App Intents diretos exigem assinatura Apple com Team Identifier real.")
        }
        let raw = try Data(contentsOf: metadata)
        guard let document = try JSONSerialization.jsonObject(with: raw) as? [String: Any],
          let actions = document["actions"] as? [String: Any],
          Set(actions.keys)
            == Set(["OpenEvieIntent", "PrepareEvieQuestionIntent", "CaptureEvieScreenIntent"]),
          let shortcuts = document["autoShortcuts"] as? [Any], shortcuts.count == 3
        else { throw Failure.check("Os metadados não contêm as três ações e atalhos.") }
        lines.append("PASS: assinatura Apple e metadados de três App Intents diretos.")
      }
    #else
      guard !FileManager.default.fileExists(atPath: metadata.path) else {
        throw Failure.check("O modo URL publicou metadados de App Intents não suportados.")
      }
      if requireMetadata {
        let registrations =
          Bundle.main.object(forInfoDictionaryKey: "CFBundleURLTypes") as? [[String: Any]]
        guard
          registrations?.contains(where: { ($0["CFBundleURLSchemes"] as? [String]) == ["evie"] })
            == true
        else {
          throw Failure.check("O esquema público evie não está registrado no bundle.")
        }
      }
      lines.append(
        requireMetadata
          ? "PASS: URLs públicas registradas; captura exige confirmação; App Intents diretos desativados."
          : "PASS: rotas URL com revisão; App Intents diretos desativados; registro do bundle não solicitado."
      )
    #endif

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
    lines.append("Atalhos: APIs públicas; nenhum serviço privado da Siri é utilizado.")
    return lines
  }

  private static var captureRequest: NativeAppleRequest {
    #if EVIE_DIRECT_APP_INTENTS
      .captureScreen
    #else
      .requestCaptureConfirmation
    #endif
  }

  private static func performOpen() async throws {
    #if EVIE_DIRECT_APP_INTENTS
      _ = try await OpenEvieIntent().perform()
    #else
      try NativeAppleActions.perform(url: URL(string: "evie://open")!)
    #endif
  }

  private static func performPrepare(_ text: String) async throws {
    #if EVIE_DIRECT_APP_INTENTS
      let intent = PrepareEvieQuestionIntent()
      intent.question = text
      _ = try await intent.perform()
    #else
      var url = URLComponents(string: "evie://prepare")!
      url.queryItems = [URLQueryItem(name: "text", value: text)]
      do {
        try NativeAppleActions.perform(url: url.url!)
      } catch EvieNativeURLRequest.Problem.emptyQuestion {
        throw NativeAppleError.emptyQuestion
      } catch EvieNativeURLRequest.Problem.questionTooLong {
        throw NativeAppleError.questionTooLong
      }
    #endif
  }

  private static func performCapture() async throws {
    #if EVIE_DIRECT_APP_INTENTS
      _ = try await CaptureEvieScreenIntent().perform()
    #else
      try NativeAppleActions.perform(url: URL(string: "evie://capture")!)
    #endif
  }

  private static func hasAppleDeveloperIdentity() -> Bool {
    var code: SecStaticCode?
    var requirement: SecRequirement?
    guard SecStaticCodeCreateWithPath(Bundle.main.bundleURL as CFURL, [], &code) == errSecSuccess,
      let code,
      SecRequirementCreateWithString("anchor apple generic" as CFString, [], &requirement)
        == errSecSuccess,
      let requirement,
      SecStaticCodeCheckValidity(code, [], requirement) == errSecSuccess
    else { return false }
    var information: CFDictionary?
    guard
      SecCodeCopySigningInformation(
        code, SecCSFlags(rawValue: kSecCSSigningInformation), &information) == errSecSuccess,
      let dictionary = information as? [String: Any],
      let team = dictionary[kSecCodeInfoTeamIdentifier as String] as? String
    else { return false }
    return !team.isEmpty
  }

}
