import Foundation

/// A backend-neutral, local voice-cloning reference.
///
/// The transcript is intentionally kept in memory. Providers must not place it
/// in command-line arguments, environment variables, diagnostics, or durable
/// request files.
public struct EvieTTSVoiceReference: Hashable, Sendable {
  public var audioFileURL: URL
  public var transcript: String

  public init(audioFileURL: URL, transcript: String) {
    self.audioFileURL = audioFileURL
    self.transcript = transcript
  }
}

/// Bounded generation controls shared by replaceable TTS providers.
public struct EvieTTSGenerationOptions: Hashable, Sendable {
  public var language: String?
  public var styleInstruction: String?
  public var speed: Double
  public var steps: Int

  public init(
    language: String? = "pt",
    styleInstruction: String? = nil,
    speed: Double = 1,
    steps: Int = 16
  ) {
    self.language = language
    self.styleInstruction = styleInstruction
    self.speed = speed
    self.steps = steps
  }
}

/// One text-to-speech request. Text and reference content are private payloads.
public struct EvieTTSRequest: Hashable, Sendable {
  public var text: String
  public var voiceReference: EvieTTSVoiceReference
  public var options: EvieTTSGenerationOptions

  public init(
    text: String,
    voiceReference: EvieTTSVoiceReference,
    options: EvieTTSGenerationOptions = EvieTTSGenerationOptions()
  ) {
    self.text = text
    self.voiceReference = voiceReference
    self.options = options
  }
}

/// A locally generated audio file. `discard()` and deinitialization attempt
/// best-effort removal of its private temporary directory; callers must not treat
/// that attempt as durable deletion in the face of filesystem errors or crashes.
public final class EvieTTSAudio: @unchecked Sendable {
  public let fileURL: URL

  private let directoryURL: URL
  private let lock = NSLock()
  private var wasDiscarded = false

  init(fileURL: URL, directoryURL: URL) {
    self.fileURL = fileURL
    self.directoryURL = directoryURL
  }

  deinit {
    discard()
  }

  /// Best-effort removal of the generated audio and its request-scoped temporary
  /// directory. Cleanup is idempotent and deliberately does not expose errors.
  public func discard() {
    lock.lock()
    guard !wasDiscarded else {
      lock.unlock()
      return
    }
    wasDiscarded = true
    lock.unlock()

    try? FileManager.default.removeItem(at: directoryURL)
  }
}

/// A replaceable local text-to-speech provider.
public protocol EvieTTSProvider: Sendable {
  func synthesize(_ request: EvieTTSRequest) async throws -> EvieTTSAudio
}

/// Stable, redacted TTS failures. No case carries request text, transcripts, or
/// private paths.
public enum EvieTTSError: Error, Equatable, LocalizedError, Sendable {
  case busy
  case invalidConfiguration
  case invalidRequest
  case temporaryStorageUnavailable
  case processLaunchFailed(code: Int32)
  case processFailed(exitCode: Int32)
  case processTerminated(signal: Int32)
  case timedOut
  case outputMissing

  public var errorDescription: String? {
    switch self {
    case .busy:
      "The local speech worker is already handling another request."
    case .invalidConfiguration:
      "The local speech worker configuration is invalid."
    case .invalidRequest:
      "The speech request is invalid or exceeds its local safety limits."
    case .temporaryStorageUnavailable:
      "Evie could not prepare private temporary storage for speech output."
    case .processLaunchFailed:
      "The local speech worker could not be launched."
    case .processFailed:
      "The local speech worker failed without producing audio."
    case .processTerminated:
      "The local speech worker terminated unexpectedly."
    case .timedOut:
      "The local speech worker exceeded its time limit."
    case .outputMissing:
      "The local speech worker did not produce a valid audio file."
    }
  }
}
