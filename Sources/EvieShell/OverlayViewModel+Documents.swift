import AppKit
import EvieCore
import Foundation

// The cards that come out of a turn about files: a well-known folder to
// permit, a document to save, a file she opened. ADR 0019.

/// What the file cards on screen are waiting on, so a button press knows what
/// it means. Memory only.
struct EvieFileCards {
  /// Document cards, by card.
  var documents: [UUID: EvieDocumentProposal] = [:]
  /// Documents for a well-known folder not granted yet, held until its card is
  /// answered.
  var awaitingRoot: [EvieSuggestedRoot: [EvieDocumentProposal]] = [:]
  /// "Permitir que a Evie leia…" cards, by card.
  var suggestions: [UUID: EvieSuggestedRoot] = [:]
  /// Saved documents, for their Abrir and Mostrar no Finder buttons.
  var saved: [UUID: URL] = [:]
}

/// Opens with `NSWorkspace`. The agent loop holds it only as `EvieFileOpening`,
/// after `EvieOpenTool` has checked the place and the kind of file.
struct EvieWorkspaceOpener: EvieFileOpening {
  func open(_ url: URL) async -> Bool {
    await MainActor.run { NSWorkspace.shared.open(url) }
  }

  func reveal(_ url: URL) async -> Bool {
    await MainActor.run {
      NSWorkspace.shared.activateFileViewerSelecting([url])
      return true
    }
  }
}

extension OverlayViewModel {
  static var homeURL: URL { FileManager.default.homeDirectoryForCurrentUser }

  /// What a turn's loop produced about files, put on screen.
  ///
  /// `savesDirectly` is ADR 0019's narrow policy, already reduced to one
  /// Boolean by the caller: switched on, asked for in the person's own
  /// message, no picture in the request. Even then only a new file in a folder
  /// granted *before* this turn is saved without its card; one that needed a
  /// folder permitted first always waits for Salvar.
  func presentFileOutcome(
    _ outcome: EvieAgentLoop.Outcome,
    question: String,
    savesDirectly: Bool
  ) {
    for action in outcome.fileActions {
      artifacts.append(
        ArtifactCardModel(
          kind: .file,
          title: action.summary,
          summary: action.kind == .opened
            ? "Em \(action.placeName), no app padrão."
            : "Em \(action.placeName). A janela do Finder está aberta.",
          isExpanded: false
        )
      )
    }

    var requested = outcome.rootRequests
    for proposal in outcome.documentProposals {
      switch EvieSuggestedRoot.lookup(proposal.destination, in: grantedRoots(), home: Self.homeURL) {
      case .granted:
        if savesDirectly {
          saveDocument(proposal, opening: false, wasAutomatic: true)
        } else {
          presentDocumentProposal(proposal)
        }
      case .notGranted(let suggestion):
        fileCards.awaitingRoot[suggestion, default: []].append(proposal)
        if !requested.contains(suggestion) {
          requested.append(suggestion)
        }
      case .unknown:
        break
      }
    }

    // His own words count too: "o que tem na minha mesa?" offers the Mesa even
    // when the model answered without naming it.
    for mentioned in EvieSuggestedRoot.mentioned(in: question) where !requested.contains(mentioned) {
      requested.append(mentioned)
    }
    let ungranted = EvieSuggestedRoot.ungranted(in: grantedRoots(), home: Self.homeURL)
    for suggestion in requested where ungranted.contains(suggestion) {
      presentRootSuggestion(suggestion)
    }
    onLayoutInvalidated?()
  }

  /// "Permitir que a Evie leia sua Mesa", with one button.
  func presentRootSuggestion(_ suggestion: EvieSuggestedRoot) {
    guard !fileCards.suggestions.values.contains(suggestion) else {
      return
    }
    let card = UUID()
    fileCards.suggestions[card] = suggestion
    artifacts.append(
      ArtifactCardModel(
        id: card,
        kind: .approval,
        title: suggestion.grantTitle,
        summary: suggestion.grantExplanation,
        isExpanded: true,
        actions: [
          ArtifactActionModel(
            id: "root-grant:\(card.uuidString)",
            title: "Permitir",
            systemImage: "folder.badge.plus",
            role: .primary
          )
        ]
      )
    )
  }

  /// A document waiting to be saved: its name, where it lands, the opening of
  /// the text, and two buttons. Nothing is on disk until one is pressed.
  func presentDocumentProposal(_ proposal: EvieDocumentProposal) {
    let rootName = documentRoot(for: proposal)?.displayName ?? proposal.destination
    fileCards.documents[proposal.id] = proposal
    artifacts.append(
      ArtifactCardModel(
        id: proposal.id,
        kind: .file,
        title: "Salvar \(proposal.fileName())",
        summary: "Em \(proposal.place(rootName: rootName)) · \(proposal.format.label)\n\n"
          + proposal.preview,
        isExpanded: true,
        actions: [
          ArtifactActionModel(
            id: "doc-save:\(proposal.id.uuidString)",
            title: "Salvar",
            systemImage: "square.and.arrow.down",
            role: .primary
          ),
          ArtifactActionModel(
            id: "doc-save-open:\(proposal.id.uuidString)",
            title: "Salvar e abrir",
            systemImage: "arrow.up.forward.app",
            role: .secondary
          ),
        ]
      )
    )
    onLayoutInvalidated?()
  }

