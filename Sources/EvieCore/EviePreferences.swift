import CoreGraphics
import Foundation

/// Every Evie behaviour the user can configure without touching a credential.
///
/// Model sampling stays in `EvieConfiguration` so the two files can be written
/// independently: changing a shortcut must never rewrite the inference settings.
public struct EviePreferences: Codable, Hashable, Sendable {
  public var appearance: EvieAppearancePreferences
  public var shortcuts: EvieShortcutPreferences
  public var voice: EvieVoicePreferences

  public init(
    appearance: EvieAppearancePreferences = EvieAppearancePreferences(),
    shortcuts: EvieShortcutPreferences = EvieShortcutPreferences(),
    voice: EvieVoicePreferences = EvieVoicePreferences()
  ) {
    self.appearance = appearance
    self.shortcuts = shortcuts
    self.voice = voice
  }

  public func validate() throws {
    try appearance.validate()
    try shortcuts.validate()
    try voice.validate()
  }

  public enum ValidationError: Error, Equatable, Sendable {
    case invalidOverlayWidth
    case callModeRequiresSpeechOutput
    case emptyWakePhrase
    case conflictingShortcuts([EvieShortcutConflict])
    case unsafeShortcut(EvieShortcutAction)
  }
}

extension EviePreferences.ValidationError: LocalizedError {
  public var errorDescription: String? {
    switch self {
    case .invalidOverlayWidth:
      "A largura da janela precisa ficar entre "
        + "\(Int(EvieAppearancePreferences.minimumOverlayWidth)) e "
        + "\(Int(EvieAppearancePreferences.maximumOverlayWidth)) pontos."
    case .callModeRequiresSpeechOutput:
      "O modo ligação só existe com a fala da Evie ligada. "
        + "Desligue o modo ligação antes de deixá-la apenas em texto."
    case .emptyWakePhrase:
      "A frase de ativação não pode ficar em branco."
    case .conflictingShortcuts(let conflicts):
      "Atalhos repetidos: "
        + conflicts
        .map { conflict in
          conflict.actions.map(\.title).joined(separator: " e ")
            + " usam \(conflict.shortcut.displayString)"
        }
        .joined(separator: "; ")
        + "."
    case .unsafeShortcut(let action):
      "O atalho de \(action.title) precisa de ⌘, ⌥ ou ⌃."
    }
  }
}

// MARK: - Appearance

/// Where the overlay sits and how wide it is.
///
/// `overlayOrigin` is stored in AppKit screen coordinates. It is only a hint:
/// the shell re-validates it against the connected displays at launch and falls
/// back to the anchored default when the saved position is no longer reachable.
public struct EvieAppearancePreferences: Codable, Hashable, Sendable {
  public static let defaultOverlayWidth: CGFloat = 576
  public static let minimumOverlayWidth: CGFloat = 420
  public static let maximumOverlayWidth: CGFloat = 1_200

  public var overlayWidth: CGFloat
  public var overlayOrigin: EvieOverlayOrigin?
  public var animatesLogo: Bool

  public init(
    overlayWidth: CGFloat = EvieAppearancePreferences.defaultOverlayWidth,
    overlayOrigin: EvieOverlayOrigin? = nil,
    animatesLogo: Bool = true
  ) {
    self.overlayWidth = overlayWidth
    self.overlayOrigin = overlayOrigin
    self.animatesLogo = animatesLogo
  }

  /// The width actually used for layout, clamped so a damaged or hand-edited
  /// file can never render an unusable overlay.
  public var resolvedOverlayWidth: CGFloat {
    min(max(overlayWidth, Self.minimumOverlayWidth), Self.maximumOverlayWidth)
  }

  public var isUsingDefaultPlacement: Bool {
    overlayOrigin == nil && overlayWidth == Self.defaultOverlayWidth
  }

  /// Returns the overlay to the bottom-centred anchor at its original width.
  public mutating func resetPlacement() {
    overlayOrigin = nil
    overlayWidth = Self.defaultOverlayWidth
  }

  public func validate() throws {
    guard overlayWidth.isFinite,
      overlayWidth >= Self.minimumOverlayWidth,
      overlayWidth <= Self.maximumOverlayWidth
    else {
      throw EviePreferences.ValidationError.invalidOverlayWidth
    }
  }
}

