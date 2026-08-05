import Darwin
import Foundation

public struct OmniVoiceBatchTTSConfiguration: Hashable, Sendable {
  public var executableURL: URL
  public var modelDirectoryURL: URL
  public var huggingFaceCacheURL: URL
  public var temporaryRootURL: URL
  public var timeout: TimeInterval
  public var terminationGracePeriod: TimeInterval

  public init(
    executableURL: URL,
    modelDirectoryURL: URL,
    huggingFaceCacheURL: URL,
    temporaryRootURL: URL = Self.defaultTemporaryRootURL,
    timeout: TimeInterval = 180,
    terminationGracePeriod: TimeInterval = 1
  ) {
    self.executableURL = executableURL
    self.modelDirectoryURL = modelDirectoryURL
    self.huggingFaceCacheURL = huggingFaceCacheURL
    self.temporaryRootURL = temporaryRootURL
    self.timeout = timeout
    self.terminationGracePeriod = terminationGracePeriod
  }

  public static var defaultTemporaryRootURL: URL {
    FileManager.default.temporaryDirectory
      .appendingPathComponent("Evie", isDirectory: true)
      .appendingPathComponent("TTS", isDirectory: true)
  }
}

/// One-shot adapter for OmniVoice's installed `omnivoice-infer-batch` CLI.
///
/// The official batch entry point reads JSONL from `--test_list`. Evie supplies
/// `/dev/stdin`, so synthesis text and the reference transcript never appear in
/// argv, the environment, or a request file. Every invocation starts in a fresh
/// process group and exits after producing one file; this adapter owns no daemon.
public actor OmniVoiceBatchTTSAdapter: EvieTTSProvider {
  private static let cachedTokenizerSnapshotsPath =
    "hub/models--eustlb--higgs-audio-v2-tokenizer/snapshots"
  private static let maximumTextBytes = 64 * 1_024
  private static let maximumTranscriptBytes = 128 * 1_024
  private static let maximumInstructionBytes = 4 * 1_024
  private static let maximumOutputBytes = 64 * 1_024 * 1_024

  private let configuration: OmniVoiceBatchTTSConfiguration
  private let runner: SecureProcessRunner
  private var isSynthesizing = false

  public init(configuration: OmniVoiceBatchTTSConfiguration) throws {
    try Self.validateConfiguration(configuration)
    self.configuration = configuration
    runner = SecureProcessRunner()
  }

  public func synthesize(_ request: EvieTTSRequest) async throws -> EvieTTSAudio {
    guard !isSynthesizing else { throw EvieTTSError.busy }
    isSynthesizing = true
    defer { isSynthesizing = false }

    try Task.checkCancellation()
    try Self.validateRequest(request)
    let referenceURL = try Self.validatedReferenceURL(request.voiceReference.audioFileURL)
    let requestDirectory = try prepareRequestDirectory()
    var shouldRemoveRequestDirectory = true
    defer {
      if shouldRemoveRequestDirectory {
        try? FileManager.default.removeItem(at: requestDirectory)
      }
    }

    let outputURL = requestDirectory.appendingPathComponent("speech.wav", isDirectory: false)
    guard
      FileManager.default.createFile(
        atPath: outputURL.path,
        contents: Data(),
        attributes: [.posixPermissions: NSNumber(value: 0o600)]
      )
    else {
      throw EvieTTSError.temporaryStorageUnavailable
    }
    guard chmod(outputURL.path, 0o600) == 0 else {
      throw EvieTTSError.temporaryStorageUnavailable
    }

    let payload = try makeStandardInput(request: request, referenceURL: referenceURL)
    let command = SecureProcessCommand(
      executableURL: configuration.executableURL,
      arguments: commandArguments(request: request, requestDirectory: requestDirectory),
      environment: try offlineEnvironment(requestDirectory: requestDirectory),
      workingDirectoryURL: requestDirectory,
      standardInput: payload,
      timeout: configuration.timeout,
      terminationGracePeriod: configuration.terminationGracePeriod
    )

    do {
      let exit = try await runner.run(command)
      guard exit.exitCode == 0 else {
        throw EvieTTSError.processFailed(exitCode: exit.exitCode)
      }
    } catch is CancellationError {
      throw CancellationError()
    } catch SecureProcessRunnerError.timedOut {
      throw EvieTTSError.timedOut
    } catch SecureProcessRunnerError.launchFailed(let code) {
      throw EvieTTSError.processLaunchFailed(code: code)
    } catch SecureProcessRunnerError.terminated(let signal) {
      throw EvieTTSError.processTerminated(signal: signal)
    } catch let error as EvieTTSError {
      throw error
    } catch {
      throw EvieTTSError.processFailed(exitCode: -1)
    }

    let outputValues = try? outputURL.resourceValues(forKeys: [
      .fileSizeKey, .isRegularFileKey, .isSymbolicLinkKey,
    ])
    guard
      outputValues?.isRegularFile == true,
      outputValues?.isSymbolicLink != true,
      let fileSize = outputValues?.fileSize,
      fileSize > 0,
      fileSize <= Self.maximumOutputBytes,
      Self.isConsistentWaveFile(at: outputURL, fileSize: fileSize),
      chmod(outputURL.path, 0o600) == 0
    else {
      throw EvieTTSError.outputMissing
    }

    shouldRemoveRequestDirectory = false
    return EvieTTSAudio(fileURL: outputURL, directoryURL: requestDirectory)
  }
}

