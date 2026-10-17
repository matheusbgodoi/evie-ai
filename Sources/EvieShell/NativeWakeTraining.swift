import AVFoundation
import EvieCore
import Foundation
import SwiftUI

/// Coordinator hooks keep the microphone exclusive and suppress the wake
/// listener while the explicit calibration sheet owns the interaction.
@MainActor
enum NativeWakeTrainingAccess {
  static var onAcquire: (() throws -> Void)?
  static var onRelease: (() -> Void)?
  static var onSaved: (() throws -> Void)?
  private(set) static var isActive = false
  static var cancelActive: (() -> Void)?
  static var store = EvieWakeEnrollmentStore(
    fileURL: EvieConfigurationLoader.defaultFileURL.deletingLastPathComponent()
      .appendingPathComponent("wake-enrollment.json"))

  static func acquire() throws {
    guard !isActive else { throw NativeAppleError.busy }
    guard let onAcquire else { throw NativeAppleError.notReady }
    try onAcquire()
    isActive = true
  }

  static func release() {
    guard isActive else { return }
    isActive = false
    cancelActive = nil
    onRelease?()
  }

  static func stop() { cancelActive?() }

  static func enrollment(for configuredPhrase: String) -> EvieWakeEnrollment? {
    guard EvieWakePhrase.normalize(configuredPhrase) == "evie" else { return nil }
    return try? store.load()
  }
}

@MainActor
final class NativeWakeTrainingModel: ObservableObject {
  enum Phase: Equatable { case ready, preparing, recording, processing, saved }
  @Published private(set) var phase = Phase.ready
  @Published private(set) var samples: [String] = []
  @Published private(set) var preview = ""
  @Published private(set) var error: String?
  private var capture: EvieAudioCapture?
  private var recognizer: EvieSpeechTranscription?
  private var task: Task<Void, Never>?
  private var generation = UUID()
  private var ownsSession = false
  private var finishRequested = false

  var isRecording: Bool { phase == .recording }
  var isBusy: Bool { phase == .preparing || phase == .recording || phase == .processing }
  var isComplete: Bool { samples.count == EvieWakeEnrollment.sampleCount }

  func record() {
    guard !isBusy, !isComplete, phase != .saved else { return }
    error = nil
    do {
      if !ownsSession {
        try NativeWakeTrainingAccess.acquire()
        ownsSession = true
        NativeWakeTrainingAccess.cancelActive = { [weak self] in self?.cancel() }
      }
    } catch {
      self.error = error.localizedDescription
      return
    }
    let id = UUID()
    generation = id
    finishRequested = false
    preview = ""
    phase = .preparing
    task = Task { @MainActor [weak self] in
      guard let self else { return }
      let microphone = EvieAudioCapture()
      let recognizer = EvieSpeechTranscription()
      capture = microphone
      self.recognizer = recognizer
      do {
        let format = try await microphone.prepareInputFormat()
        try Task.checkCancellation()
        let pump = try await recognizer.start(inputFormat: format)
        try Task.checkCancellation()
        recognizer.onTranscriptChanged = { [weak self] settled, volatile in
          guard let self, generation == id else { return }
          preview = (settled + " " + volatile).trimmingCharacters(in: .whitespacesAndNewlines)
        }
        try await microphone.start(sink: pump)
        try Task.checkCancellation()
        phase = .recording
        // A bounded recording; no timer or microphone exists between samples.
        for _ in 0..<50 {
          if finishRequested { break }
          try await Task.sleep(for: .milliseconds(100))
        }
        microphone.stop()
        phase = .processing
        let transcript = await recognizer.finish()
        try Task.checkCancellation()
        guard generation == id else { return }
        _ = try EvieWakeEnrollment.acceptedAlias(transcript)
        samples.append(transcript)
        preview = ""
        phase = .ready
      } catch {
        microphone.stop()
        await recognizer.cancel()
        guard generation == id, !Task.isCancelled else { return }
        self.error = error.localizedDescription
        phase = .ready
      }
      if generation == id {
        capture = nil
        self.recognizer = nil
        task = nil
      }
    }
  }

  func finishRecording() { finishRequested = true }

  func repeatLast() {
    guard !isBusy, !samples.isEmpty, phase != .saved else { return }
    samples.removeLast()
    error = nil
  }