public struct EvieOverlayOrigin: Codable, Hashable, Sendable {
  public var x: CGFloat
  public var y: CGFloat

  public init(x: CGFloat, y: CGFloat) {
    self.x = x
    self.y = y
  }
}

// MARK: - Shortcuts

/// Every action that can be reached from a global key combination.
public enum EvieShortcutAction: String, CaseIterable, Codable, Sendable {
  case toggleOverlay
  case quickText
  case pushToTalk
  case toggleCallMode
  case newConversation
  case openHistory
  case openSettings
  case emergencyStop

  public var title: String {
    switch self {
    case .toggleOverlay: "Mostrar ou ocultar a Evie"
    case .quickText: "Escrever para a Evie"
    case .pushToTalk: "Falar (segurar para gravar)"
    case .toggleCallMode: "Entrar ou sair do modo ligação"
    case .newConversation: "Nova conversa"
    case .openHistory: "Abrir o histórico"
    case .openSettings: "Abrir as configurações"
    case .emergencyStop: "Parar tudo agora"
    }
  }

  public var details: String {
    switch self {
    case .toggleOverlay:
      "Traz a Evie para a frente já pronta para digitar, ou a esconde."
    case .quickText:
      "Abre o campo de texto sem mexer no estado de voz."
    case .pushToTalk:
      "Enquanto a tecla estiver pressionada o microfone fica aberto."
    case .toggleCallMode:
      "Alterna entre a conversa escrita e a conversa por voz contínua."
    case .newConversation:
      "Começa uma conversa vazia sem apagar o histórico anterior."
    case .openHistory:
      "Abre a janela com as conversas salvas somente neste Mac."
    case .openSettings:
      "Abre esta janela de configurações."
    case .emergencyStop:
      "Cancela a resposta, corta o áudio e fecha o microfone imediatamente."
    }
  }

  public var defaultShortcut: EvieShortcut {
    switch self {
    case .toggleOverlay: EvieShortcut(keyCode: 49, modifiers: [.option])
    case .quickText: EvieShortcut(keyCode: 49, modifiers: [.option, .shift])
    case .pushToTalk: EvieShortcut(keyCode: 9, modifiers: [.option])
    case .toggleCallMode: EvieShortcut(keyCode: 8, modifiers: [.option, .shift])
    case .newConversation: EvieShortcut(keyCode: 45, modifiers: [.option, .shift])
    case .openHistory: EvieShortcut(keyCode: 4, modifiers: [.option, .shift])
    case .openSettings: EvieShortcut(keyCode: 43, modifiers: [.option, .shift])
    case .emergencyStop: EvieShortcut(keyCode: 53, modifiers: [.option, .shift])
    }
  }

  /// Push-to-talk is the only action that reacts to key release as well, so the
  /// shell has to register it for both event kinds.
  public var isHoldToActivate: Bool {
    self == .pushToTalk
  }
}

public struct EvieShortcutConflict: Hashable, Sendable {
  public let shortcut: EvieShortcut
  public let actions: [EvieShortcutAction]

  public init(shortcut: EvieShortcut, actions: [EvieShortcutAction]) {
    self.shortcut = shortcut
    self.actions = actions
  }
}

/// Resolved bindings for every action.
///
/// The persisted document only records deviations: an omitted action keeps its
/// documented default, and an explicit `null` means the user turned it off.
public struct EvieShortcutPreferences: Hashable, Sendable {
  private var overrides: [EvieShortcutAction: EvieShortcut]
  private var disabledActions: Set<EvieShortcutAction>

  public init() {
    overrides = [:]
    disabledActions = []
  }

  public func shortcut(for action: EvieShortcutAction) -> EvieShortcut? {
    guard !disabledActions.contains(action) else {
      return nil
    }
    return overrides[action] ?? action.defaultShortcut
  }

  public func isDisabled(_ action: EvieShortcutAction) -> Bool {
    disabledActions.contains(action)
  }

  public func isUsingDefault(_ action: EvieShortcutAction) -> Bool {
    overrides[action] == nil && !disabledActions.contains(action)
  }

  public var isUsingDefaults: Bool {
    overrides.isEmpty && disabledActions.isEmpty
  }