extension OmniVoiceBatchTTSAdapter {
  private static func validateConfiguration(
    _ configuration: OmniVoiceBatchTTSConfiguration
  ) throws {
    guard
      isAbsoluteFileURL(configuration.executableURL),
      isAbsoluteFileURL(configuration.modelDirectoryURL),
      isAbsoluteFileURL(configuration.huggingFaceCacheURL),
      isAbsoluteFileURL(configuration.temporaryRootURL),
      configuration.temporaryRootURL.lastPathComponent == "TTS",
      configuration.temporaryRootURL.deletingLastPathComponent().lastPathComponent == "Evie",
      configuration.timeout > 0,
      configuration.timeout <= 1_800,
      configuration.timeout.isFinite,
      configuration.terminationGracePeriod >= 0,
      configuration.terminationGracePeriod <= 10,
      configuration.terminationGracePeriod.isFinite,
      FileManager.default.isExecutableFile(atPath: configuration.executableURL.path)
    else {
      throw EvieTTSError.invalidConfiguration
    }

    let executableValues = try? configuration.executableURL.resourceValues(forKeys: [
      .isRegularFileKey, .isSymbolicLinkKey,
    ])
    let modelValues = try? configuration.modelDirectoryURL.resourceValues(forKeys: [
      .isDirectoryKey, .isSymbolicLinkKey,
    ])
    let cacheValues = try? configuration.huggingFaceCacheURL.resourceValues(forKeys: [
      .isDirectoryKey, .isSymbolicLinkKey,
    ])
    let tokenizerSnapshotsURL = configuration.huggingFaceCacheURL.appendingPathComponent(
      cachedTokenizerSnapshotsPath,
      isDirectory: true
    )
    let tokenizerSnapshots = try? FileManager.default.contentsOfDirectory(
      at: tokenizerSnapshotsURL,
      includingPropertiesForKeys: [.isDirectoryKey, .isSymbolicLinkKey],
      options: [.skipsHiddenFiles]
    )
    let hasCachedTokenizerSnapshot = tokenizerSnapshots?.contains { snapshotURL in
      let values = try? snapshotURL.resourceValues(forKeys: [
        .isDirectoryKey, .isSymbolicLinkKey,
      ])
      return values?.isDirectory == true && values?.isSymbolicLink != true
    }
    guard
      executableValues?.isRegularFile == true,
      executableValues?.isSymbolicLink != true,
      modelValues?.isDirectory == true,
      modelValues?.isSymbolicLink != true,
      cacheValues?.isDirectory == true,
      cacheValues?.isSymbolicLink != true,
      hasCachedTokenizerSnapshot == true
    else {
      throw EvieTTSError.invalidConfiguration
    }
  }

  private static func validateRequest(_ request: EvieTTSRequest) throws {
    let text = request.text.trimmingCharacters(in: .whitespacesAndNewlines)
    let transcript = request.voiceReference.transcript
      .trimmingCharacters(in: .whitespacesAndNewlines)
    let language = request.options.language?.trimmingCharacters(in: .whitespacesAndNewlines)
    let instruction = request.options.styleInstruction?
      .trimmingCharacters(in: .whitespacesAndNewlines)

    guard
      !text.isEmpty,
      !transcript.isEmpty,
      request.text.lengthOfBytes(using: .utf8) <= maximumTextBytes,
      request.voiceReference.transcript.lengthOfBytes(using: .utf8) <= maximumTranscriptBytes,
      instruction?.lengthOfBytes(using: .utf8) ?? 0 <= maximumInstructionBytes,
      language?.lengthOfBytes(using: .utf8) ?? 0 <= 64,
      !containsControlCharacters(request.text),
      !containsControlCharacters(request.voiceReference.transcript),
      instruction.map({ !containsControlCharacters($0) }) ?? true,
      language.map({ !$0.isEmpty && !containsControlCharacters($0) }) ?? true,
      request.options.speed.isFinite,
      (0.5...2).contains(request.options.speed),
      (8...64).contains(request.options.steps)
    else {
      throw EvieTTSError.invalidRequest
    }
  }

