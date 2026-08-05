import AppKit
import AVFoundation
import EvieCore
import Foundation

/// The voices Evie can speak with, and the only place they are added or removed.
///
/// Two kinds live in one list on purpose. A system voice belongs to macOS and
/// cannot be deleted by an application, so removing one hides it from the picker
/// — the honest version, which stops offering it without pretending to have
/// deleted an operating-system file. A cloned voice belongs to the local engine
/// and removing one really does delete it.
@MainActor
final class EvieVoiceLibraryViewModel: ObservableObject {
  /// One voice as the list shows it.
  struct Entry: Identifiable, Hashable {
    enum Origin: Hashable {
      /// Installed by macOS. Removing hides it.
      case system
      /// Trained by the local engine. Removing deletes it.
      case cloned
    }

    var id: String
    var name: String
    var detail: String
    var origin: Origin
    var isHidden: Bool
    var isSelected: Bool
  }

  @Published private(set) var entries: [Entry] = []
  @Published private(set) var isEngineRunning = false
  @Published private(set) var isBusy = false
  @Published private(set) var feedback: Feedback?
  // The form for a new voice lives here rather than in the view: this toolchain
  // has no `@State`, and a view that cannot hold state has to be given somewhere
  // to put it.
  @Published var newVoiceName = ""
  @Published var newVoiceReferenceText = ""
  @Published private(set) var pendingAudioURL: URL?

  var pendingAudioName: String? {
    pendingAudioURL?.lastPathComponent
  }

  var canTrain: Bool {
    pendingAudioURL != nil
      && !newVoiceName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
      && !isBusy
  }

  struct Feedback: Equatable {
    var message: String
    var isError: Bool
  }

  private let engine = EvieOmniVoiceClient()
  private let preferences: () -> EvieVoicePreferences
  private let mutate: (@MainActor (inout EvieVoicePreferences) -> Void) -> Void

  init(
    preferences: @escaping () -> EvieVoicePreferences,
    mutate: @escaping (@MainActor (inout EvieVoicePreferences) -> Void) -> Void
  ) {
    self.preferences = preferences
    self.mutate = mutate
  }

  func refresh() async {
    isEngineRunning = await engine.isHealthy()
    let cloned = isEngineRunning ? await engine.voices() : []
    let voice = preferences()

    let systemEntries = EvieSpeechOutput.availableVoices().map { option in
      Entry(
        id: option.id,
        name: option.name,
        detail: option.isEnhanced ? "do sistema · natural" : "do sistema",
        origin: .system,
        isHidden: voice.hiddenVoiceIdentifiers.contains(option.id),
        isSelected: voice.clonedVoiceID == nil && voice.voiceIdentifier == option.id
      )
    }
    let clonedEntries = cloned.map { profile in
      Entry(
        id: profile.id,
        name: profile.name,
        detail: profile.language.isEmpty ? "treinada por você" : "treinada · \(profile.language)",
        origin: .cloned,
        isHidden: false,
        isSelected: voice.clonedVoiceID == profile.id
      )
    }
    // Trained voices first: they are the ones worth listening to, and the ones
    // the user made.
    entries = clonedEntries + systemEntries
  }

  func select(_ entry: Entry) {
    mutate { voice in
      switch entry.origin {
      case .cloned:
        voice.clonedVoiceID = entry.id
      case .system:
        voice.clonedVoiceID = nil
        voice.voiceIdentifier = entry.id
      }
    }
    Task { await refresh() }
  }

  /// Removes a voice: hidden if it belongs to macOS, deleted if Evie trained it.
  func remove(_ entry: Entry) {
    switch entry.origin {
    case .system:
      mutate { $0.hideVoice(identifier: entry.id) }
      feedback = Feedback(
        message: "\(entry.name) não aparece mais na lista. Dá para trazer de volta aqui mesmo.",
        isError: false
      )
      Task { await refresh() }

    case .cloned:
      isBusy = true
      Task { @MainActor in
        defer { isBusy = false }
        do {
          try await engine.deleteProfile(id: entry.id)
          if preferences().clonedVoiceID == entry.id {
            mutate { $0.clonedVoiceID = nil }
          }
          feedback = Feedback(message: "\(entry.name) foi apagada.", isError: false)
        } catch {
          feedback = Feedback(
            message: (error as? LocalizedError)?.errorDescription
              ?? "Não consegui apagar essa voz.",
            isError: true
          )
        }
        await refresh()
      }
    }
  }

  func restore(_ entry: Entry) {
    mutate { $0.showVoice(identifier: entry.id) }
    Task { await refresh() }
  }

  /// Trains a new voice from a recording the user picks.
  ///
  /// `referenceText` is what the recording says. Optional to the engine, and
  /// worth filling in: without it the voice's first use pays a one-off
  /// transcription pass measured at 23 seconds, in the middle of a conversation.
  func addVoice(named name: String, audioURL: URL, referenceText: String) {
    let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !trimmed.isEmpty else {
      feedback = Feedback(message: "Dê um nome para a voz.", isError: true)
      return
    }
    guard isEngineRunning else {
      feedback = Feedback(
        message: "O motor de voz não está no ar. Rode Scripts/evie-voice start e tente de novo.",
        isError: true
      )
      return
    }

    isBusy = true
    Task { @MainActor in
      defer { isBusy = false }
      do {
        let identifier = try await engine.createProfile(
          name: trimmed,
          audioURL: audioURL,
          referenceText: referenceText
        )
        mutate { $0.clonedVoiceID = identifier }
        feedback = Feedback(
          message: "\(trimmed) foi treinada e já está selecionada.",
          isError: false
        )
      } catch {
        feedback = Feedback(
          message: (error as? LocalizedError)?.errorDescription
            ?? "Não consegui treinar essa voz.",
          isError: true
        )
      }
      await refresh()
    }
  }

  /// Trains the voice the form describes.
  func trainPendingVoice() {
    guard let audioURL = pendingAudioURL else {
      feedback = Feedback(message: "Escolha primeiro um áudio de referência.", isError: true)
      return
    }
    addVoice(named: newVoiceName, audioURL: audioURL, referenceText: newVoiceReferenceText)
    newVoiceName = ""
    newVoiceReferenceText = ""
    pendingAudioURL = nil
  }

  func chooseAudio() {
    guard let url = pickAudio() else {
      return
    }
    pendingAudioURL = url
    if newVoiceName.isEmpty {
      newVoiceName = url.deletingPathExtension().lastPathComponent
    }
  }

  /// Asks for a recording, through the system panel.
  func pickAudio() -> URL? {
    let panel = NSOpenPanel()
    panel.canChooseFiles = true
    panel.canChooseDirectories = false
    panel.allowsMultipleSelection = false
    panel.allowedContentTypes = [.audio, .wav, .mp3, .mpeg4Audio, .aiff]
    panel.prompt = "Usar este áudio"
    panel.message = """
      Escolha uma gravação limpa da voz, de uns dez a trinta segundos, sem música \
      nem outra pessoa falando por cima.
      """
    guard panel.runModal() == .OK else {
      return nil
    }
    return panel.url
  }
}
