import Foundation

// What the overlay says about the brain: the chip in the input bar, the label
// under an answer and the chip's menu. Kept here rather than in the views so
// the words and the mapping from a probe's rung to a dot are tested.
//
// The owner asked, 2026-10-16, "como eu sei quando é o Qwen e quando é o LLM
// local do Mac?" — the status line's "· no seu PC" was the only answer, and it
// shows only after an answer and only in the voice capsule.

// MARK: - Names

extension EvieModelProfile {
  /// The model as a person names it: "Qwen 3.8", "LensVLM".
  ///
  /// Derived from the id the server answers to rather than stored, so a
  /// profile whose model is edited in Settings is named for what it now runs,
  /// and an id nobody mapped is shown as itself — never as a guess.
  public var displayModelName: String {
    let label = displayName.trimmingCharacters(in: .whitespacesAndNewlines)
    if !label.isEmpty, label != "PC RTX 3090", label != "Mac local" { return label }
    return Self.displayModelName(forModel: model)
  }

  /// `qwen-daily` is the PC gateway's alias for the Qwen 3.8 model it keeps
  /// resident (the owner's name for it, 2026-10-16). Any LensVLM build is
  /// "LensVLM". Anything else is its id without the publisher:
  /// "mlx-community/Foo-9B" reads "Foo-9B".
  static func displayModelName(forModel model: String) -> String {
    let id = model.trimmingCharacters(in: .whitespacesAndNewlines)
    let lowered = id.lowercased()
    if lowered == "qwen-daily" {
      return "Qwen 3.8"
    }
    if lowered.contains("lensvlm") {
      return "LensVLM"
    }
    guard let name = id.split(separator: "/").last, !name.isEmpty else {
      return id
    }
    return String(name)
  }

  /// The chip: "Qwen 3.8 · PC".
  public var chipTitle: String {
    "\(displayModelName) · \(location.shortName)"
  }

  /// The quiet line on an answer card: "Qwen 3.8 · no seu PC".
  public var answerLabel: String {
    "\(displayModelName) · \(location.answerPlace)"
  }
}

extension ModelLocation {
  /// The place in two or three letters, for the chip.
  public var shortName: String {
    switch self {
    case .yourPC: "PC"
    case .thisMac: "Mac"
    }
  }

  /// The place as the end of a sentence: "no seu PC", "neste Mac".
  public var answerPlace: String {
    switch self {
    case .yourPC: "no seu PC"
    case .thisMac: "neste Mac"
    }
  }
}

// MARK: - The choice the menu makes

/// Which brain conversations start on, as the chip's menu offers it.
///
/// Not a second way of choosing a brain: `EvieBrainResolver.choose(_:)` takes
/// it and narrows the existing preference order to the chosen place, so
/// "Sempre o PC" is the order with the Mac left out and "Automático" is the
/// order as Settings saved it.
public enum EvieBrainChoice: String, CaseIterable, Codable, Sendable, Identifiable {
  case automatic
  case alwaysPC
  case alwaysMac

  public var id: String { rawValue }

  public var title: String {
    switch self {
    case .automatic: "Automático"
    case .alwaysPC: "Sempre o PC"
    case .alwaysMac: "Sempre o Mac"
    }
  }

  /// The one place this choice allows, or nil for any.
  public var location: ModelLocation? {
    switch self {
    case .automatic: nil
    case .alwaysPC: .yourPC
    case .alwaysMac: .thisMac
    }
  }

  public func allows(_ profile: EvieModelProfile) -> Bool {
    location.map { $0 == profile.location } ?? true
  }
}

// MARK: - The chip

/// What the chip's dot says.
public enum EvieBrainChipState: Sendable, Equatable {
  /// Not probed yet, or a "Testar conexão" in flight.
  case checking
  case ready
  /// It will answer, after a wait: the PC's model is not loaded, or the Mac
  /// brain is not running and starts on the first question.
  case cold
  /// The Mac brain is starting for a turn right now.
  case waking
  /// It cannot answer: out, its key missing or refused, or the model unknown.
  case unreachable

  public init(rung: ReadinessRung?, isWaking: Bool) {
    if isWaking {
      self = .waking
      return
    }
    switch rung {
    case nil: self = .checking
    case .ready: self = .ready
    case .modelCold: self = .cold
    case .unreachable, .keyMissing, .keyRejected, .modelUnknown: self = .unreachable
    }
  }
}

