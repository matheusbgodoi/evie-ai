import AVFoundation
import EvieCore
import Foundation

/// Silent synthesis checks the real native boundary without surprising audio,
/// opening a microphone, starting a worker or reading a personal voice's name.
@MainActor
enum NativeVoiceCheck {
  struct Report: Encodable {
    let success: Bool
    let nativeVoices: Int
    let unavailableSiriVoices: Int
    let enhancedOrPremiumVoices: Int
    let personalVoiceAuthorization: String
    let selectedNativeVoice: String?
    let frames: Int
    let audioSeconds: Double
    let synthesisSeconds: Double
    let cancellationChecksPassed: Bool
    let wakeCalibrationStatus: String
    let wakeAliasCount: Int
    let syntheticSpeechAnalysisPassed: Bool
    let syntheticTranscript: String?
    let temporaryCalibrationPassed: Bool
    let syntheticWakeNameRecognized: Bool
    let speechAnalysisFailure: String?
    let warning: String?
  }

  static func run(installSpeechAssets: Bool = false) async -> Report {
    let options = NativeVoiceCatalog.options()
    let blocked = ["com.apple.siri.natural.Sandra", "com.apple.siri.natural.Nando"]
      .filter { AVSpeechSynthesisVoice(identifier: $0) == nil }.count
    let enhanced = options.filter(\.isEnhanced).count
    let cancelled = await checkCancellation()
    let wakeStatus: String
    let wakeAliasCount: Int
    do {
      if let calibration = try NativeWakeTrainingAccess.store.load() {
        wakeStatus = "valid"
        wakeAliasCount = calibration.aliases.count
      } else {
        wakeStatus = "notConfigured"
        wakeAliasCount = 0
      }
    } catch {
      wakeStatus = "invalid"
      wakeAliasCount = 0
    }
    guard let id = options.first?.id, let voice = AVSpeechSynthesisVoice(identifier: id) else {
      return Report(
        success: false, nativeVoices: 0, unavailableSiriVoices: blocked,
        enhancedOrPremiumVoices: enhanced,
        personalVoiceAuthorization: NativeVoiceCatalog.personalVoiceStatus,
        selectedNativeVoice: nil, frames: 0, audioSeconds: 0, synthesisSeconds: 0,
        cancellationChecksPassed: cancelled, wakeCalibrationStatus: wakeStatus,
        wakeAliasCount: wakeAliasCount, syntheticSpeechAnalysisPassed: false,
        syntheticTranscript: nil, temporaryCalibrationPassed: false,
        syntheticWakeNameRecognized: false,
        speechAnalysisFailure: "Sem áudio nativo para verificar.",
        warning: "Nenhuma voz pública pt-BR disponível.")
    }
    let synthesizer = AVSpeechSynthesizer()
    let collector = NativeSpeechBufferCollector()
    let utterance = AVSpeechUtterance(string: "Evie. Esta é uma frase de pesquisa.")
    utterance.voice = voice
    let started = ContinuousClock.now
    let deadline = Task { @MainActor in
      do { try await Task.sleep(for: .seconds(10)) } catch { return }
      collector.cancel()
      synthesizer.stopSpeaking(at: .immediate)
    }
    let buffers = await withCheckedContinuation { continuation in
      guard collector.begin(continuation) else { return }
      synthesizer.write(utterance) { collector.receive($0) }
    }
    deadline.cancel()
    let elapsed = started.duration(to: .now)
    let elapsedSeconds =
      Double(elapsed.components.seconds)
      + Double(elapsed.components.attoseconds) / 1e18
    let frames = buffers?.reduce(0) { $0 + Int($1.frameLength) } ?? 0
    let audioSeconds =
      buffers?.reduce(0) {
        $0 + Double($1.frameLength) / $1.format.sampleRate
      } ?? 0
    let roundTrip = await checkSpeechAnalysis(
      buffers ?? [], installSpeechAssets: installSpeechAssets)
    return Report(
      success: frames > 0 && cancelled && roundTrip.analysisPassed && roundTrip.calibrationPassed,
      nativeVoices: options.count,
      unavailableSiriVoices: blocked, enhancedOrPremiumVoices: enhanced,
      personalVoiceAuthorization: NativeVoiceCatalog.personalVoiceStatus,
      selectedNativeVoice: id, frames: frames, audioSeconds: audioSeconds,
      synthesisSeconds: elapsedSeconds, cancellationChecksPassed: cancelled,
      wakeCalibrationStatus: wakeStatus, wakeAliasCount: wakeAliasCount,
      syntheticSpeechAnalysisPassed: roundTrip.analysisPassed,
      syntheticTranscript: roundTrip.transcript,
      temporaryCalibrationPassed: roundTrip.calibrationPassed,
      syntheticWakeNameRecognized: roundTrip.wakeNameRecognized,
      speechAnalysisFailure: roundTrip.failure,
      warning: enhanced == 0
        ? "Nenhuma voz pública aprimorada ou premium pt-BR instalada; a qualidade atual é a voz padrão do macOS."
        : nil)
  }