  public mutating func setShortcut(_ shortcut: EvieShortcut, for action: EvieShortcutAction) {
    overrides[action] = shortcut
    disabledActions.remove(action)
  }

  public mutating func disable(_ action: EvieShortcutAction) {
    overrides.removeValue(forKey: action)
    disabledActions.insert(action)
  }

  public mutating func reset(_ action: EvieShortcutAction) {
    overrides.removeValue(forKey: action)
    disabledActions.remove(action)
  }

  public mutating func resetAll() {
    overrides.removeAll()
    disabledActions.removeAll()
  }

  /// Every key combination claimed by more than one action, in declaration order
  /// so the message the user reads is stable between launches.
  public func conflicts() -> [EvieShortcutConflict] {
    var owners: [EvieShortcut: [EvieShortcutAction]] = [:]
    for action in EvieShortcutAction.allCases {
      guard let shortcut = shortcut(for: action) else {
        continue
      }
      owners[shortcut, default: []].append(action)
    }

    return
      owners
      .filter { $0.value.count > 1 }
      .map { EvieShortcutConflict(shortcut: $0.key, actions: $0.value) }
      .sorted { left, right in
        let leftIndex = EvieShortcutAction.allCases.firstIndex(of: left.actions[0]) ?? 0
        let rightIndex = EvieShortcutAction.allCases.firstIndex(of: right.actions[0]) ?? 0
        return leftIndex < rightIndex
      }
  }

  public func validate() throws {
    for action in EvieShortcutAction.allCases {
      guard let shortcut = shortcut(for: action) else {
        continue
      }
      do {
        try shortcut.validate()
      } catch {
        throw EviePreferences.ValidationError.unsafeShortcut(action)
      }
    }

    let conflicts = conflicts()
    guard conflicts.isEmpty else {
      throw EviePreferences.ValidationError.conflictingShortcuts(conflicts)
    }
  }
}

extension EvieShortcutPreferences: Codable {
  public init(from decoder: any Decoder) throws {
    self.init()
    let container = try decoder.container(keyedBy: ActionKey.self)
    for key in container.allKeys {
      guard let action = EvieShortcutAction(rawValue: key.stringValue) else {
        continue
      }
      if try container.decodeNil(forKey: key) {
        disabledActions.insert(action)
      } else {
        overrides[action] = try container.decode(EvieShortcut.self, forKey: key)
      }
    }
  }

  public func encode(to encoder: any Encoder) throws {
    var container = encoder.container(keyedBy: ActionKey.self)
    for action in EvieShortcutAction.allCases {
      let key = ActionKey(stringValue: action.rawValue)
      if disabledActions.contains(action) {
        try container.encodeNil(forKey: key)
      } else if let shortcut = overrides[action] {
        try container.encode(shortcut, forKey: key)
      }
    }
  }

  fileprivate struct ActionKey: CodingKey {
    let stringValue: String
    var intValue: Int? { nil }

    init(stringValue: String) {
      self.stringValue = stringValue
    }

    init?(intValue: Int) {
      return nil
    }
  }
}

// MARK: - Voice

/// How a turn is presented once voice exists.
public enum EvieVoicePresentation: String, Hashable, Sendable {
  /// Everything stays written, even when the question arrived by microphone.
  case textOnly
  /// The transcript and the answer appear as cards and Evie also speaks.
  case textAndSpeech
  /// Only the animated mark and its waves; nothing is written on screen.
  case call
}

public struct EvieVoicePreferences: Codable, Hashable, Sendable {
  public static let defaultWakePhrase = "Ei, Evie"

