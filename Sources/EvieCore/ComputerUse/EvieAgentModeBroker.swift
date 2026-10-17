import Foundation

/// How the person asked for a session or confirmed a step.
public enum UserGesture: Sendable, Equatable {
  /// Holding the talk shortcut: a key on this Mac, held by a hand.
  case pushToTalk
  /// A click on one of Evie's buttons, which refuse events Evie posts herself.
  case button
  /// A local research trigger, only while a hand-armed, expiring research
  /// session is held by the shell (ADR 0020). Cannot approve a sensitive step.
  case researchShortcut
  /// "Evie, …" heard by the microphone — which also hears videos, calls and
  /// other people, so it can start a conversation but never a session.
  case wakeWord
}

/// The person's permission for one computer-use session.
///
/// No public initializer and no `Codable`: only `EvieAgentModeBroker.begin`
/// makes one, after a gesture only the person can make, so neither model
/// output nor anything decoded can claim a session exists.
public struct EvieAgentModeGrant: Sendable, Hashable {
  public let id: UUID
  public let startedAt: Date
  /// At most `EvieAgentModeBroker.grantLifetime` after `startedAt`.
  public let expiresAt: Date
  /// The person's own request, as said or typed.
  public let goal: String
  /// Explicit clipboard-output consent collected by trusted local UI for this
  /// session, not inferred from model text or the goal. False for normal use.
  public let allowsClipboardWrites: Bool
  /// Research shortcut grants permit only identified answer fields and choices;
  /// a confirmation cannot expand them into submit/send or launching authority.
  public let answerEntryOnly: Bool

  fileprivate init(
    id: UUID, startedAt: Date, expiresAt: Date, goal: String, allowsClipboardWrites: Bool,
    answerEntryOnly: Bool
  ) {
    self.id = id
    self.startedAt = startedAt
    self.expiresAt = expiresAt
    self.goal = goal
    self.allowsClipboardWrites = allowsClipboardWrites
    self.answerEntryOnly = answerEntryOnly
  }
}

/// A question for the person before an action. Its text comes from the
/// policy, built from what the system reports about the screen.
public struct ComputerConfirmation: Sendable, Equatable {
  public let id: UUID
  public let text: String
  public let operation: CapabilityOperation

  fileprivate init(id: UUID, text: String, operation: CapabilityOperation) {
    self.id = id
    self.text = text
    self.operation = operation
  }
}

public enum ActionClearance: Sendable, Equatable {
  /// Cleared: hand this to the executor with the action.
  case commit(CapabilityCommit)
  /// Ask the person; `approve` turns their click into a commit.
  case needsConfirmation(ComputerConfirmation)
  /// Not done. The reason goes back to the model as the tool result.
  case refused(String)
}

/// Why the executor must not act on a commit.
public enum ComputerUseError: Error, Equatable, Sendable {
  /// The session was stopped, replaced or ran out of time.
  case sessionEnded
  /// The broker did not issue this commit, or it was already carried out.
  case unknownCommit
  /// The commit was issued for a different action.
  case actionMismatch
}

extension ComputerUseError: LocalizedError {
  public var errorDescription: String? {
    switch self {
    case .sessionEnded:
      "A sessão de controle do Mac terminou."
    case .unknownCommit:
      "Essa ação não foi autorizada, ou já foi feita."
    case .actionMismatch:
      "A autorização não é desta ação."
    }
  }
}

/// The one place computer-use authority comes from (ADR 0016, amending 0009).
///
/// A session begins with a grant, made only from push-to-talk or a click. For
/// every action the loop brings, the broker checks the grant is the active
/// one and unexpired, that the observation is the newest and not yet acted
/// on, the budget, and the policy; then it builds a `CapabilityProposal`
/// (`.execute`, or `.delete` for what cannot be undone) bound to the session
/// (`planID` is the grant's id) and to the observation (the revision is its
/// id), and mints the commit through `CapabilityCommitAuthorityFactory` —
/// under the documented policy when nothing needs asking, or with the
/// person's click on "Fazer" when something does. Delete always needs that
/// click: the factory refuses it otherwise, by type, not by keyword.
///
/// The executor calls `validate(_:for:)` right before acting. A revoke, an
/// expiry or a newer observation in between voids every commit not yet
/// carried out, and each commit is carried out at most once.
@MainActor
public final class EvieAgentModeBroker {
  /// Fifteen minutes: the longest a capability proposal may live.
  public nonisolated static let grantLifetime: TimeInterval =
    CapabilityContractLimits.maximumProposalLifetime
  /// A request longer than this is not a spoken or typed instruction.
  public nonisolated static let maximumGoalCharacters = 2_000

  private struct Issued {
    let proposal: CapabilityProposal
    let action: ComputerAction
  }