  private struct SpeechRoundTrip {
    let analysisPassed: Bool
    let calibrationPassed: Bool
    let transcript: String?
    let failure: String?
    var wakeNameRecognized = false
  }

  private static func checkSpeechAnalysis(
    _ buffers: [AVAudioPCMBuffer], installSpeechAssets: Bool
  ) async -> SpeechRoundTrip {
    guard let format = buffers.first(where: { $0.frameLength > 0 })?.format else {
      return SpeechRoundTrip(
        analysisPassed: false, calibrationPassed: false, transcript: nil,
        failure: "Síntese sem áudio.")
    }
    let availability = await EvieSpeechTranscription.availability(for: Locale(identifier: "pt-BR"))
    guard availability == .ready || (installSpeechAssets && availability == .needsDownload) else {
      return SpeechRoundTrip(
        analysisPassed: false, calibrationPassed: false, transcript: nil,
        failure: availability.message)
    }
    let recognizer = EvieSpeechTranscription()
    var timedOut = false
    let analysis = Task { @MainActor in
      let pump = try await recognizer.start(inputFormat: format)
      try Task.checkCancellation()
      for buffer in buffers { pump.receive(buffer) }
      let text = await recognizer.finish()
      try Task.checkCancellation()
      return text
    }
    let deadlineSeconds = installSpeechAssets ? 120 : 15
    let deadline = Task { @MainActor in
      do { try await Task.sleep(for: .seconds(deadlineSeconds)) } catch { return }
      timedOut = true
      analysis.cancel()
      await recognizer.cancel()
    }
    defer { deadline.cancel() }
    do {
      let transcript = try await analysis.value
      guard !timedOut else {
        return SpeechRoundTrip(
          analysisPassed: false, calibrationPassed: false, transcript: nil,
          failure: "A transcrição sintética excedeu o prazo de \(deadlineSeconds) segundos.")
      }
      let normalized = transcript.folding(
        options: [.diacriticInsensitive, .caseInsensitive], locale: Locale(identifier: "pt-BR"))
      let analysisPassed = normalized.contains("frase") && normalized.contains("pesquisa")
      let words = transcript.split(whereSeparator: { $0.isWhitespace || $0.isPunctuation })
      guard !words.isEmpty else {
        return SpeechRoundTrip(
          analysisPassed: false, calibrationPassed: false, transcript: transcript,
          failure: "O reconhecedor não retornou texto para o áudio sintético.")
      }
      let alias = (1...min(3, words.count)).lazy.compactMap { count in
        try? EvieWakeEnrollment.acceptedAlias(words.prefix(count).joined(separator: " "))
      }.first
      let directory = FileManager.default.temporaryDirectory.appendingPathComponent(
        UUID().uuidString)
      defer { try? FileManager.default.removeItem(at: directory) }
      let store = EvieWakeEnrollmentStore(
        fileURL: directory.appendingPathComponent("synthetic-wake.json"))
      // Controlled synthetic transcripts exercise the calibration contract,
      // independently of whether TTS pronounces the invented name recognizably.
      // This is not enrollment of the owner's voice or five recognized calls.
      let syntheticSamples = ["Evie", "Evi", "Ivi", "E vi", "Ívie"]
      try store.save(EvieWakeEnrollment(samples: syntheticSamples))
      let restored = try store.load()
      let calibrationPassed =
        syntheticSamples.allSatisfy { restored?.matches($0) == true }
        && restored?.matches("hoje eu vi") == false
      return SpeechRoundTrip(
        analysisPassed: analysisPassed, calibrationPassed: calibrationPassed,
        transcript: transcript,
        failure: analysisPassed && calibrationPassed
          ? nil : "A frase sintética não completou o percurso de voz e calibração.",
        wakeNameRecognized: alias != nil)
    } catch {
      await recognizer.cancel()
      return SpeechRoundTrip(
        analysisPassed: false, calibrationPassed: false, transcript: nil,
        failure: "Não foi possível analisar a fala sintética pelo macOS.")
    }
  }

  private static func checkCancellation() async -> Bool {
    let beforeBegin = NativeSpeechBufferCollector()
    beforeBegin.cancel()
    let early = await withCheckedContinuation { continuation in
      _ = beforeBegin.begin(continuation)
    }
    let afterBegin = NativeSpeechBufferCollector()
    let later = await withCheckedContinuation { continuation in
      _ = afterBegin.begin(continuation)
      afterBegin.cancel()
      afterBegin.cancel()
    }
    return early == nil && later == nil
  }
}
