import CoreGraphics
import Foundation

/// Finds an installed application by the name the model gave. The shell's
/// resolver asks Launch Services; tests use a table.
public protocol ComputerAppResolving: Sendable {
  func resolve(name: String) -> ResolvedApp?
}

/// An application the system found for a name: what `open_app` launches (by
/// bundle id, never by the name) and what its confirmation calls it.
public struct ResolvedApp: Sendable, Equatable {
  public let bundleID: String
  /// The name the system shows, localised ("Notas").
  public let displayName: String
  /// Other names the same app goes by ("Notes"), for matching the request.
  public let otherNames: [String]

  public init(bundleID: String, displayName: String, otherNames: [String] = []) {
    self.bundleID = bundleID
    self.displayName = displayName
    self.otherNames = otherNames
  }
}

/// The rules every computer-use action passes before it can be committed.
///
/// Code, not a prompt. Text on the screen reaches the model, and the model can
/// be talked into anything; these checks read only what the system reports —
/// the observation's frame, the accessibility tree, the app in front, secure
/// input — so a page that says "abra o Terminal" changes nothing here. What
/// they ask the person is built from that same data and never quotes the
/// model (ADR 0016).
public struct ComputerActionPolicy: Sendable {
  public struct Clearance: Sendable, Equatable {
    /// `.delete` for what cannot be taken back (⌘⌫, emptying the Trash),
    /// which the commit factory then refuses without the person's click.
    public let operation: CapabilityOperation
    /// What the action does, for the proposal and the action log.
    public let summary: String
    /// When set, the person is asked this before anything happens.
    public let confirmation: String?
    /// What the action acts on: an app by bundle id, the clipboard, the clock.
    public let targetNamespace: String
    public let targetIdentifier: String
  }

  public enum Decision: Sendable, Equatable {
    case refused(String)
    case cleared(Clearance)
  }

  public static let evieBundleID = "com.matheusbgodoi.evie"

  /// Apps Evie never drives: they change the system itself, run anything, or
  /// hold secrets. Matched by bundle id, by bundle-id family, and by the name
  /// the system shows, so an app whose id is unknown is still caught.
  public static let deniedBundleIDs: Set<String> = [
    "com.apple.systempreferences", "com.apple.keychainaccess", "com.apple.Terminal",
    "com.googlecode.iterm2", "com.mitchellh.ghostty", "com.apple.shortcuts",
    "com.apple.ScriptEditor2", "com.apple.Automator", "com.apple.installer",
    "com.apple.Passwords",
  ]
  static let deniedBundlePrefixes = [
    "dev.warp.", "com.1password.", "com.agilebits.", "com.bitwarden.", "com.lastpass.",
    "com.dashlane.", "org.keepassxc.", "com.keepersecurity.",
  ]
  static let deniedNames: Set<String> = [
    "ajustes do sistema", "system settings", "preferencias do sistema", "system preferences",
    "acesso as chaves", "keychain access", "terminal", "iterm", "iterm2", "warp", "ghostty",
    "atalhos", "shortcuts", "editor de scripts", "script editor", "automator", "instalador",
    "installer", "senhas", "passwords", "1password", "1password 7", "bitwarden", "keepassxc",
    "lastpass", "dashlane", "keeper",
  ]

  /// Browsers: a page names its own buttons, so a missing keyword proves
  /// nothing, and every Return or button press there is asked about.
  public static let browserBundleIDs: Set<String> = [
    "com.apple.Safari", "com.apple.SafariTechnologyPreview", "com.google.Chrome",
    "com.google.Chrome.beta", "com.google.Chrome.canary", "org.chromium.Chromium",
    "org.mozilla.firefox", "org.mozilla.firefoxdeveloperedition", "org.mozilla.nightly",
    "company.thebrowser.Browser", "com.brave.Browser", "com.microsoft.edgemac",
    "com.operasoftware.Opera", "com.vivaldi.Vivaldi", "com.kagi.kagimacOS",
    "com.duckduckgo.macos.browser", "app.zen-browser.zen",
  ]