  private struct Pending {
    let proposal: CapabilityProposal
    let action: ComputerAction
    let observationID: String
  }

  private struct Session {
    let grant: EvieAgentModeGrant
    var budget: ComputerUseBudget
    var latestObservationID: String?
    var spentObservationIDs: Set<String> = []
    var issued: [UUID: Issued] = [:]
    var pending: [UUID: Pending] = [:]
    /// A chord that may open a launcher was committed, and no observation
    /// since has shown that none is open: Return and a typed newline ask
    /// first until one does (`ComputerActionPolicy.showsNoLauncher`).
    var launcherMayBeOpen = false
  }

  private let policy: ComputerActionPolicy
  private let now: () -> Date
  private var session: Session?

  public init(policy: ComputerActionPolicy, now: @escaping () -> Date = Date.init) {
    self.policy = policy
    self.now = now
  }

  /// Why a profile cannot run act mode, or `nil` when it can: the loop needs
  /// a brain that both sees the screen and calls tools reliably. LensVLM on
  /// the Mac does not call tools (ADR 0015), so act mode needs the PC.
  public nonisolated static func unavailableReason(on profile: EvieModelProfile) -> String? {
    profile.capabilities.tools && profile.capabilities.vision
      ? nil : "Controlar o Mac precisa do PC"
  }

  // MARK: - The session

  /// The active grant, if any; an expired one is ended here.
  public var activeGrant: EvieAgentModeGrant? {
    liveSession()?.grant
  }

  /// Begins a session for `goal`, replacing any running one.
  ///
  /// Push-to-talk or a button after the session card (S5d), or a research
  /// shortcut inside its hand-armed lease (ADR 0020). An earlier deadline
  /// limits the grant. The wake word never can begin one.
  public func begin(
    goal: String, gesture: UserGesture, expiresAt deadline: Date? = nil,
    allowsClipboardWrites: Bool = false
  ) -> EvieAgentModeGrant? {
    guard gesture == .pushToTalk || gesture == .button || gesture == .researchShortcut else {
      return nil
    }
    let trimmed = goal.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !trimmed.isEmpty, trimmed.count <= Self.maximumGoalCharacters else {
      return nil
    }
    let start = now()
    let expiry = min(deadline ?? .distantFuture, start.addingTimeInterval(Self.grantLifetime))
    guard expiry > start else { return nil }
    let grant = EvieAgentModeGrant(
      id: UUID(),
      startedAt: start,
      expiresAt: expiry,
      goal: trimmed,
      allowsClipboardWrites: allowsClipboardWrites,
      answerEntryOnly: gesture == .researchShortcut
    )
    session = Session(grant: grant, budget: ComputerUseBudget(startedAt: start))
    return grant
  }

  /// Ends the session at once: every grant, confirmation and commit not yet
  /// carried out is void. The kill switches all lead here.
  public func revoke() {
    session = nil
  }

  public func isActive(_ grant: EvieAgentModeGrant) -> Bool {
    liveSession(for: grant) != nil
  }

  /// The computer-use tools, for a loop holding the active grant; none
  /// otherwise.
  public func toolDefinitions(
    for grant: EvieAgentModeGrant?,
    convention: CoordinateConvention
  ) -> [EvieToolDefinition] {
    guard let grant, isActive(grant) else {
      return []
    }
    return ComputerToolDefinitions.definitions(convention: convention)
  }

  /// Records `observation` as the screen the next action is judged against.
  /// Any question still open about an older screen is dropped.
  @discardableResult
  public func register(_ observation: ComputerObservation, grant: EvieAgentModeGrant) -> Bool {
    guard var current = liveSession(for: grant) else {
      return false
    }
    current.latestObservationID = observation.id
    current.pending.removeAll()
    if current.launcherMayBeOpen, ComputerActionPolicy.showsNoLauncher(observation) {
      current.launcherMayBeOpen = false
    }
    session = current
    return true
  }

  /// Counts what an action did, for the run-of-setbacks limit.
  public func record(_ result: ActionResult, grant: EvieAgentModeGrant) {
    guard var current = liveSession(for: grant) else {
      return
    }
    current.budget.record(result.outcome)
    session = current
  }

  /// Whether the budget is spent, so the loop should finish with `need_user`.
  public func needsUser(_ grant: EvieAgentModeGrant) -> Bool {
    exhaustion(of: grant) != nil
  }

  /// Which limit of the budget is spent, if one is.
  public func exhaustion(of grant: EvieAgentModeGrant) -> ComputerUseBudget.Exhaustion? {
    guard let current = liveSession(for: grant) else {
      return nil
    }
    if case .exhausted(let reason) = current.budget.verdict(at: now()) {
      return reason
    }
    return nil
  }