/// The chip in the overlay's input bar: which brain the next question goes
/// to, whether it can answer now, and whether agent mode is on.
public struct EvieBrainChip: Sendable, Equatable {
  /// The brain the conversation's next turn most likely runs on
  /// (`EvieBrainResolver.expectedProfile(for:)`).
  public var profile: EvieModelProfile
  /// What the key store or the probe last said, or nil before either has.
  public var rung: ReadinessRung?
  public var isWaking: Bool
  public var isAgentModeOn: Bool

  public init(
    profile: EvieModelProfile,
    rung: ReadinessRung? = nil,
    isWaking: Bool = false,
    isAgentModeOn: Bool = false
  ) {
    self.profile = profile
    self.rung = rung
    self.isWaking = isWaking
    self.isAgentModeOn = isAgentModeOn
  }

  public var title: String {
    profile.chipTitle
  }

  public var state: EvieBrainChipState {
    EvieBrainChipState(rung: rung, isWaking: isWaking)
  }

  /// Shown beside the brain while agent mode is on.
  public static let agentModeBadge = "modo agente ligado"

  /// The state in words, for the tooltip and VoiceOver.
  public var stateDescription: String {
    switch state {
    case .checking:
      return "verificando…"
    case .ready:
      return "pronto"
    case .waking:
      return "acordando…"
    case .cold:
      return profile.location == .yourPC
        ? "conectado; o modelo carrega na primeira pergunta"
        : "dormindo; acorda na primeira pergunta \(EvieBrainCopy.macWakeCost)"
    case .unreachable:
      return EvieBrainCopy.reasonSentence(passingOver: profile, because: rung ?? .unreachable)
    }
  }

  /// "Qwen 3.8 no seu PC: pronto. Modo agente ligado."
  public var accessibilityLabel: String {
    let brain = "\(profile.displayModelName) \(profile.location.answerPlace): \(stateDescription)"
    let sentence = brain.hasSuffix(".") ? brain : brain + "."
    return isAgentModeOn ? sentence + " Modo agente ligado." : sentence
  }

  /// What "Testar conexão" reports on the status line. A brain that cannot
  /// answer gets the reason, and where to fix a missing key.
  public var connectionSummary: String {
    switch state {
    case .unreachable:
      let fix =
        rung == .keyMissing && profile.location == .yourPC
        ? " Importe a chave em Configurações › Cérebro." : ""
      return stateDescription + fix
    case .checking, .ready, .cold, .waking:
      return "\(profile.displayModelName) \(profile.location.answerPlace): \(stateDescription)."
    }
  }
}

// MARK: - The chip's menu

/// The chip's menu, worked out from the profiles and the resolver's state.
public struct EvieBrainMenu: Sendable, Equatable {
  public struct Item: Sendable, Equatable, Identifiable {
    public let choice: EvieBrainChoice
    /// "Sempre o PC · Qwen 3.8".
    public let title: String
    public let isSelected: Bool
    /// False when there is no brain in that place to pin.
    public let isAvailable: Bool

    public var id: String { choice.id }
  }

  public let items: [Item]
  /// Said when the open conversation stays where it is although the choice
  /// now points elsewhere: a conversation never changes brain mid-thread.
  public let pinnedNote: String?
  /// "Raciocínio: Máximo", because thinking is what makes an answer slow.
  public let reasoningLine: String

  /// - Parameters:
  ///   - profiles: the set in use, in its preference order.
  ///   - choice: the resolver's current choice.
  ///   - pinned: the profile the open conversation is pinned to, if any.
  ///   - next: the profile a new conversation would start on under `choice`.
  public init(
    profiles: EvieModelProfileSet,
    choice: EvieBrainChoice,
    pinned: EvieModelProfile?,
    next: EvieModelProfile
  ) {
    let ordered = profiles.preferenceOrder.compactMap(profiles.profile(id:))
    items = EvieBrainChoice.allCases.map { option in
      let detail: String
      let available: Bool
      if let location = option.location {
        let first =
          ordered.first { $0.location == location }
          ?? profiles.profiles.first { $0.location == location }
        detail = first?.displayModelName ?? "indisponível"
        available = first != nil
      } else {
        var places: [String] = []
        for profile in ordered where !places.contains(profile.location.shortName) {
          places.append(profile.location.shortName)
        }
        detail = places.joined(separator: ", depois ")
        available = true
      }
      return Item(
        choice: option,
        title: detail.isEmpty ? option.title : "\(option.title) · \(detail)",
        isSelected: option == choice,
        isAvailable: available
      )
    }
    if let pinned, pinned.id != next.id {
      pinnedNote =
        "Esta conversa continua em \(pinned.chipTitle). A escolha vale a partir da próxima."
    } else {
      pinnedNote = nil
    }
    reasoningLine = "Raciocínio: \((pinned ?? next).defaultReasoning.title)"
  }
}
