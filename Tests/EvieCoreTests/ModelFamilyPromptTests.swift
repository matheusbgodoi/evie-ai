import Foundation
import Testing

@testable import EvieCore

/// What each model family's prompt looks like. Two corrections in this
/// codebase were measured on Gemma alone (`EvieBrevityPreamble`,
/// `EvieNearestTerm`), so they follow the profile's family; the skill guidance
/// takes the same `<system-context>` path whatever the family.
@Suite("Model family prompt shape")
struct ModelFamilyPromptTests {
  private static let brevityQuestion = "em uma frase, o que é a cluemed?"
  private static let askedAt = "sexta-feira, 16 de outubro de 2026, 21:30"

  // MARK: - The brevity reminder

  @Test("only Gemma is reminded that a short answer still means looking first")
  func brevityReminderIsGemmaOnly() {
    let gemma = EvieBrevityPreamble.annotated(Self.brevityQuestion, for: .gemma)
    #expect(gemma.hasPrefix(Self.brevityQuestion))
    #expect(gemma.contains("Procure primeiro"))

    for family in [ModelFamily.qwen, .unknown] {
      #expect(
        EvieBrevityPreamble.annotated(Self.brevityQuestion, for: family) == Self.brevityQuestion,
        "\(family) recebeu o lembrete"
      )
    }
  }

  @Test("each family's question carries the time it was asked, and Gemma's alone the reminder")
  func questionShapePerFamily() {
    let pc = EvieTurnPlan(profile: EvieModelProfile.builtInPC, readiness: .ready)
    let mac = EvieTurnPlan(profile: EvieModelProfile.builtInMac, readiness: .ready)
    let gemma = EvieTurnPlan(profile: Self.profile(family: .gemma), readiness: .ready)
    let unknown = EvieTurnPlan(profile: Self.profile(family: .unknown), readiness: .ready)
    let plain = "[\(Self.askedAt)] \(Self.brevityQuestion)"

    #expect(pc.profile.family == .qwen)
    #expect(mac.profile.family == .qwen)
    #expect(pc.question(Self.brevityQuestion, askedAt: Self.askedAt) == plain)
    #expect(mac.question(Self.brevityQuestion, askedAt: Self.askedAt) == plain)
    #expect(unknown.question(Self.brevityQuestion, askedAt: Self.askedAt) == plain)
    #expect(
      gemma.question(Self.brevityQuestion, askedAt: Self.askedAt)
        == plain + "\n\n" + EvieBrevityPreamble.reminder
    )
  }

  @Test("a question that asks for no short answer is the same on every family")
  func ordinaryQuestionIsUntouched() {
    for family in [ModelFamily.qwen, .gemma, .unknown] {
      let plan = EvieTurnPlan(profile: Self.profile(family: family), readiness: .ready)
      #expect(plan.question("o que é a cluemed?", askedAt: "agora") == "[agora] o que é a cluemed?")
    }
  }

  // MARK: - Skill guidance

  @Test("skill guidance reaches every family as <system-context> on the question")
  func skillGuidancePerFamily() throws {
    let persona = ChatMessage(role: .system, content: "Você é a Evie.")
    let guidance = ChatMessage(role: .system, content: "Siga a skill de resumo.")
    let question = ChatMessage(role: .user, content: "[agora] resume a reunião")

    for profile in Self.everyFamily {
      let guided = try Self.wireMessages([persona, guidance, question], on: profile)
      let unguided = try Self.wireMessages([persona, question], on: profile)

      #expect(guided.count == 2, "\(profile.id)")
      #expect(guided[0]["role"] as? String == "system", "\(profile.id)")
      // The prompt's first bytes do not depend on whether a skill matched.
      #expect(guided[0]["content"] as? String == unguided[0]["content"] as? String, "\(profile.id)")
      #expect(!guided.dropFirst().contains { $0["role"] as? String == "system" }, "\(profile.id)")
      #expect(
        guided[1]["content"] as? String
          == "<system-context>\nSiga a skill de resumo.\n</system-context>\n\n[agora] resume a reunião",
        "\(profile.id)"
      )
      #expect(unguided[1]["content"] as? String == "[agora] resume a reunião", "\(profile.id)")
    }
  }

  // MARK: - The near-miss search term

  @Test("a search in the person's own words keeps the near-miss retry")
  func personsSearchKeepsTheRetry() throws {
    let directory = try Self.notes()
    defer { try? FileManager.default.removeItem(at: directory) }
    let root = EvieFileRoot(id: "r1", displayName: "Obsidian", path: directory.path)
    let call = EvieToolCall(
      id: "grounding-r1",
      name: "search_content",
      argumentsJSON: #"{"root_id":"r1","query":"cluumed"}"#
    )

    let corrected = EvieFileToolbox().execute(call, roots: [root])
    let literal = EvieFileToolbox().execute(call, roots: [root], correctingNearMisses: false)

    #expect(corrected.content.contains("mas achei \"cluemed\""))
    #expect(literal.content.contains("Não achei \"cluumed\""))
  }

  @Test("the families the corrections were measured on")
  func familyFlags() {
    #expect(ModelFamily.gemma.needsBrevityReminder)
    #expect(ModelFamily.gemma.misspellsSearchTerms)
    for family in [ModelFamily.qwen, .unknown] {
      #expect(!family.needsBrevityReminder)
      #expect(!family.misspellsSearchTerms)
    }
  }
}

extension ModelFamilyPromptTests {
  fileprivate static var everyFamily: [EvieModelProfile] {
    [
      EvieModelProfile.builtInPC, EvieModelProfile.builtInMac,
      profile(family: .gemma), profile(family: .unknown),
    ]
  }

  fileprivate static func profile(family: ModelFamily) -> EvieModelProfile {
    EvieModelProfile(
      id: "custom",
      displayName: "Personalizado",
      endpoint: URL(string: "http://127.0.0.1:38433/v1")!,
      model: family == .gemma ? "gemma-4-26b-a4b-it" : "outro-modelo",
      contextTokens: 65_536,
      maxCompletionTokens: 4_096,
      capabilities: .init(vision: false, tools: true),
      thinkingStyle: .none,
      runtime: .remoteGateway,
      location: .thisMac,
      family: family,
      coordinateConvention: .pixels
    )
  }

  fileprivate static func wireMessages(
    _ messages: [ChatMessage],
    on profile: EvieModelProfile
  ) throws -> [[String: Any]] {
    let configuration = profile.configuration
    let request = try OpenAICompatibleClient.makeRequest(
      messages: messages,
      tools: [],
      options: .chat(configuration),
      configuration: configuration,
      bearerToken: nil
    )
    let body = try #require(request.httpBody)
    let json = try #require(try JSONSerialization.jsonObject(with: body) as? [String: Any])
    return try #require(json["messages"] as? [[String: Any]])
  }

  /// A note that names the company the way it is spelt.
  fileprivate static func notes() throws -> URL {
    let directory = FileManager.default.temporaryDirectory
      .appendingPathComponent("evie-family-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    try Data("A Cluemed é o cofre de saúde do paciente.\n".utf8)
      .write(to: directory.appendingPathComponent("cluemed.md"))
    return directory
  }
}
