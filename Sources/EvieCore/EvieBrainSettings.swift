import Foundation

// What the "Cérebro" settings tab shows and edits, kept here rather than in the
// view model so the copy and the rules are tested: which words name each brain,
// how a typed value becomes a profile, and how the endpoint field is checked.

// MARK: - Per-profile copy

extension ModelLocation {
  /// "Onde roda", as the tab says it.
  public var placeDescription: String {
    switch self {
    case .yourPC: "No seu PC, pela sua rede Tailscale (criptografada)"
    case .thisMac: "Somente neste Mac"
    }
  }

  /// The end of the status line under an answer: "1 234 tokens · no seu PC".
  /// It replaced "somente local", which stopped being true the day the PC
  /// became the default brain.
  public var statusTag: String {
    switch self {
    case .yourPC: "no seu PC"
    case .thisMac: "somente neste Mac"
    }
  }

  /// Who did not answer, when a turn fails.
  public var noAnswer: String {
    switch self {
    case .yourPC: "O PC não respondeu"
    case .thisMac: "O cérebro do Mac não respondeu"
    }
  }

  /// What the error card suggests: the tab where the connection can be tested.
  public var failureRecovery: String {
    "\(noAnswer). Abra Configurações › Cérebro e use Testar conexão."
  }
}

extension EvieModelProfile {
  /// "servidor: 200 704 · Evie usa: 135 168": what the server holds, for
  /// reference, and the cap the budget is built on, which the tab edits.
  public var contextLine: String {
    let used = "Evie usa: \(Self.grouped(contextTokens))"
    guard let serverContextTokens else {
      return used
    }
    return "servidor: \(Self.grouped(serverContextTokens)) · \(used)"
  }

  /// Digits in threes, joined by a no-break space so a figure never wraps: the
  /// spacing the spec writes, and one a Portuguese reader cannot mistake for a
  /// decimal point.
  static func grouped(_ value: Int) -> String {
    let digits = Array(String(value.magnitude))
    var groups: [String] = []
    var end = digits.count
    while end > 0 {
      let start = max(0, end - 3)
      groups.insert(String(digits[start..<end]), at: 0)
      end = start
    }
    return (value < 0 ? "-" : "") + groups.joined(separator: "\u{A0}")
  }
}

extension ReasoningLevel {
  public var title: String {
    switch self {
    case .off: "Desligado"
    case .low: "Baixo"
    case .medium: "Médio"
    case .xhigh: "Máximo"
    }
  }
}

extension MacFallback {
  /// The choices under "Quando o PC estiver fora".
  public var title: String {
    switch self {
    case .off: "Não usar o Mac"
    case .ask: "Perguntar"
    case .automatic: "Usar o Mac automaticamente"
    }
  }
}

extension EvieModelProfileSet {
  /// The set with `id` first in the preference order and every other profile
  /// that was in it after, in the order they had. A profile the order did not
  /// name — a migrated `custom` — joins it at the front.
  public func preferring(_ id: String) -> EvieModelProfileSet {
    var copy = self
    copy.preferenceOrder = [id] + preferenceOrder.filter { $0 != id }
    return copy
  }
}

// MARK: - Fields the environment holds

/// A profile field an `EVIE_MODEL_*` variable can override for one run. The
/// tab shows such a field locked, and a save leaves the file's value alone: a
/// variable set for one launch must not end up in the file.
public enum EvieManagedField: String, Sendable, CaseIterable {
  case endpoint = "EVIE_MODEL_ENDPOINT"
  case model = "EVIE_MODEL_NAME"
  case contextTokens = "EVIE_MODEL_CONTEXT"
  case maxCompletionTokens = "EVIE_MODEL_MAX_COMPLETION"
  case temperature = "EVIE_MODEL_TEMPERATURE"
  case topP = "EVIE_MODEL_TOP_P"
  case requestTimeout = "EVIE_MODEL_TIMEOUT_SECONDS"

  /// The fields the loader overrode from `environment`, which apply to the
  /// profile in use only.
  public static func managed(by environment: [String: String]) -> Set<EvieManagedField> {
    Set(allCases.filter { environment[$0.rawValue] != nil })
  }
}

// MARK: - Drafts

/// One profile's fields as the tab edits them: text where a person types, the
/// sampling switches as the pane draws them. `applied(to:)` turns it back into a
/// profile, and refuses what the profile could not run with.
///
/// Only what the tab shows is here. The key reference, capabilities, runtime and
/// location are not editable: the reference names where the key is kept and the
/// host it is bound to, and the rest describe what the server is.
public struct EvieProfileDraft: Sendable, Equatable {
  public let profileID: String
  public var endpoint: String
  public var model: String
  public var contextTokens: Int
  public var maxCompletionTokens: Int
  public var defaultReasoning: ReasoningLevel
  public var usesServerTemperature: Bool
  public var temperature: Double
  public var usesServerTopP: Bool
  public var topP: Double
  public var requestTimeout: TimeInterval