  /// Launchers: Return opens whatever they have selected, which is how
  /// "⌘Espaço, Terminal, Return" would get around the denylist.
  public static let launcherBundleIDs: Set<String> = [
    "com.apple.Spotlight", "com.raycast.macos", "com.runningwithcrayons.Alfred",
    "at.obdev.LaunchBar",
  ]

  /// The verbs of the spec's list (enviar|send|comprar|pagar|excluir|apagar|
  /// delete|confirmar|publicar|postar|assinar|transferir), folded, with their
  /// imperative forms and English pairs, since a button says "Envie" or "Pay"
  /// as often as it says the infinitive.
  static let confirmWords: Set<String> = [
    "enviar", "envie", "envia", "send", "comprar", "compre", "buy", "pagar", "pague", "pay",
    "excluir", "exclua", "apagar", "apague", "delete", "deletar", "confirmar", "confirme",
    "confirm", "publicar", "publique", "publish", "postar", "poste", "post", "assinar",
    "assine", "sign", "transferir", "transfira", "transfer",
  ]

  /// A drop onto any of these is asked about: a confirm word, or the Trash.
  static let dropWords = confirmWords.union(["lixo", "trash"])

  static let pressableRoles: Set<String> = ["AXButton", "AXMenuButton"]

  public static let passwordFieldRefusal = "campo de senha: digite você"

  let resolver: any ComputerAppResolving

  public init(resolver: any ComputerAppResolving) {
    self.resolver = resolver
  }

  /// Checks `action` against what was observed and what holds now.
  ///
  /// `goal` is the person's own request, from the gesture that began the
  /// session; an app it does not name is asked about before it is opened.
  public func evaluate(
    _ action: ComputerAction,
    observation: ComputerObservation,
    live: ComputerLiveState,
    goal: String
  ) -> Decision {
    switch action {
    case .openApp(let name, let url):
      return evaluateOpenApp(name: name, url: url, goal: goal)
    case .readClipboard:
      return .cleared(
        Clearance(
          operation: .execute,
          summary: "Ler a área de transferência",
          confirmation:
            "Ler o que está copiado na área de transferência e mandar para o cérebro?",
          targetNamespace: "evie.computer.clipboard",
          targetIdentifier: "general"
        )
      )
    case .writeClipboard(let text):
      guard !text.isEmpty else {
        return .refused("Não há texto para copiar.")
      }
      return .cleared(
        Clearance(
          operation: .execute,
          summary: "Copiar um texto para a área de transferência",
          confirmation: nil,
          targetNamespace: "evie.computer.clipboard",
          targetIdentifier: "general"
        )
      )
    case .wait(let seconds):
      guard (1...5).contains(seconds) else {
        return .refused("Espere de 1 a 5 segundos por vez.")
      }
      return .cleared(
        Clearance(
          operation: .execute,
          summary: "Esperar \(seconds) s",
          confirmation: nil,
          targetNamespace: "evie.computer.time",
          targetIdentifier: "wait"
        )
      )
    case .click, .moveMouse, .drag, .typeText, .pressKeys, .scroll, .paste:
      return evaluateOnScreen(action, observation: observation, live: live)
    }
  }

  /// The global point a target means on `observation`: an element's centre or
  /// a grid point, through `ScreenGeometry`. `nil` for an element the
  /// observation does not list and for a point off its frame.
  public static func globalPoint(
    of target: ComputerAction.Target,
    in observation: ComputerObservation
  ) -> CGPoint? {
    guard let grid = gridPoint(of: target, in: observation) else {
      return nil
    }
    return observation.frame.globalPoint(
      normalizedX: Int(grid.x.rounded()),
      normalizedY: Int(grid.y.rounded())
    )
  }

  static func gridPoint(
    of target: ComputerAction.Target,
    in observation: ComputerObservation
  ) -> CGPoint? {
    switch target {
    case .element(_, let index):
      guard let element = observation.element(index: index) else {
        return nil
      }
      return CGPoint(x: element.box0to1000.midX, y: element.box0to1000.midY)
    case .normalized(let x, let y, _):
      return CGPoint(x: x, y: y)
    }
  }