  /// The folder a proposal lands in, resolved against what is granted now.
  func documentRoot(for proposal: EvieDocumentProposal) -> EvieFileRoot? {
    if case .granted(let root) = EvieSuggestedRoot.lookup(
      proposal.destination, in: grantedRoots(), home: Self.homeURL)
    {
      return root
    }
    return nil
  }

  /// Writes the document as a new file and says where it went — exactly as
  /// loudly when nobody pressed a button.
  func saveDocument(_ proposal: EvieDocumentProposal, opening: Bool, wasAutomatic: Bool) {
    fileCards.documents[proposal.id] = nil
    guard let root = documentRoot(for: proposal) else {
      artifacts.append(
        ArtifactCardModel(
          kind: .error,
          title: "Não salvei \(proposal.fileName())",
          summary: "Essa pasta não está mais autorizada, então não gravei nada.",
          isExpanded: true
        )
      )
      onLayoutInvalidated?()
      return
    }

    do {
      let receipt = try EvieDocumentCreator().create(proposal, in: root)
      let card = UUID()
      fileCards.saved[card] = receipt.url
      let place = proposal.place(rootName: root.displayName)
      var summary = "Em \(place)."
      if receipt.fileName != proposal.fileName() {
        summary += " Já existia um \(proposal.fileName()), então este é um arquivo novo ao lado."
      }
      if wasAutomatic {
        summary +=
          "\n\nVocê pediu para salvar na sua mensagem, e salvar direto está ligado. "
          + "Desligue em Configurações › Pastas."
      }
      artifacts.append(
        ArtifactCardModel(
          id: card,
          kind: .file,
          title: wasAutomatic ? "Salvei \(receipt.fileName) sem te perguntar" : "Salvei \(receipt.fileName)",
          summary: summary,
          isExpanded: true,
          actions: [
            ArtifactActionModel(
              id: "doc-open:\(card.uuidString)", title: "Abrir",
              systemImage: "arrow.up.forward.app", role: .secondary),
            ArtifactActionModel(
              id: "doc-reveal:\(card.uuidString)", title: "Mostrar no Finder",
              systemImage: "folder", role: .secondary),
          ]
        )
      )
      primaryText = "Documento salvo"
      secondaryText = place
      if opening {
        NSWorkspace.shared.open(receipt.url)
      }
    } catch {
      artifacts.append(
        ArtifactCardModel(
          kind: .error,
          title: "Não salvei \(proposal.fileName())",
          summary: (error as? LocalizedError)?.errorDescription ?? "Não consegui salvar.",
          isExpanded: true
        )
      )
    }
    onLayoutInvalidated?()
  }

  /// The buttons on file cards. Returns whether the action was one of them.
  func handleFileCardAction(_ id: UUID, action: ArtifactActionModel) -> Bool {
    if action.id.hasPrefix("root-grant:") {
      artifacts.removeAll { $0.id == id }
      if let suggestion = fileCards.suggestions.removeValue(forKey: id) {
        grantRootSuggestion(suggestion)
      }
      onLayoutInvalidated?()
      return true
    }
    if action.id.hasPrefix("doc-save:") || action.id.hasPrefix("doc-save-open:") {
      artifacts.removeAll { $0.id == id }
      if let proposal = fileCards.documents[id] {
        saveDocument(proposal, opening: action.id.hasPrefix("doc-save-open:"), wasAutomatic: false)
      }
      return true
    }
    if action.id.hasPrefix("doc-open:") || action.id.hasPrefix("doc-reveal:") {
      if let url = fileCards.saved[id] {
        if action.id.hasPrefix("doc-open:") {
          NSWorkspace.shared.open(url)
        } else {
          NSWorkspace.shared.activateFileViewerSelecting([url])
        }
      }
      return true
    }
    return false
  }

  /// Closing a file card is a no: the folder stays ungranted, the document
  /// unsaved, and a document held for that folder is dropped with it.
  func dismissFileCard(_ id: UUID) {
    fileCards.documents[id] = nil
    fileCards.saved[id] = nil
    if let suggestion = fileCards.suggestions.removeValue(forKey: id) {
      fileCards.awaitingRoot[suggestion] = nil
    }
  }

  /// The press on "Permitir": grants the fixed folder, then puts on screen the
  /// documents that were waiting for it — still as cards, never saved directly,
  /// because the folder was not granted when he asked.
  func grantRootSuggestion(_ suggestion: EvieSuggestedRoot) {
    guard let grantSuggestedRoot, grantSuggestedRoot(suggestion) else {
      primaryText = "Não consegui permitir \(suggestion.displayName)"
      secondaryText = "Tente em Configurações › Pastas"
      return
    }
    primaryText = "\(suggestion.displayName) permitida"
    let held = fileCards.awaitingRoot.removeValue(forKey: suggestion) ?? []
    secondaryText =
      held.isEmpty
      ? "Pode pedir de novo — agora ela consegue olhar lá"
      : "O documento está logo abaixo, esperando você salvar"
    for proposal in held {
      presentDocumentProposal(proposal)
    }
  }
}
