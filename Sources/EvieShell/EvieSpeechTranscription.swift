import AVFoundation
import Foundation
import Speech
import Synchronization

/// Turns what the microphone hears into text, using the system's own recogniser.
///
/// The choice matters for this machine specifically: the model runs in a system
/// daemon rather than inside Evie, so it does not compete with the 26B model for
/// the 24 GB of unified memory that is the real constraint here. It also supports
/// Brazilian Portuguese, streams partial results, reports per-result confidence,
/// and can be told to release its model when idle.
@available(macOS 26, *)
@MainActor
final class EvieSpeechTranscription {
  /// Text confirmed by the recogniser and no longer subject to revision.
  private(set) var settledText = ""
  /// The current guess, which may still change. Never treated as an instruction.
  private(set) var volatileText = ""

  var onTranscriptChanged: (@MainActor (_ settled: String, _ volatile: String) -> Void)?

  private let locale: Locale
  private var analyzer: SpeechAnalyzer?
  private var transcriber: SpeechTranscriber?
  private var continuation: AsyncStream<AnalyzerInput>.Continuation?
  private var resultsTask: Task<Void, Never>?

  init(locale: Locale = Locale(identifier: "pt-BR")) {
    self.locale = locale
  }

  static var isSupported: Bool {
    SpeechTranscriber.isAvailable
  }

  enum TranscriptionError: LocalizedError {
    case unsupportedLocale(String)
    case noCompatibleFormat
    case converterUnavailable

    var errorDescription: String? {
      switch self {
      case .unsupportedLocale(let identifier):
        "O reconhecimento de fala deste Mac não cobre \(identifier)."
      case .noCompatibleFormat:
        "Não consegui um formato de áudio compatível com o reconhecimento."
      case .converterUnavailable:
        "Não consegui converter o áudio do microfone para o reconhecimento."
      }
    }
  }

  /// Whether this Mac can transcribe the configured language, and whether doing
  /// so would first need a download.
  static func availability(for locale: Locale) async -> Availability {
    guard SpeechTranscriber.isAvailable else {
      return .unsupported
    }
    guard await SpeechTranscriber.supportedLocale(equivalentTo: locale) != nil else {
      return .localeUnsupported
    }
    let probe = SpeechTranscriber(locale: locale, preset: .progressiveTranscription)
    switch await AssetInventory.status(forModules: [probe]) {
    case .installed: return .ready
    case .downloading: return .downloading
    case .supported: return .needsDownload
    case .unsupported: return .localeUnsupported
    @unknown default: return .unsupported
    }
  }

  enum Availability: Equatable, Sendable {
    case ready
    case needsDownload
    case downloading
    case localeUnsupported
    case unsupported

    var message: String {
      switch self {
      case .ready: "Pronta para transcrever."
      case .needsDownload: "A primeira transcrição vai baixar o pacote de idioma."
      case .downloading: "O pacote de idioma está sendo baixado."
      case .localeUnsupported: "Este Mac não transcreve este idioma."
      case .unsupported: "Este Mac não tem reconhecimento de fala disponível."
      }
    }
  }

  /// Prepares the recogniser and returns the pump the audio tap should feed.
  ///
  /// The asset install runs here rather than lazily, so the first spoken sentence
  /// does not disappear into a silent download.
  func start(inputFormat: AVAudioFormat) async throws -> AnalyzerInputPump {
    settledText = ""
    volatileText = ""

    guard let resolvedLocale = await SpeechTranscriber.supportedLocale(equivalentTo: locale)
    else {
      throw TranscriptionError.unsupportedLocale(locale.identifier)
    }

    let transcriber = SpeechTranscriber(
      locale: resolvedLocale,
      transcriptionOptions: [],
      reportingOptions: [.volatileResults, .fastResults],
      attributeOptions: [.transcriptionConfidence]
    )

    if await AssetInventory.status(forModules: [transcriber]) != .installed,
      let request = try await AssetInventory.assetInstallationRequest(
        supporting: [transcriber]
      )
    {
      try await request.downloadAndInstall()
    }

    guard
      let analyzerFormat = await SpeechAnalyzer.bestAvailableAudioFormat(
        compatibleWith: [transcriber]
      )
    else {
      throw TranscriptionError.noCompatibleFormat
    }

    let (stream, continuation) = AsyncStream<AnalyzerInput>.makeStream()
    let analyzer = SpeechAnalyzer(modules: [transcriber])
    try await analyzer.start(inputSequence: stream)

    self.analyzer = analyzer
    self.transcriber = transcriber
    self.continuation = continuation
    observeResults(from: transcriber)

    guard
      let pump = AnalyzerInputPump(
        inputFormat: inputFormat,
        analyzerFormat: analyzerFormat,
        continuation: continuation
      )
    else {
      throw TranscriptionError.converterUnavailable
    }
    return pump
  }