  // MARK: - On screen

  private func evaluateOnScreen(
    _ action: ComputerAction,
    observation: ComputerObservation,
    live: ComputerLiveState
  ) -> Decision {
    if action.targets.contains(where: { $0.observationID != observation.id }) {
      return .refused(
        "Essa ação se refere a uma observação antiga; a tela pode ter mudado. "
          + "Olhe de novo com look_screen."
      )
    }

    let app = observation.frontApp
    let appName = ComputerScreenText.sanitized(app.name, limit: 60)
    if app.bundleID == Self.evieBundleID {
      return .refused("Essa janela é da própria Evie; ela não age sobre si mesma.")
    }
    if Self.isDenied(bundleID: app.bundleID, names: [app.name]) {
      return .refused(Self.deniedMessage(appName))
    }
    guard let current = live.frontApp, current.processID == app.processID,
      current.bundleID == app.bundleID
    else {
      return .refused(
        "O app da frente mudou desde a observação (era o \(appName)). Olhe a tela de novo."
      )
    }

    if case .typeText(let text) = action {
      guard !text.isEmpty else {
        return .refused("Não há texto para digitar.")
      }
      guard text.count <= ComputerUseBudget.maximumTypedCharacters else {
        return .refused(
          "Digito no máximo \(ComputerUseBudget.maximumTypedCharacters) caracteres por vez."
        )
      }
    }

    if action.usesKeyboard,
      live.secureInputEnabled || live.focusedFieldIsSecure
        || observation.focusedElement?.isSecure == true
    {
      return .refused(Self.passwordFieldRefusal)
    }

    var hits: [AXElementSummary?] = []
    for target in action.targets {
      if case .element(_, let index) = target, observation.element(index: index) == nil {
        return .refused("O elemento [\(index)] não existe nessa observação.")
      }
      guard let point = Self.globalPoint(of: target, in: observation),
        let grid = Self.gridPoint(of: target, in: observation)
      else {
        return .refused("Esse ponto fica fora da tela observada.")
      }
      if observation.evieWindowFrames.contains(where: { $0.contains(point) }) {
        return .refused("Esse ponto cai numa janela da própria Evie.")
      }
      let hit: AXElementSummary?
      if case .element(_, let index) = target {
        hit = observation.element(index: index)
      } else {
        hit = observation.element(atGrid: grid)
      }
      if hit?.isSecure == true {
        return .refused(Self.passwordFieldRefusal)
      }
      hits.append(hit)
    }

    return .cleared(classify(action, hits: hits, observation: observation, appName: appName))
  }