  private static func validatedReferenceURL(_ url: URL) throws -> URL {
    guard isAbsoluteFileURL(url) else { throw EvieTTSError.invalidRequest }
    let values = try? url.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey])
    guard values?.isRegularFile == true, values?.isSymbolicLink != true else {
      throw EvieTTSError.invalidRequest
    }
    return url.standardizedFileURL
  }

  private static func isAbsoluteFileURL(_ url: URL) -> Bool {
    url.isFileURL && url.path.hasPrefix("/") && !url.path.contains("\0")
  }

  private static func containsControlCharacters(_ value: String) -> Bool {
    value.unicodeScalars.contains { scalar in
      CharacterSet.controlCharacters.contains(scalar) && scalar != "\n" && scalar != "\t"
    }
  }

  private static func isConsistentWaveFile(at url: URL, fileSize: Int) -> Bool {
    guard fileSize >= 44, let file = try? FileHandle(forReadingFrom: url) else {
      return false
    }
    defer { try? file.close() }

    guard
      let header = try? file.read(upToCount: 12),
      header.count == 12,
      hasASCII("RIFF", in: header, at: 0),
      hasASCII("WAVE", in: header, at: 8),
      let riffSize = littleEndianUInt32(in: header, at: 4),
      UInt64(riffSize) + 8 == UInt64(fileSize)
    else {
      return false
    }

    var offset = 12
    var foundFormat = false
    var foundAudioData = false

    while offset + 8 <= fileSize {
      do {
        try file.seek(toOffset: UInt64(offset))
        guard
          let chunkHeader = try file.read(upToCount: 8),
          chunkHeader.count == 8,
          let chunkSize = littleEndianUInt32(in: chunkHeader, at: 4)
        else {
          return false
        }

        let dataOffset = UInt64(offset + 8)
        let dataEnd = dataOffset + UInt64(chunkSize)
        guard dataEnd <= UInt64(fileSize) else { return false }

        if hasASCII("fmt ", in: chunkHeader, at: 0) {
          guard chunkSize >= 16, !foundFormat else { return false }
          guard
            let format = try file.read(upToCount: 16),
            format.count == 16,
            let audioFormat = littleEndianUInt16(in: format, at: 0),
            let channels = littleEndianUInt16(in: format, at: 2),
            let sampleRate = littleEndianUInt32(in: format, at: 4),
            let byteRate = littleEndianUInt32(in: format, at: 8),
            let blockAlignment = littleEndianUInt16(in: format, at: 12),
            let bitsPerSample = littleEndianUInt16(in: format, at: 14),
            audioFormat != 0,
            channels > 0,
            sampleRate > 0,
            byteRate > 0,
            blockAlignment > 0,
            bitsPerSample > 0
          else {
            return false
          }
          foundFormat = true
        } else if hasASCII("data", in: chunkHeader, at: 0) {
          guard chunkSize > 0, !foundAudioData else { return false }
          foundAudioData = true
        }

        let padding = UInt64(chunkSize % 2)
        let nextOffset = dataEnd + padding
        guard nextOffset <= UInt64(fileSize), nextOffset <= UInt64(Int.max) else {
          return false
        }
        offset = Int(nextOffset)
      } catch {
        return false
      }
    }

    return offset == fileSize && foundFormat && foundAudioData
  }

  private static func hasASCII(_ expected: String, in data: Data, at offset: Int) -> Bool {
    let expectedBytes = Array(expected.utf8)
    guard offset >= 0, offset + expectedBytes.count <= data.count else { return false }
    return data[offset..<(offset + expectedBytes.count)].elementsEqual(expectedBytes)
  }

  private static func littleEndianUInt16(in data: Data, at offset: Int) -> UInt16? {
    guard offset >= 0, offset + 2 <= data.count else { return nil }
    return UInt16(data[offset]) | (UInt16(data[offset + 1]) << 8)
  }

  private static func littleEndianUInt32(in data: Data, at offset: Int) -> UInt32? {
    guard offset >= 0, offset + 4 <= data.count else { return nil }
    return UInt32(data[offset])
      | (UInt32(data[offset + 1]) << 8)
      | (UInt32(data[offset + 2]) << 16)
      | (UInt32(data[offset + 3]) << 24)
  }

  private func prepareRequestDirectory() throws -> URL {
    let fileManager = FileManager.default
    let evieDirectory = configuration.temporaryRootURL.deletingLastPathComponent()
    do {
      try createPrivateDirectory(evieDirectory, fileManager: fileManager)
      try createPrivateDirectory(configuration.temporaryRootURL, fileManager: fileManager)
      let directory = configuration.temporaryRootURL.appendingPathComponent(
        UUID().uuidString,
        isDirectory: true
      )
      try createPrivateDirectory(directory, fileManager: fileManager)
      return directory
    } catch {
      throw EvieTTSError.temporaryStorageUnavailable
    }
  }

  private func createPrivateDirectory(_ url: URL, fileManager: FileManager) throws {
    if fileManager.fileExists(atPath: url.path) {
      let values = try url.resourceValues(forKeys: [.isDirectoryKey, .isSymbolicLinkKey])
      guard values.isDirectory == true, values.isSymbolicLink != true else {
        throw EvieTTSError.temporaryStorageUnavailable
      }
    } else {
      try fileManager.createDirectory(
        at: url,
        withIntermediateDirectories: false,
        attributes: [.posixPermissions: NSNumber(value: 0o700)]
      )
    }
    guard chmod(url.path, 0o700) == 0 else {
      throw EvieTTSError.temporaryStorageUnavailable
    }
  }

  private func makeStandardInput(
    request: EvieTTSRequest,
    referenceURL: URL
  ) throws -> Data {
    let record = OmniVoiceBatchRecord(
      id: "speech",
      text: request.text,
      referenceAudio: referenceURL.path,
      referenceText: request.voiceReference.transcript,
      languageID: request.options.language,
      languageName: request.options.language,
      speed: request.options.speed,
      instruction: request.options.styleInstruction
    )
    var data = try JSONEncoder().encode(record)
    data.append(0x0A)
    return data
  }

  private func commandArguments(
    request: EvieTTSRequest,
    requestDirectory: URL
  ) -> [String] {
    [
      "--model", configuration.modelDirectoryURL.path,
      "--test_list", "/dev/stdin",
      "--res_dir", requestDirectory.path,
      "--nj_per_gpu", "1",
      "--batch_size", "1",
      "--warmup", "0",
      "--num_step", String(request.options.steps),
    ]
  }

  private func offlineEnvironment(requestDirectory: URL) throws -> [String: String] {
    let cacheURL = requestDirectory.appendingPathComponent("cache", isDirectory: true)
    do {
      try createPrivateDirectory(cacheURL, fileManager: .default)
    } catch {
      throw EvieTTSError.temporaryStorageUnavailable
    }

    return [
      "DO_NOT_TRACK": "1",
      "HF_DATASETS_OFFLINE": "1",
      "HF_HOME": configuration.huggingFaceCacheURL.path,
      "HF_HUB_DISABLE_TELEMETRY": "1",
      "HF_HUB_DISABLE_IMPLICIT_TOKEN": "1",
      "HF_HUB_OFFLINE": "1",
      "LC_CTYPE": "UTF-8",
      "PATH": "/usr/bin:/bin",
      "PYTHONNOUSERSITE": "1",
      "PYTHONPYCACHEPREFIX": cacheURL.appendingPathComponent("python", isDirectory: true).path,
      "PYTHONUNBUFFERED": "1",
      "TMPDIR": requestDirectory.path + "/",
      "TOKENIZERS_PARALLELISM": "false",
      "TORCH_HOME": cacheURL.appendingPathComponent("torch", isDirectory: true).path,
      "TRANSFORMERS_OFFLINE": "1",
      "XDG_CACHE_HOME": cacheURL.path,
    ]
  }
}

private struct OmniVoiceBatchRecord: Encodable {
  let id: String
  let text: String
  let referenceAudio: String
  let referenceText: String
  let languageID: String?
  let languageName: String?
  let speed: Double
  let instruction: String?

  enum CodingKeys: String, CodingKey {
    case id
    case text
    case referenceAudio = "ref_audio"
    case referenceText = "ref_text"
    case languageID = "language_id"
    case languageName = "language_name"
    case speed
    case instruction = "instruct"
  }
}