  /// When the next action may be committed, so the loop can wait for it.
  public func nextActionAllowedAt(_ grant: EvieAgentModeGrant) -> Date? {
    liveSession(for: grant)?.budget.nextActionAllowedAt
  }

  // MARK: - Authorizing

  public func authorize(
    _ action: ComputerAction,
    grant: EvieAgentModeGrant,
    observation: ComputerObservation,
    live: ComputerLiveState
  ) -> ActionClearance {
    guard var current = liveSession(for: grant) else {
      return .refused(ComputerUseError.sessionEnded.localizedDescription)
    }
    if let refusal = Self.refusal(of: current.budget.verdict(at: now())) {
      return .refused(refusal)
    }
    if let refusal = Self.observationRefusal(observation.id, in: current) {
      return .refused(refusal)
    }

    let clearance: ComputerActionPolicy.Clearance
    switch policy.evaluate(
      action, observation: observation, live: live, goal: grant.goal,
      afterLauncherChord: current.launcherMayBeOpen,
      clipboardWriteAuthorized: grant.allowsClipboardWrites,
      answerEntryOnly: grant.answerEntryOnly)
    {
    case .refused(let reason):
      return .refused(reason)
    case .cleared(let cleared):
      clearance = cleared
    }

    let proposal: CapabilityProposal
    do {
      proposal = try Self.proposal(
        for: action,
        clearance: clearance,
        grant: grant,
        observation: observation,
        at: now()
      )
    } catch {
      return .refused(
        "Essa ação não pode ser autorizada como está: é grande demais ou tem caracteres "
          + "inválidos."
      )
    }

    if let question = clearance.confirmation {
      let confirmation = ComputerConfirmation(
        id: proposal.requestID,
        text: question,
        operation: clearance.operation
      )
      current.pending[proposal.requestID] = Pending(
        proposal: proposal,
        action: action,
        observationID: observation.id
      )
      session = current
      return .needsConfirmation(confirmation)
    }
    return mint(proposal, action: action, approval: .documentedPolicy, in: &current)
  }

  /// Turns the person's yes into a commit. Only a click on the card's button
  /// counts: the card rejects events Evie posts, keyboard confirmation is off
  /// while she acts, and the wake word is never the person for certain.
  public func approve(
    _ confirmation: ComputerConfirmation,
    grant: EvieAgentModeGrant,
    gesture: UserGesture
  ) -> ActionClearance {
    guard gesture == .button else {
      return .refused("Só um clique em Fazer confirma uma ação.")
    }
    guard var current = liveSession(for: grant) else {
      return .refused(ComputerUseError.sessionEnded.localizedDescription)
    }
    guard let pending = current.pending.removeValue(forKey: confirmation.id) else {
      return .refused("Essa pergunta não vale mais; olhe a tela de novo.")
    }
    session = current
    if let refusal = Self.observationRefusal(pending.observationID, in: current) {
      return .refused(refusal)
    }
    if case .exhausted(let reason) = current.budget.verdict(at: now()) {
      return .refused(reason.message)
    }
    return mint(pending.proposal, action: pending.action, approval: .explicitUser, in: &current)
  }

  /// The executor's check, immediately before it posts anything: the session
  /// is still the commit's, the broker issued this commit for this action and
  /// it has not been carried out, and the factory still accepts it against
  /// the newest observation. A commit passes once.
  public func validate(_ commit: CapabilityCommit, for action: ComputerAction) throws {
    guard var current = session, commit.proposal.planID == current.grant.id,
      now() < current.grant.expiresAt
    else {
      throw ComputerUseError.sessionEnded
    }
    guard let issued = current.issued[commit.proposal.requestID] else {
      throw ComputerUseError.unknownCommit
    }
    guard issued.action == action else {
      throw ComputerUseError.actionMismatch
    }
    current.issued.removeValue(forKey: commit.proposal.requestID)
    session = current
    try CapabilityCommitAuthorityFactory.validate(
      commit,
      against: issued.proposal,
      currentRevision: CapabilityRevision(current.latestObservationID ?? ""),
      at: now()
    )
  }

  /// Whether a commit `validate` already accepted still stands: the same
  /// session, unexpired, and no newer observation since. The executor asks
  /// again right before each event it posts, because a dwell, a focus change
  /// or a long text lies between `validate` and the last keystroke, and a
  /// stop in that time must stop what is left.
  public func stillAuthorizes(_ commit: CapabilityCommit) -> Bool {
    guard let current = liveSession(), commit.proposal.planID == current.grant.id else {
      return false
    }
    return current.latestObservationID == commit.proposal.revision.value
  }

  // MARK: - Building blocks

