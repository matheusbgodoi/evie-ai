import Foundation

public enum EvieResearchDestination: String, CaseIterable, Sendable {
  case clipboard
  case controlMac

  public var title: String {
    switch self {
    case .clipboard: "Copiar a resposta"
    case .controlMac: "Preencher ou selecionar no Mac"
    }
  }
}

/// Ephemeral authority for the two research shortcuts. It is never serialized
/// and never rearmed by launching the app. Each asynchronous run needs its own
/// lease, rechecked before delivering a result.
public struct EvieResearchSession: Sendable {
  public static let lifetime: TimeInterval = 15 * 60
  public static let defaultGoal =
    "Interprete a questão ou tarefa principal visível na tela e resolva-a. "
    + "Se houver ambiguidade ou faltar informação, explique o que falta em vez de adivinhar."

  public struct Run: Sendable, Equatable {
    public let id: UUID
    public let goal: String
    public let destination: EvieResearchDestination
    public let expiresAt: Date
    fileprivate let sessionID: UUID
  }

  public private(set) var expiresAt: Date?
  private var sessionID: UUID?
  private var goal = ""
  private var destination = EvieResearchDestination.clipboard
  private var activeRun: UUID?

  public init() {}

  public func isArmed(now: Date = Date()) -> Bool {
    sessionID != nil && expiresAt.map { now < $0 } == true
  }

  public mutating func arm(
    goal: String, destination: EvieResearchDestination, now: Date = Date()
  ) throws {
    let goal = goal.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !goal.isEmpty, goal.count <= 1_200 else { throw EvieResearchError.invalidGoal }
    self.goal = goal
    self.destination = destination
    sessionID = UUID()
    expiresAt = now.addingTimeInterval(Self.lifetime)
    activeRun = nil
  }

  public mutating func begin(now: Date = Date()) throws -> Run {
    guard isArmed(now: now), let sessionID, let expiresAt else { throw EvieResearchError.notArmed }
    guard activeRun == nil else { throw EvieResearchError.busy }
    let run = Run(
      id: UUID(), goal: goal, destination: destination, expiresAt: expiresAt, sessionID: sessionID)
    activeRun = run.id
    return run
  }

  public func allows(_ run: Run, now: Date = Date()) -> Bool {
    isArmed(now: now) && sessionID == run.sessionID && activeRun == run.id
  }

  public mutating func finish(_ run: Run) {
    guard sessionID == run.sessionID, activeRun == run.id else { return }
    activeRun = nil
  }

  public mutating func disarm() {
    sessionID = nil
    expiresAt = nil
    activeRun = nil
  }
}

public enum EvieResearchError: Error, Equatable, Sendable, LocalizedError {
  case notArmed, busy, invalidGoal, invalidAnswer, clipboardChanged, clipboardWriteFailed
  case visionUnavailable
  case unavailable(String)

  public var errorDescription: String? {
    switch self {
    case .notArmed: "Ative uma sessão de pesquisa antes de executar."
    case .busy: "Aguarde a tarefa atual ou use Parar tudo."
    case .invalidGoal: "Descreva o objetivo em 1 a 1.200 caracteres."
    case .invalidAnswer: "O cérebro não devolveu uma resposta completa e válida. Nada foi copiado."
    case .clipboardChanged:
      "Você copiou algo durante a análise. Preservei seu clipboard; execute novamente para tentar."
    case .clipboardWriteFailed: "Não consegui escrever a resposta na área de transferência."
    case .visionUnavailable: "O cérebro selecionado não lê imagens. Escolha o PC ou LensVLM."
    case .unavailable(let reason): reason
    }
  }
}
