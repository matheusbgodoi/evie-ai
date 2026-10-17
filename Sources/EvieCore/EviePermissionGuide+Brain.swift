import Foundation

// The first-run guide's two rows that are not system permissions. With them the
// guide sets Evie up end to end: the key the PC asks for, then a test that the
// brain answers with it, so nobody has to find Configurações › Cérebro first.

// MARK: - Rows

extension PermissionGuideRow {
  public static let pcKeyID = "pc_key"
  public static let brainID = "brain"

  /// The "Chave do PC" row.
  ///
  /// - Parameters:
  ///   - status: whether Evie's own item holds the key, from an attributes-only
  ///     query; nil when no profile takes the PC key, so there is nothing to ask.
  ///   - importFailure: why the last import failed, if it did. A key saved
  ///     since, from here or from Settings, wins over it.
  public static func pcKey(
    status: EvieModelKeyStatus?,
    importFailure: String?
  ) -> PermissionGuideRow {
    let importKey = Action(title: "Importar", kind: .importPCKey)
    let (mark, statusText, hint, action): (Mark, String, String?, Action?) =
      switch (status, importFailure) {
      case (nil, _):
        (.satisfied, "Não usada", nil, nil)
      case (.checking, nil):
        (.pending, "Verificando…", "Aguardando a resposta do Keychain do macOS.", nil)
      case (.checking, let failure?):
        (.refused, "Não importada", failure, importKey)
      case (.saved, _):
        (.satisfied, "Salva", nil, nil)
      case (.missing, nil):
        (.pending, "Sem chave", EvieModelKeys.importPromptExplanation, importKey)
      case (.missing, let failure?):
        (.refused, "Não importada", failure, importKey)
      case (.unknown(let reason), nil):
        (.refused, "Não consegui ver", reason, importKey)
      case (.unknown, let failure?):
        (.refused, "Não importada", failure, importKey)
      }
    return PermissionGuideRow(
      id: pcKeyID,
      title: "Chave do PC",
      detail: "Deixa a Evie falar com o PC pela sua rede Tailscale. A chave fica no "
        + "Keychain deste Mac, no item da Evie; para colar à mão, use "
        + "Configurações › Cérebro.",
      hint: hint,
      mark: mark,
      statusText: statusText,
      action: action
    )
  }

  /// The "Cérebro" row: the last Testar conexão on `profile`, or none yet.
  ///
  /// An unloaded model counts as set up. The PC loads it on the first
  /// question, and the Mac brain is meant to be off until a turn wakes it, so
  /// neither is something the person has to fix. The test stays on offer
  /// whatever the result: unlike a permission, it can change by itself.
  public static func brain(
    profile: EvieModelProfile,
    report: ModelConnectionReport?
  ) -> PermissionGuideRow {
    let test = Action(title: "Testar conexão", kind: .testConnection)
    let detail =
      profile.location == .yourPC
      ? "Confere se o PC responde pela sua rede Tailscale, aceita a chave e tem o "
        + "\(profile.model) carregado."
      : "Confere se o cérebro do Mac responde. Parado é normal: a Evie o acorda "
        + "quando uma pergunta precisa dele."
    guard let report else {
      return PermissionGuideRow(
        id: brainID,
        title: "Cérebro",
        detail: detail,
        hint: nil,
        mark: .pending,
        statusText: "Não testado",
        action: test
      )
    }

    let (mark, statusText): (Mark, String) =
      switch report.readiness.rung {
      case .ready: (.satisfied, "Pronto")
      case .modelCold:
        (.satisfied, profile.location == .thisMac ? "Acorda ao perguntar" : "Descarregado")
      case .unreachable: (.refused, "Sem resposta")
      case .keyMissing: (.refused, "Sem chave")
      case .keyRejected: (.refused, "Chave recusada")
      case .modelUnknown: (.refused, "Sem o modelo")
      }
    return PermissionGuideRow(
      id: brainID,
      title: "Cérebro",
      detail: detail,
      hint: report.stepsLine(for: profile) + "\n" + report.summary(for: profile),
      mark: mark,
      statusText: statusText,
      action: test
    )
  }
}

extension ModelConnectionReport {
  /// The three steps on one line, as the guide's row has room for:
  /// "PC alcançável: ✓ 37 ms · Chave aceita: ✓ 69 ms · Modelo carregado: ✓ 69 ms".
  /// Settings draws the same steps as a list with symbols.
  public func stepsLine(for profile: EvieModelProfile) -> String {
    lines.map { line in
      let outcome =
        switch line.outcome {
        case .passed: "✓"
        case .failed: "✗"
        case .notRun: "não testado"
        case .notNeeded: "não precisa"
        }
      let time = line.elapsed.map { " " + Self.formatted($0) } ?? ""
      return "\(title(of: line.step, for: profile)): \(outcome)\(time)"
    }
    .joined(separator: " · ")
  }
}