  /// The proposal for `action`: bound to the session by its plan id and to
  /// the observation by its revision, living no longer than the grant.
  nonisolated static func proposal(
    for action: ComputerAction,
    clearance: ComputerActionPolicy.Clearance,
    grant: EvieAgentModeGrant,
    observation: ComputerObservation,
    at now: Date
  ) throws -> CapabilityProposal {
    try CapabilityProposal(
      requestID: UUID(),
      planID: grant.id,
      capability: CapabilityDescriptor(
        identifier: action.capabilityIdentifier,
        operation: clearance.operation
      ),
      target: CapabilityTarget(
        displayName: clearance.summary,
        canonicalIdentity: CapabilityCanonicalTargetIdentity(
          namespace: clearance.targetNamespace,
          identifier: clearance.targetIdentifier
        )
      ),
      materialArguments: action.materialArguments,
      revision: CapabilityRevision(observation.id),
      createdAt: now,
      expiresAt: grant.expiresAt,
      provenance: CapabilityProvenance(
        origin: .model,
        trust: .mixed,
        sourceReference: observation.id
      )
    )
  }

  private func mint(
    _ proposal: CapabilityProposal,
    action: ComputerAction,
    approval: CapabilityApprovalEvidence,
    in current: inout Session
  ) -> ActionClearance {
    let commit: CapabilityCommit
    do {
      commit = try CapabilityCommitAuthorityFactory.authorize(
        proposal: proposal,
        approvedRevision: proposal.revision,
        approval: approval,
        at: now()
      )
    } catch {
      session = current
      return .refused(error.localizedDescription)
    }
    current.issued[proposal.requestID] = Issued(proposal: proposal, action: action)
    current.spentObservationIDs.insert(proposal.revision.value)
    if case .pressKeys(let chord) = action, chord.mayOpenLauncher {
      current.launcherMayBeOpen = true
    }
    current.budget.recordAction(at: now())
    session = current
    return .commit(commit)
  }

  private static func observationRefusal(_ id: String, in session: Session) -> String? {
    guard id == session.latestObservationID else {
      return "Essa não é a última observação; a tela pode ter mudado. "
        + "Olhe de novo com look_screen."
    }
    guard !session.spentObservationIDs.contains(id) else {
      return "Já agi sobre essa observação; olhe a tela de novo antes da próxima ação."
    }
    return nil
  }

  private static func refusal(of verdict: ComputerUseBudget.Verdict) -> String? {
    switch verdict {
    case .proceed:
      nil
    case .wait:
      "Espere um instante entre uma ação e outra."
    case .exhausted(let reason):
      reason.message
    }
  }

  /// The session, ended here if its time is up.
  private func liveSession() -> Session? {
    guard let current = session else {
      return nil
    }
    guard now() < current.grant.expiresAt else {
      session = nil
      return nil
    }
    return current
  }

  private func liveSession(for grant: EvieAgentModeGrant) -> Session? {
    guard let current = liveSession(), current.grant.id == grant.id else {
      return nil
    }
    return current
  }
}

extension ComputerAction {
  /// The action's material arguments, bound into its proposal.
  var materialArguments: CapabilityMaterialArguments {
    var values: [String: CapabilityArgumentValue] = ["kind": .string(kindName)]
    func add(_ target: Target, prefix: String = "") {
      values["\(prefix)observation_id"] = .string(target.observationID)
      switch target {
      case .element(_, let index):
        values["\(prefix)element"] = .integer(Int64(index))
      case .normalized(let x, let y, _):
        values["\(prefix)x"] = .integer(Int64(x))
        values["\(prefix)y"] = .integer(Int64(y))
      }
    }
    switch self {
    case .click(let target, let button, let count):
      add(target)
      values["button"] = .string(button.rawValue)
      values["count"] = .integer(Int64(count))
    case .moveMouse(let target):
      add(target)
    case .drag(let from, let to):
      add(from, prefix: "from_")
      add(to, prefix: "to_")
    case .typeText(let text), .writeClipboard(let text):
      values["text"] = .string(text)
    case .pressKeys(let chord):
      values["key"] = .string(chord.key)
      values["modifiers"] = .array(chord.modifiers.sorted().map { .integer(Int64($0.rawValue)) })
    case .scroll(let target, let dx, let dy):
      add(target)
      values["dx"] = .integer(Int64(dx))
      values["dy"] = .integer(Int64(dy))
    case .wait(let seconds):
      values["seconds"] = .integer(Int64(seconds))
    case .openApp(let name, let url):
      values["name"] = .string(name)
      if let url {
        values["url"] = .string(url.absoluteString)
      }
    case .readClipboard, .paste:
      break
    }
    return CapabilityMaterialArguments(values)
  }
}
