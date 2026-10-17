import EvieCore
import Foundation

/// The brain chip in the input bar and its menu.
///
/// The chip shows the brain the next question goes to — the conversation's
/// pin, or where a new one would start — so it is read from the resolver, never
/// kept beside it. Choosing a brain in its menu goes to the resolver too
/// (`EvieBrainResolver.choose(_:)`), which narrows the same preference order
/// every turn walks.
extension OverlayViewModel {
  /// Re-reads the chip from the resolver: the key store first, then the
  /// cached probe, which probes again only when its answer is stale.
  func refreshBrainChip() {
    let conversation = activeConversationID
    let expected = brainResolver.expectedProfile(for: conversation)
    if expected != brainChip.profile {
      contextUsageDescription = nil
      // The name changes at once; the dot waits for the probe.
      brainChip.profile = expected
      brainChip.rung = nil
    }
    brainChipGeneration &+= 1
    let generation = brainChipGeneration
    Task { @MainActor [weak self] in
      guard let self else { return }
      let status = await brainResolver.status(for: conversation)
      applyBrainStatus(status, generation: generation, conversation: conversation)
    }
  }

  /// "Testar conexão": probes the chip's brain again and says what it found
  /// on the status line.
  func testBrainConnection() {
    guard !hasActiveRequest, !isResearchBusy() else { return }
    let conversation = activeConversationID
    brainChip.rung = nil
    brainChipGeneration &+= 1
    let generation = brainChipGeneration
    Task { @MainActor [weak self] in
      guard let self else { return }
      let status = await brainResolver.checkConnection(for: conversation)
      guard applyBrainStatus(status, generation: generation, conversation: conversation) else {
        return
      }
      guard !hasActiveRequest, !isResearchBusy() else { return }
      primaryText = "Testar conexão"
      secondaryText = brainChip.connectionSummary
      onLayoutInvalidated?()
    }
  }

  /// The chip's menu as it stands now.
  var brainMenu: EvieBrainMenu {
    EvieBrainMenu(
      profiles: brainResolver.configuration.profiles,
      choice: brainResolver.choice,
      pinned: brainResolver.pinnedProfile(for: activeConversationID),
      next: brainResolver.newConversationProfile
    )
  }

  /// A choice from the chip's menu, for every conversation not yet pinned.
  func chooseBrain(_ choice: EvieBrainChoice) {
    guard !hasActiveRequest, !isResearchBusy() else {
      presentRuntimeWarning("Pare a tarefa atual antes de trocar o cérebro.")
      return
    }
    // The menu's ticks come from the resolver, which publishes nothing.
    do {
      try onBrainChoiceChanged?(choice)
    } catch {
      presentRuntimeError(title: "Não consegui guardar a escolha do cérebro", error: error)
      return
    }
    objectWillChange.send()
    brainResolver.choose(choice, for: activeConversationID)
    contextUsageDescription = nil
    refreshBrainChip()
  }

  /// What the chip says about agent mode, set whenever the preference changes.
  func showAgentMode(_ isOn: Bool) {
    guard brainChip.isAgentModeOn != isOn else {
      return
    }
    brainChip.isAgentModeOn = isOn
  }

  /// The turn's brain, once resolved or failed over to: the status line's
  /// place, the chip, and the label on the answer being written.
  func adoptAnsweringBrain(_ brain: ResolvedBrain) {
    if answeringProfile.id != brain.profile.id { contextUsageDescription = nil }
    answeringProfile = brain.profile
    brainChip.profile = brain.profile
    brainChip.rung = brain.rung
    brainChipGeneration &+= 1
    labelActiveAnswer(with: brain.profile)
  }

  /// A turn ended. An answer proves the brain is up; a failure is asked
  /// about again, since whatever the cache said was just proved wrong.
  func brainTurnEnded(answered: Bool) {
    if answered {
      brainChip.rung = .ready
      brainChipGeneration &+= 1
    } else {
      refreshBrainChip()
    }
  }

  /// "Acordando o cérebro do Mac…" on the chip's dot as well as the status
  /// line.
  func showBrainWaking(_ waking: Bool) {
    brainChip.isWaking = waking
  }

  private func labelActiveAnswer(with profile: EvieModelProfile) {
    guard let id = activeArtifactID, let index = artifacts.firstIndex(where: { $0.id == id })
    else {
      return
    }
    artifacts[index].brainLabel = profile.answerLabel
  }

  /// Applies a probe's answer unless a newer refresh, a resolved turn or a
  /// change of conversation came after it. Returns whether it was applied.
  @discardableResult
  private func applyBrainStatus(
    _ status: (profile: EvieModelProfile, rung: ReadinessRung),
    generation: UInt64,
    conversation: UUID
  ) -> Bool {
    guard generation == brainChipGeneration, conversation == activeConversationID else {
      return false
    }
    brainChip.profile = status.profile
    brainChip.rung = status.rung
    return true
  }
}
