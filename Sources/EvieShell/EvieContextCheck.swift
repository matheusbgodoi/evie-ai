import EvieCore
import Foundation

/// The model sees synthetic conversation only. Report counts and a semantic
/// fixture result, never endpoints, credentials, summaries or personal history.
enum EvieContextCheck {
  struct Report: Encodable {
    let success: Bool
    let originalCharacters: Int
    let preparedCharacters: Int
    let budget: Int
    let currentQuestionIntact: Bool
    let syntheticFactPreserved: Bool
    let cachedSecondRequest: Bool
    let error: String?
  }

  static func run() async -> Report {
    let budget = 32_768
    do {
      let loaded = try EvieConfigurationLoader().loadProfiles()
      guard let profile = loaded.profiles.profiles.first(where: { $0.location == .yourPC }) else {
        return Report(
          success: false, originalCharacters: 0, preparedCharacters: 0, budget: budget,
          currentQuestionIntact: false, syntheticFactPreserved: false,
          cachedSecondRequest: false,
          error: "Nenhum cérebro no PC está configurado para este teste.")
      }
      let client = ModelClientFactory.live.makeClient(configuration: profile.configuration)
      var history = [
        ChatMessage(role: .system, content: "Conversa sintética de validação de contexto.")
      ]
      for index in 0..<20 {
        history.append(
          ChatMessage(
            role: .user,
            content: (index == 0
              ? "A cor combinada para o projeto fictício Aurora é azul. "
              : "Etapa sintética \(index). ")
              + String(repeating: "Texto sintético de carga, sem novas decisões. ", count: 25)))
        history.append(
          ChatMessage(
            role: .assistant,
            content:
              "Entendido. "
              + String(repeating: "Registro sintético sem informações pessoais. ", count: 25)))
      }
      let question = ChatMessage(
        role: .user, content: "Qual foi a cor combinada no início para o projeto Aurora?")
      let compaction = EvieConversationCompaction()
      let prepared = try await compaction.prepare(
        history: history, tail: [question], budget: budget, client: client,
        targetID: "synthetic-context-check")
      let cached = try await compaction.prepare(
        history: history, tail: [question], budget: budget, client: client,
        targetID: "synthetic-context-check")
      let summary = prepared.messages.dropFirst().first?.content.lowercased() ?? ""
      let intact = prepared.messages.last == question
      let preserved = prepared.didCompact && summary.contains("azul") && summary.contains("aurora")
      let reused = cached.usage.usedCachedSummary && cached.messages == prepared.messages
      return Report(
        success: intact && preserved && reused && prepared.usage.preparedCharacters <= budget,
        originalCharacters: prepared.usage.originalCharacters,
        preparedCharacters: prepared.usage.preparedCharacters, budget: budget,
        currentQuestionIntact: intact, syntheticFactPreserved: preserved,
        cachedSecondRequest: reused, error: nil)
    } catch {
      return Report(
        success: false, originalCharacters: 0, preparedCharacters: 0, budget: budget,
        currentQuestionIntact: false, syntheticFactPreserved: false,
        cachedSecondRequest: false,
        error: (error as? EvieConversationCompaction.Problem)?.localizedDescription
          ?? "Não consegui validar a compactação com o cérebro configurado. Nenhum histórico pessoal foi usado."
      )
    }
  }
}
