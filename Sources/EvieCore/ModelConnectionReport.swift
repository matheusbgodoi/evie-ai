import Foundation

/// What "Testar conexão" shows: the readiness probe's steps, each with a mark
/// and the time its request took.
///
/// The steps are the probe's rungs read from the bottom: the machine answers,
/// the key is accepted, the model is loaded. A step after one that failed is
/// `notRun`, because the probe stops there — nothing is sent with a key that was
/// refused, and nothing is asked of a PC that did not answer.
public struct ModelConnectionReport: Sendable, Equatable {
  public enum Step: Sendable, Equatable, CaseIterable {
    case reachable
    case key
    case model
  }

  public enum Outcome: Sendable, Equatable {
    case passed
    case failed
    /// An earlier step failed, so this one was never asked.
    case notRun
    /// A loopback brain takes no key.
    case notNeeded
  }

  public struct Line: Sendable, Equatable {
    public let step: Step
    public let outcome: Outcome
    /// How long the request that settled this step took; `nil` when nothing was
    /// sent for it. Two steps settled by one answer — the key and the model,
    /// both read from `/v1/models` — show that request's time each.
    public let elapsed: Duration?

    public init(step: Step, outcome: Outcome, elapsed: Duration?) {
      self.step = step
      self.outcome = outcome
      self.elapsed = elapsed
    }
  }

  public let readiness: ModelReadiness
  /// One line per step, in `Step` order.
  public let lines: [Line]
  /// Every id the server's model list named, for the profile's model picker;
  /// empty when the list was not reached.
  public let availableModels: [String]

  public init(readiness: ModelReadiness, lines: [Line], availableModels: [String]) {
    self.readiness = readiness
    self.lines = lines
    self.availableModels = availableModels
  }

  public func line(_ step: Step) -> Line {
    lines.first { $0.step == step } ?? Line(step: step, outcome: .notRun, elapsed: nil)
  }
}

// MARK: - Copy

extension ModelConnectionReport {
  public func title(of step: Step, for profile: EvieModelProfile) -> String {
    switch step {
    case .reachable:
      profile.location == .yourPC ? "PC alcançável" : "Servidor do Mac rodando"
    case .key:
      "Chave aceita"
    case .model:
      "Modelo carregado"
    }
  }

  /// One sentence under the three lines: what the result means and what to do.
  public func summary(for profile: EvieModelProfile) -> String {
    let isPC = profile.location == .yourPC
    let subject = isPC ? "O PC" : profile.displayName
    switch readiness.rung {
    case .ready:
      return "Tudo certo: \(profile.model) está carregado."
    case .modelCold where line(.reachable).outcome == .failed:
      return "O cérebro do Mac não está rodando."
    case .modelCold:
      return "\(profile.model) está descarregado: a primeira pergunta espera ele carregar."
    case .keyMissing:
      return "Sem chave: cole a chave ou importe da configuração do PC."
    case .keyRejected:
      return "\(subject) recusou a chave salva. Cole ou importe a chave de novo."
    case .modelUnknown:
      return "\(subject) não tem o modelo \(profile.model). Escolha um da lista."
    case .unreachable:
      return isPC
        ? "O PC não respondeu. Ele está ligado e no Tailscale?"
        : "\(profile.location.noAnswer)."
    }
  }

  /// "37 ms" under a second, "1,2 s" above, as the pane shows each step's time.
  public static func formatted(_ duration: Duration) -> String {
    let (seconds, attoseconds) = duration.components
    let milliseconds = Double(seconds) * 1_000 + Double(attoseconds) / 1e15
    if milliseconds < 1 {
      return "<1 ms"
    }
    if milliseconds < 1_000 {
      return "\(Int(milliseconds.rounded())) ms"
    }
    let tenths = Int((milliseconds / 100).rounded())
    return "\(tenths / 10),\(tenths % 10) s"
  }
}

/// The probe's notes as it goes, turned into a report at whichever step it
/// stops.
struct ConnectionLog {
  private var outcomes: [ModelConnectionReport.Step: (ModelConnectionReport.Outcome, Duration?)] =
    [:]
  var availableModels: [String] = []

  mutating func record(
    _ step: ModelConnectionReport.Step,
    _ outcome: ModelConnectionReport.Outcome,
    after elapsed: Duration? = nil
  ) {
    outcomes[step] = (outcome, elapsed)
  }

  func report(_ rung: ReadinessRung) -> ModelConnectionReport {
    report(ModelReadiness(rung: rung))
  }

  func report(_ readiness: ModelReadiness) -> ModelConnectionReport {
    ModelConnectionReport(
      readiness: readiness,
      lines: ModelConnectionReport.Step.allCases.map { step in
        let (outcome, elapsed) = outcomes[step] ?? (.notRun, nil)
        return .init(step: step, outcome: outcome, elapsed: elapsed)
      },
      availableModels: availableModels
    )
  }
}