  func save() {
    guard isComplete, !isBusy, phase != .saved else { return }
    do {
      let record = try EvieWakeEnrollment(samples: samples)
      let previous: EvieWakeEnrollment?
      do { previous = try NativeWakeTrainingAccess.store.load() } catch is DecodingError {
        previous = nil
      } catch EvieWakeEnrollment.Problem.invalidRecord { previous = nil }
      try NativeWakeTrainingAccess.store.save(record)
      do {
        guard let apply = NativeWakeTrainingAccess.onSaved else { throw NativeAppleError.notReady }
        try apply()
      } catch {
        let saveFailure = error
        do {
          if let previous {
            try NativeWakeTrainingAccess.store.save(previous)
          } else {
            try NativeWakeTrainingAccess.store.remove()
          }
        } catch {
          self.error = "Não consegui aplicar nem restaurar a calibração. Tente salvar novamente."
          return
        }
        throw saveFailure
      }
      phase = .saved
      release()
    } catch { self.error = error.localizedDescription }
  }

  func cancel() {
    generation = UUID()
    task?.cancel()
    task = nil
    capture?.stop()
    capture = nil
    let recognizer = recognizer
    self.recognizer = nil
    let releasesSession = ownsSession
    ownsSession = false
    preview = ""
    phase = .ready
    Task { @MainActor in
      await recognizer?.cancel()
      if releasesSession { NativeWakeTrainingAccess.release() }
    }
  }

  private func release() {
    guard ownsSession else { return }
    ownsSession = false
    NativeWakeTrainingAccess.release()
  }
}

struct NativeWakeTrainingView: View {
  @StateObject private var model = NativeWakeTrainingModel()
  @Environment(\.dismiss) private var dismiss

  var body: some View {
    VStack(alignment: .leading, spacing: 18) {
      Label("Chame a Evie do seu jeito", systemImage: "waveform.badge.mic")
        .font(.title2.weight(.semibold))
      Text(
        "Grave cinco chamadas dizendo apenas “Evie”, na distância em que você costuma usar o Mac. Confira a transcrição de cada uma antes de salvar."
      )
      .foregroundStyle(.secondary)
      Text("\(model.samples.count) de \(EvieWakeEnrollment.sampleCount) chamadas")
        .font(.headline)
      ProgressView(
        value: Double(model.samples.count), total: Double(EvieWakeEnrollment.sampleCount))
      ForEach(Array(model.samples.enumerated()), id: \.offset) { index, sample in
        Label("\(index + 1). \(sample)", systemImage: "checkmark.circle.fill")
          .foregroundStyle(.secondary)
      }
      if model.isBusy {
        HStack {
          ProgressView().controlSize(.small)
          Text(model.isRecording ? "Ouvindo por até 5 segundos…" : "Preparando a transcrição…")
        }
        if !model.preview.isEmpty { Text(model.preview).font(.callout.monospaced()) }
      }
      if let error = model.error {
        Label(error, systemImage: "exclamationmark.triangle").foregroundStyle(.orange)
      }
      if model.phase == .saved {
        Label(
          "Calibração salva. Agora você pode chamar “Evie”.", systemImage: "checkmark.seal.fill")
      }
      Spacer(minLength: 0)
      Text(
        "Processamento local pelo reconhecimento de fala do macOS. Guardamos apenas as variantes reconhecidas; nenhum áudio é salvo. Isto calibra a palavra, não identifica sua voz nem treina a Siri."
      )
      .font(.caption).foregroundStyle(.secondary)
      HStack {
        Button(model.phase == .saved ? "Concluir" : "Cancelar") {
          model.cancel()
          dismiss()
        }
        Spacer()
        if model.isRecording {
          Button("Concluir gravação") { model.finishRecording() }.buttonStyle(.borderedProminent)
        } else if model.phase != .saved {
          if !model.samples.isEmpty {
            Button("Repetir última") { model.repeatLast() }.disabled(model.isBusy)
          }
          if model.isComplete {
            Button("Salvar calibração") { model.save() }.buttonStyle(.borderedProminent)
          } else {
            Button("Gravar chamada \(model.samples.count + 1)") { model.record() }
              .buttonStyle(.borderedProminent).disabled(model.isBusy)
          }
        }
      }
    }
    .padding(24).frame(width: 530, height: 550)
    .interactiveDismissDisabled(model.isBusy)
    .onDisappear { model.cancel() }
  }
}