extension EvieLoadedConfiguration {
  /// The profile whose key the guide imports: the one in use when it runs on
  /// the PC with a key, otherwise the first such profile, preference order
  /// first. The Mac brain being in use is no reason to skip the key: it is
  /// usually in use because the key is missing.
  public var pcKeyProfile: EvieModelProfile? {
    let takesPCKey = { (profile: EvieModelProfile) in
      profile.location == .yourPC && profile.credential != nil
    }
    if takesPCKey(activeProfile) {
      return activeProfile
    }
    let preferred = profiles.preferenceOrder.compactMap(profiles.profile(id:))
    return (preferred + profiles.profiles).first(where: takesPCKey)
  }
}

// MARK: - Buttons

/// The "Chave do PC" row's state and its button.
///
/// Holds only why the last import failed; whether a key is saved is asked of
/// the keychain on every refresh, so a key pasted in Settings shows here too.
@MainActor
public final class EvieGuidePCKeyStep {
  private let keys: EvieModelKeys
  private let configuration: @MainActor () -> EvieLoadedConfiguration
  private let onKeySaved: @MainActor (EvieModelProfile) -> Void
  private var importFailure: String?
  private let statusRefresh: EvieModelKeyStatusRefresh
  public var onStatusChanged: (@MainActor () -> Void)?

  /// - Parameters:
  ///   - configuration: the profiles as Evie uses them now, read on every
  ///     refresh so a save in Settings is followed.
  ///   - onKeySaved: told after a successful import, so whatever read the old
  ///     state — the readiness cache, the brain row, the Settings pane — reads
  ///     it again.
  public init(
    keys: EvieModelKeys,
    configuration: @escaping @MainActor () -> EvieLoadedConfiguration,
    onKeySaved: @escaping @MainActor (EvieModelProfile) -> Void
  ) {
    self.keys = keys
    self.configuration = configuration
    self.onKeySaved = onKeySaved
    statusRefresh = EvieModelKeyStatusRefresh(keys: keys)
    statusRefresh.onChange = { [weak self] in self?.onStatusChanged?() }
  }

  /// Rendering only reads cached attributes. The OS query runs on the bounded
  /// background worker, even if another Keychain prompt is blocking it.
  public var row: PermissionGuideRow {
    let references = statusReferences
    statusRefresh.refresh(references, force: false)
    return .pcKey(
      status: references.isEmpty
        ? nil : statusRefresh.statuses[PermissionGuideRow.pcKeyID] ?? .checking,
      importFailure: importFailure)
  }

  public func refreshStatus() { statusRefresh.refresh(statusReferences) }

  private var statusReferences: [String: CredentialReference] {
    guard let reference = configuration().pcKeyProfile?.credential else { return [:] }
    return [PermissionGuideRow.pcKeyID: reference]
  }

  /// One read of the PC configuration's item, which waits for the macOS
  /// prompt, then a copy into the profile's own item.
  public func importKey() async {
    guard let profile = configuration().pcKeyProfile, let reference = profile.credential else {
      return
    }
    do {
      try await keys.importPCConfigurationKey(into: reference)
      importFailure = nil
      refreshStatus()
      onKeySaved(profile)
    } catch {
      // `EvieModelKeyError` messages never carry what was read or typed.
      importFailure = (error as? LocalizedError)?.errorDescription ?? "\(error)"
    }
  }
}

/// The "Cérebro" row's last connection test and its button.
@MainActor
public final class EvieGuideBrainStep {
  private let configuration: @MainActor () -> EvieLoadedConfiguration
  private let test: @MainActor (EvieModelProfile) async -> ModelConnectionReport
  /// Kept with the exact profile it was measured on, so a settings save that
  /// changes the brain in use shows "Não testado" rather than an old answer.
  private var lastResult: (profile: EvieModelProfile, report: ModelConnectionReport)?

  public convenience init(
    configuration: @escaping @MainActor () -> EvieLoadedConfiguration,
    probe: ModelReadinessProbe
  ) {
    self.init(configuration: configuration) { await probe.connectionReport(for: $0) }
  }

  init(
    configuration: @escaping @MainActor () -> EvieLoadedConfiguration,
    test: @escaping @MainActor (EvieModelProfile) async -> ModelConnectionReport
  ) {
    self.configuration = configuration
    self.test = test
  }

  public var row: PermissionGuideRow {
    let profile = configuration().activeProfile
    let report = lastResult.flatMap { $0.profile == profile ? $0.report : nil }
    return .brain(profile: profile, report: report)
  }

  /// The same probe Configurações › Cérebro runs, on the profile in use with
  /// its environment overrides, which is what a turn would ask first.
  public func testConnection() async {
    let profile = configuration().activeProfile
    lastResult = (profile, await test(profile))
  }

  /// A key was saved since the last test, so its answer may no longer hold.
  public func forgetResult() {
    lastResult = nil
  }
}