  /// Closes the input, waits for the recogniser to settle, and returns what it
  /// heard. A volatile fragment left over at the end is discarded rather than
  /// submitted: a guess must not become a question.
  func finish() async -> String {
    continuation?.finish()
    continuation = nil

    try? await analyzer?.finalizeAndFinishThroughEndOfInput()
    await resultsTask?.value
    resultsTask = nil
    analyzer = nil
    transcriber = nil

    let transcript = settledText.trimmingCharacters(in: .whitespacesAndNewlines)
    volatileText = ""
    // The system model lives in a daemon; this is what lets it go.
    await SpeechModels.endRetention()
    return transcript
  }

  func cancel() async {
    continuation?.finish()
    continuation = nil
    resultsTask?.cancel()
    resultsTask = nil
    await analyzer?.cancelAndFinishNow()
    analyzer = nil
    transcriber = nil
    settledText = ""
    volatileText = ""
    await SpeechModels.endRetention()
  }

  private func observeResults(from transcriber: SpeechTranscriber) {
    resultsTask = Task { @MainActor [weak self] in
      do {
        for try await result in transcriber.results {
          guard let self else { return }
          let text = String(result.text.characters)
          if result.isFinal {
            settledText += settledText.isEmpty ? text : " \(text)"
            volatileText = ""
          } else {
            volatileText = text
          }
          onTranscriptChanged?(settledText, volatileText)
        }
      } catch {
        // A failed stream is not a transcript. Whatever settled before the error
        // is kept; nothing is invented to replace what was lost.
        self?.volatileText = ""
      }
    }
  }
}

/// Converts microphone buffers into the format the recogniser asked for and
/// feeds them in.
///
/// It is used from the audio thread, so it holds a lock around the converter and
/// does nothing that can block. Marked unchecked because `AVAudioConverter` and
/// `AVAudioFormat` predate `Sendable`; every use of them here is serialised.
@available(macOS 26, *)
final class AnalyzerInputPump: EvieAudioBufferSink, @unchecked Sendable {
  private let converter: Mutex<AVAudioConverter>
  private let analyzerFormat: AVAudioFormat
  private let ratio: Double
  private let continuation: AsyncStream<AnalyzerInput>.Continuation

  init?(
    inputFormat: AVAudioFormat,
    analyzerFormat: AVAudioFormat,
    continuation: AsyncStream<AnalyzerInput>.Continuation
  ) {
    guard let converter = AVAudioConverter(from: inputFormat, to: analyzerFormat) else {
      return nil
    }
    self.converter = Mutex(converter)
    self.analyzerFormat = analyzerFormat
    ratio = analyzerFormat.sampleRate / max(inputFormat.sampleRate, 1)
    self.continuation = continuation
  }

  func receive(_ buffer: AVAudioPCMBuffer) {
    let capacity = AVAudioFrameCount(Double(buffer.frameLength) * ratio) + 64
    guard capacity > 0,
      let output = AVAudioPCMBuffer(pcmFormat: analyzerFormat, frameCapacity: capacity)
    else {
      return
    }

    var consumed = false
    var conversionError: NSError?
    let status = converter.withLock { converter in
      converter.convert(to: output, error: &conversionError) { _, inputStatus in
        if consumed {
          inputStatus.pointee = .noDataNow
          return nil
        }
        consumed = true
        inputStatus.pointee = .haveData
        return buffer
      }
    }

    guard conversionError == nil, status != .error, output.frameLength > 0 else {
      return
    }
    continuation.yield(AnalyzerInput(buffer: output))
  }

  func finish() {
    continuation.finish()
  }
}