  /// Whether an on-screen action needs the person first, and whether it is
  /// destructive. Every check above has passed.
  private func classify(
    _ action: ComputerAction,
    hits: [AXElementSummary?],
    observation: ComputerObservation,
    appName: String
  ) -> Clearance {
    func cleared(
      _ summary: String,
      ask confirmation: String? = nil,
      operation: CapabilityOperation = .execute
    ) -> Clearance {
      Clearance(
        operation: operation,
        summary: summary,
        confirmation: confirmation,
        targetNamespace: "evie.computer.app",
        targetIdentifier: observation.frontApp.bundleID ?? "pid-\(observation.frontApp.processID)"
      )
    }
    let bundleID = observation.frontApp.bundleID ?? ""
    let inBrowser = Self.browserBundleIDs.contains(bundleID)

    switch action {
    case .click(_, let button, _):
      let element = hits.first ?? nil
      let title = element.map { ComputerScreenText.sanitized($0.title, limit: 80) } ?? ""
      let named = title.isEmpty ? "num ponto da tela" : "em “\(title)”"
      let summary = "Clicar \(named) no \(appName)"
      guard button == .left, let element else {
        return cleared(summary)
      }
      let words = Self.words(element.title)
      if Self.emptiesTrash(words) {
        return cleared(
          summary,
          ask: "Apagar de vez: clicar em “\(title)” no \(appName)? Não dá para desfazer.",
          operation: .delete
        )
      }
      if !words.isDisjoint(with: Self.confirmWords) {
        let role = Self.roleSuffix(element.role)
        return cleared(summary, ask: "Clicar em “\(title)”\(role) no \(appName)?")
      }
      if inBrowser, Self.pressableRoles.contains(element.role) {
        let name = title.isEmpty ? "num botão sem nome" : "no botão “\(title)”"
        return cleared(
          summary,
          ask: "Clicar \(name) no \(appName)? Num navegador, o nome do botão vem da página, "
            + "então a Evie pergunta antes."
        )
      }
      return cleared(summary)

    case .moveMouse:
      return cleared("Mover o ponteiro no \(appName)")

    case .scroll:
      return cleared("Rolar no \(appName)")

    case .drag:
      let summary = "Arrastar no \(appName)"
      let drop = hits.last ?? nil
      if let drop, !Self.words(drop.title).isDisjoint(with: Self.dropWords) {
        let title = ComputerScreenText.sanitized(drop.title, limit: 80)
        return cleared(summary, ask: "Arrastar até “\(title)” no \(appName)?")
      }
      if bundleID == "com.apple.finder" {
        return cleared(summary, ask: "Arrastar no Finder? Isso pode mover arquivos.")
      }
      return cleared(summary)

    case .typeText(let text):
      let summary = "Digitar \(text.count) caracteres no \(appName)"
      if text.contains(where: \.isNewline) {
        return cleared(summary, ask: returnConfirmation(observation, appName: appName))
      }
      return cleared(summary)

    case .pressKeys(let chord):
      let summary = "Usar \(chord.symbol) no \(appName)"
      if chord.modifiers.contains(.command), chord.key == "delete" || chord.key == "forwarddelete" {
        return cleared(
          summary,
          ask: "Apagar: \(chord.symbol) no \(appName) apaga o que estiver selecionado. Fazer?",
          operation: .delete
        )
      }
      if let meaning = Self.riskyChordMeaning(chord) {
        return cleared(summary, ask: "Usar \(chord.symbol) no \(appName)? \(meaning)")
      }
      if chord.isReturn {
        return cleared(summary, ask: returnConfirmation(observation, appName: appName))
      }
      return cleared(summary)

    case .paste:
      return cleared("Colar no \(appName)")

    case .wait, .writeClipboard, .readClipboard, .openApp:
      return cleared("Agir no \(appName)")
    }
  }

  /// Return submits whatever the window treats as its default — a form, a
  /// launcher's choice, a dialog's "Excluir" — and which button that is does
  /// not show in the focused element. So Return is asked about in a browser,
  /// in a launcher, and wherever a confirm-word button is on screen.
  private func returnConfirmation(_ observation: ComputerObservation, appName: String) -> String? {
    let bundleID = observation.frontApp.bundleID ?? ""
    if Self.browserBundleIDs.contains(bundleID) {
      return "Apertar Return no \(appName)? Num navegador, Return pode enviar um formulário, "
        + "e a página escolhe o nome dos botões."
    }
    if Self.launcherBundleIDs.contains(bundleID) {
      return "Apertar Return no \(appName)? Isso abre o que estiver selecionado."
    }
    let candidates = [observation.focusedElement].compactMap { $0 }
      + observation.elements.filter { Self.pressableRoles.contains($0.role) }
    let confirmable = candidates.first {
      !Self.words($0.title).isDisjoint(with: Self.confirmWords)
    }
    if let confirmable {
      let title = ComputerScreenText.sanitized(confirmable.title, limit: 80)
      return "Apertar Return no \(appName)? Há “\(title)” nesta janela, "
        + "e Return pode acioná-lo."
    }
    return nil
  }

  private static func riskyChordMeaning(_ chord: KeyChord) -> String? {
    let modifiers = chord.modifiers
    switch chord.key {
    case "q" where modifiers == [.command, .shift] || modifiers == [.command, .shift, .option]:
      return "Isso encerra a sua sessão no Mac."
    case "q" where modifiers == [.command, .control]:
      return "Isso bloqueia a tela."
    case "q" where modifiers.contains(.command):
      return "Isso fecha o app."
    case "w" where modifiers.contains(.command):
      return "Isso fecha a janela."
    case "space" where modifiers.contains(.command):
      return "Isso abre o Spotlight."
    case "escape" where modifiers.isSuperset(of: [.command, .option]):
      return "Isso abre Forçar Encerrar."
    case "tab" where modifiers.contains(.command):
      return "Isso troca de app."
    default:
      return nil
    }
  }

