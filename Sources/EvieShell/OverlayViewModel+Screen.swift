import AppKit
import EvieCore
import Foundation
import ImageIO

// Looking at the screen: the capture a question asks for, the one the
// shortcut takes ahead of the question, and what a brain that cannot see is
// given instead of the picture.

extension OverlayViewModel {
  /// Captures the screen for the turn `requestID`, or ends that turn and
  /// returns `nil`: with the settings card when Screen Recording is not
  /// allowed, with the reason otherwise.
  func lookForTurn(_ request: EvieScreenLook.Request, requestID: UUID) async -> CapturedScreen? {
    guard let screenLook else {
      finishFailure(
        EvieFailure(kind: .unavailable, message: "Olhar a tela não está disponível nesta versão."),
        requestID: requestID
      )
      return nil
    }
    primaryText = "Olhando a tela…"
    onLayoutInvalidated?()
    do {
      let screen = try await screenLook.look(request, maxLongEdge: pictureLongEdge)
      try Task.checkCancellation()
      guard activeRequestID == requestID else {
        return nil
      }
      primaryText = "Pensando…"
      onLayoutInvalidated?()
      return screen
    } catch is CancellationError {
      finishCancellation(requestID: requestID)
    } catch EvieScreenLookError.permissionNeeded {
      finishFailure(
        Self.screenPermissionFailure,
        requestID: requestID,
        title: EvieScreenLookCopy.permissionTitle,
        actions: [Self.openScreenSettingsAction]
      )
    } catch {
      finishFailure(
        EvieFailure(
          kind: .unavailable,
          message: (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
        ),
        requestID: requestID,
        title: "Não consegui olhar a tela"
      )
    }
    return nil
  }

  /// The shortcut: captures the screen under the pointer now and holds it for
  /// the next question, which is sent with it.
  func captureScreenForNextQuestion() {
    guard !hasActiveRequest, !isResearchBusy() else {
      primaryText = "Aguarde ou cancele a consulta atual"
      onLayoutInvalidated?()
      return
    }
    guard let screenLook else {
      presentRuntimeWarning("Olhar a tela não está disponível nesta versão.")
      return
    }
    screenLookTask?.cancel()
    screenLookTask = Task { @MainActor [weak self] in
      guard let self else { return }
      do {
        let screen = try await screenLook.look(.screenUnderPointer, maxLongEdge: pictureLongEdge)
        try Task.checkCancellation()
        pendingScreen = screen
        isQuickTextEntryPresented = true
        visualState = .ready
        primaryText = "Tela capturada"
        secondaryText = EvieScreenLookCopy.captured
      } catch is CancellationError {
        return
      } catch EvieScreenLookError.permissionNeeded {
        artifacts.append(
          ArtifactCardModel(
            kind: .error,
            title: EvieScreenLookCopy.permissionTitle,
            summary: EvieScreenLookCopy.permissionSummary,
            detail: EvieScreenLookCopy.permissionDetail,
            isExpanded: true,
            actions: [Self.openScreenSettingsAction]
          )
        )
      } catch {
        presentRuntimeWarning(
          (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
        )
      }
      screenLookTask = nil
      onLayoutInvalidated?()
    }
  }

  /// Drops every picture of the screen this conversation still holds in
  /// memory: the one waiting for a question and the one being replayed.
  func forgetScreenPictures() {
    pendingScreen = nil
    screenLookTask?.cancel()
    screenLookTask = nil
    sentPictureTurn = nil
    sendingPictureTurn = nil
    screenFallbackText = nil
  }

  /// The pictures a turn sends on `plan`'s brain: the capture first, then any
  /// pasted ones. A brain that cannot see gets the capture's recognised text
  /// and description instead, read once per capture.
  func pictures(for turn: PreparedTurn, on plan: EvieTurnPlan) async -> EvieTurnPictures {
    var pictures = turn.pictures
    guard let screen = turn.screen else {
      return pictures
    }
    pictures.images.insert(screen.image, at: 0)
    guard !plan.profile.capabilities.vision else {
      return pictures
    }
    let screenText = await screenFallback(for: screen.image)
    let texts = [screenText, pictures.textFallback].compactMap { $0 }
    pictures.textFallback = texts.isEmpty ? nil : texts.joined(separator: "\n\n")
    return pictures
  }

  /// OCR and the system describer over the capture itself — the JPEG in
  /// memory, never a file.
  func screenFallback(for image: EvieImagePart) async -> String? {
    if let cached = screenFallbackText, cached.imageID == image.id {
      return cached.text
    }
    primaryText = "Lendo a tela…"
    onLayoutInvalidated?()
    guard let source = CGImageSourceCreateWithData(image.data as CFData, nil),
      let picture = CGImageSourceCreateImageAtIndex(source, 0, nil)
    else {
      return nil
    }
    let name = "captura da tela"
    let read = try? await documentReader.read(picture, sourceName: name)
    let seen = try? await visionDescriber.describe(picture)
    let text = EvieTurnPictures.fallbackEvidence(
      seen: seen.map { [(name: name, description: $0)] } ?? [],
      read: read.map { [$0] } ?? []
    )
    screenFallbackText = (image.id, text)
    primaryText = "Pensando…"
    onLayoutInvalidated?()
    return text
  }

  static let openScreenSettingsAction = ArtifactActionModel(
    id: "screen-settings",
    title: EvieScreenLookCopy.openSettingsTitle,
    systemImage: "gearshape",
    role: .secondary
  )

  static let screenPermissionFailure = EvieFailure(
    kind: .permissionDenied,
    message: EvieScreenLookCopy.permissionSummary,
    recoverySuggestion: EvieScreenLookCopy.permissionDetail
  )
}