  public var wakeWordEnabled: Bool
  public var wakePhrase: String
  public var pushToTalkEnabled: Bool
  /// Whether Evie answers out loud at all.
  public var speechOutputEnabled: Bool
  /// Whether she also reads out an answer to something that was typed.
  ///
  /// Off by default, and the default is the point: speaking back to a question
  /// you spoke is a conversation, speaking back to a question you typed is an
  /// interruption. Answering out loud follows the way the question was asked
  /// unless this says otherwise.
  public var speaksTypedAnswers: Bool
  /// Whether a voice turn hides the written transcript entirely.
  public var callModeEnabled: Bool
  public var retainsRawAudio: Bool
  public var voiceProfileAlias: String?
  /// Which installed system voice she speaks with. `nil` means the best one.
  public var voiceIdentifier: String?
  /// A cloned voice from the local voice engine. When set, and the engine is
  /// running, it wins over the system voice.
  public var clonedVoiceID: String?
  /// System voices removed from the picker.
  ///
  /// macOS voices cannot be uninstalled by an application, and most of them are
  /// audibly synthetic. Hiding is the honest version of removing: they stop being
  /// offered, the list becomes the voices actually worth choosing, and nothing
  /// pretends to have deleted a file belonging to the operating system.
  public var hiddenVoiceIdentifiers: Set<String>
  /// `AVSpeechUtterance` rate, where 0.5 is the system default.
  public var speechRate: Double

  public init(
    wakeWordEnabled: Bool = false,
    wakePhrase: String = EvieVoicePreferences.defaultWakePhrase,
    pushToTalkEnabled: Bool = true,
    speechOutputEnabled: Bool = true,
    speaksTypedAnswers: Bool = false,
    callModeEnabled: Bool = false,
    retainsRawAudio: Bool = false,
    voiceProfileAlias: String? = nil,
    voiceIdentifier: String? = nil,
    clonedVoiceID: String? = nil,
    hiddenVoiceIdentifiers: Set<String> = [],
    speechRate: Double = 0.5
  ) {
    self.wakeWordEnabled = wakeWordEnabled
    self.wakePhrase = wakePhrase
    self.pushToTalkEnabled = pushToTalkEnabled
    self.speechOutputEnabled = speechOutputEnabled
    self.speaksTypedAnswers = speaksTypedAnswers
    self.callModeEnabled = callModeEnabled
    self.retainsRawAudio = retainsRawAudio
    self.voiceProfileAlias = voiceProfileAlias
    self.voiceIdentifier = voiceIdentifier
    self.clonedVoiceID = clonedVoiceID
    self.hiddenVoiceIdentifiers = hiddenVoiceIdentifiers
    self.speechRate = speechRate
  }

  /// Hides a voice, and stops using it if it was the one selected.
  public mutating func hideVoice(identifier: String) {
    hiddenVoiceIdentifiers.insert(identifier)
    if voiceIdentifier == identifier {
      voiceIdentifier = nil
    }
  }

  public mutating func showVoice(identifier: String) {
    hiddenVoiceIdentifiers.remove(identifier)
  }

  /// Whether this answer should be read out, given how the question arrived.
  ///
  /// A call always speaks — that is what a call is — regardless of how the words
  /// were captured.
  public func speaksAnswer(toSpokenPrompt wasSpoken: Bool, inCall: Bool = false) -> Bool {
    guard speechOutputEnabled else {
      return false
    }
    return inCall || wasSpoken || speaksTypedAnswers
  }

  /// Clamped so a hand-edited file cannot produce speech nobody can follow.
  public var resolvedSpeechRate: Double {
    min(max(speechRate, 0.3), 0.75)
  }

  public var presentation: EvieVoicePresentation {
    if callModeEnabled {
      return .call
    }
    return speechOutputEnabled ? .textAndSpeech : .textOnly
  }

  /// Silencing Evie also leaves the call: a call with no voice is just a blank
  /// circle, so the two switches are changed together rather than trapping the
  /// user in an unusable state.
  public mutating func setSpeechOutputEnabled(_ enabled: Bool) {
    speechOutputEnabled = enabled
    if !enabled {
      callModeEnabled = false
      // Nothing speaks, so "also speak typed answers" would be a switch that
      // says something untrue about what will happen.
      speaksTypedAnswers = false
    }
  }

  public mutating func setCallModeEnabled(_ enabled: Bool) {
    callModeEnabled = enabled
    if enabled {
      speechOutputEnabled = true
    }
  }

  public func validate() throws {
    guard !callModeEnabled || speechOutputEnabled else {
      throw EviePreferences.ValidationError.callModeRequiresSpeechOutput
    }
    guard
      !wakeWordEnabled
        || !wakePhrase.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    else {
      throw EviePreferences.ValidationError.emptyWakePhrase
    }
  }
}