  // MARK: - Opening an app

  private func evaluateOpenApp(name: String, url: URL?, goal: String) -> Decision {
    var host: String?
    if let url {
      guard url.scheme?.lowercased() == "https", let urlHost = url.host(), !urlHost.isEmpty,
        url.user() == nil, url.password() == nil
      else {
        return .refused("Só abro links https:// comuns.")
      }
      host = ComputerScreenText.sanitized(urlHost, limit: 80)
    }

    guard let app = resolver.resolve(name: name) else {
      return .refused("Não encontrei esse app neste Mac.")
    }
    let appName = ComputerScreenText.sanitized(app.displayName, limit: 60)
    if app.bundleID == Self.evieBundleID {
      return .refused("A Evie não abre a si mesma.")
    }
    if Self.isDenied(bundleID: app.bundleID, names: [app.displayName] + app.otherNames) {
      return .refused(Self.deniedMessage(appName))
    }

    let named = ([app.displayName] + app.otherNames).contains { Self.goal(goal, names: $0) }
    let unnamedNote = named ? nil : "Você não falou desse app no pedido."
    let confirmation: String?
    if let host {
      confirmation = ["Abrir um link de \(host) no \(appName)?", unnamedNote]
        .compactMap { $0 }.joined(separator: " ")
    } else {
      confirmation = unnamedNote.map { "Abrir o \(appName)? \($0)" }
    }
    return .cleared(
      Clearance(
        operation: .execute,
        summary: host.map { "Abrir \($0) no \(appName)" } ?? "Abrir o \(appName)",
        confirmation: confirmation,
        targetNamespace: "evie.computer.app",
        targetIdentifier: app.bundleID
      )
    )
  }

  // MARK: - Matching

  static func isDenied(bundleID: String?, names: [String]) -> Bool {
    if let bundleID {
      if deniedBundleIDs.contains(bundleID)
        || deniedBundlePrefixes.contains(where: { bundleID.hasPrefix($0) })
      {
        return true
      }
    }
    return names.contains { deniedNames.contains(fold($0).trimmingCharacters(in: .whitespaces)) }
  }

  private static func deniedMessage(_ appName: String) -> String {
    "A Evie não mexe no \(appName): ele muda o sistema, roda comandos ou guarda senhas. "
      + "Se precisar, faça você."
  }

  /// Whether the person's request names the app: its words, in order, as
  /// whole words of the request, ignoring case and accents.
  static func goal(_ goal: String, names name: String) -> Bool {
    let nameWords = orderedWords(name)
    guard !nameWords.isEmpty else {
      return false
    }
    let goalWords = orderedWords(goal)
    guard goalWords.count >= nameWords.count else {
      return false
    }
    for start in 0...(goalWords.count - nameWords.count)
    where Array(goalWords[start..<(start + nameWords.count)]) == nameWords {
      return true
    }
    return false
  }

  static func emptiesTrash(_ words: Set<String>) -> Bool {
    (words.contains("esvaziar") && words.contains("lixo"))
      || (words.contains("empty") && words.contains("trash"))
  }

  private static func roleSuffix(_ role: String) -> String {
    switch role {
    case "AXButton", "AXMenuButton": " (botão)"
    case "AXMenuItem": " (item de menu)"
    case "AXLink": " (link)"
    default: ""
    }
  }

  static func words(_ text: String) -> Set<String> {
    Set(orderedWords(text))
  }

  static func orderedWords(_ text: String) -> [String] {
    fold(ComputerScreenText.sanitized(text, limit: 400))
      .split(whereSeparator: { !$0.isLetter && !$0.isNumber })
      .map(String.init)
  }

  static func fold(_ text: String) -> String {
    text.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: nil).lowercased()
  }
}