  /// The sampling Evie recommends when a value is fixed rather than left to
  /// the server: what the pane has always offered.
  public static let recommendedTemperature = 0.2
  public static let recommendedTopP = 0.95

  public init(_ profile: EvieModelProfile) {
    profileID = profile.id
    endpoint = profile.endpoint.absoluteString
    model = profile.model
    contextTokens = profile.contextTokens
    maxCompletionTokens = profile.maxCompletionTokens
    defaultReasoning = profile.defaultReasoning
    usesServerTemperature = profile.temperature == nil
    temperature = profile.temperature ?? Self.recommendedTemperature
    usesServerTopP = profile.topP == nil
    topP = profile.topP ?? Self.recommendedTopP
    requestTimeout = profile.requestTimeout
  }

  /// `profile` with this draft's values, except the `managed` fields, which keep
  /// the profile's own.
  public func applied(
    to profile: EvieModelProfile,
    keeping managed: Set<EvieManagedField> = []
  ) throws -> EvieModelProfile {
    var edited = profile
    if !managed.contains(.endpoint) {
      guard let url = parsedEndpoint else {
        throw Problem.invalidEndpoint
      }
      edited.endpoint = url
    }
    if !managed.contains(.model) {
      edited.model = model.trimmingCharacters(in: .whitespacesAndNewlines)
    }
    if !managed.contains(.contextTokens) {
      edited.contextTokens = contextTokens
    }
    if !managed.contains(.maxCompletionTokens) {
      edited.maxCompletionTokens = maxCompletionTokens
    }
    edited.defaultReasoning = defaultReasoning
    if !managed.contains(.temperature) {
      edited.temperature = usesServerTemperature ? nil : temperature
    }
    if !managed.contains(.topP) {
      edited.topP = usesServerTopP ? nil : topP
    }
    if !managed.contains(.requestTimeout) {
      edited.requestTimeout = requestTimeout
    }
    do {
      try edited.configuration.validate()
    } catch let reason as EvieConfiguration.ValidationError {
      throw Problem(reason)
    }
    return edited
  }

  /// What the transport policy would say about this endpoint with `credential`,
  /// in Portuguese, or nil when it would send to it. Checked as the field is
  /// typed, so a refused address is explained before it is saved rather than on
  /// the next question.
  public func endpointProblem(
    credential: CredentialReference?,
    policy: ModelTransportPolicy
  ) -> String? {
    guard let url = parsedEndpoint else {
      return Problem.invalidEndpoint.errorDescription
    }
    let chat = EvieConfiguration(endpoint: url).chatCompletionsURL
    return policy.refusal(of: chat, credentialHost: credential?.boundHost)?.explanation
  }

  /// The typed endpoint as a URL with a scheme and a host, or nil.
  private var parsedEndpoint: URL? {
    let text = endpoint.trimmingCharacters(in: .whitespacesAndNewlines)
    guard let url = URL(string: text), url.scheme != nil, url.host != nil else {
      return nil
    }
    return url
  }

  /// Why a draft cannot become a profile, as the tab says it.
  public enum Problem: Error, Sendable, Equatable {
    case invalidEndpoint
    case emptyModel
    case invalidContext
    case outputOverContext
    case invalidTemperature
    case invalidTopP
    case invalidTimeout

    init(_ reason: EvieConfiguration.ValidationError) {
      switch reason {
      case .invalidEndpoint: self = .invalidEndpoint
      case .emptyModel: self = .emptyModel
      case .invalidContextWindow: self = .invalidContext
      case .invalidCompletionLimit: self = .outputOverContext
      case .invalidTemperature: self = .invalidTemperature
      case .invalidTopP: self = .invalidTopP
      case .invalidTimeout: self = .invalidTimeout
      }
    }
  }
}

extension EvieProfileDraft.Problem: LocalizedError {
  public var errorDescription: String? {
    switch self {
    case .invalidEndpoint:
      "Isso não é um endereço. Use algo como https://servidor/v1."
    case .emptyModel:
      "Escolha ou escreva o nome do modelo."
    case .invalidContext:
      "O contexto precisa ter pelo menos um token."
    case .outputOverContext:
      "A resposta máxima não pode passar do contexto que a Evie usa."
    case .invalidTemperature:
      "A temperatura vai de 0 a 2."
    case .invalidTopP:
      "O top-p vai de 0 (sem incluir) a 1."
    case .invalidTimeout:
      "O tempo limite precisa ser maior que zero."
    }
  }
}
