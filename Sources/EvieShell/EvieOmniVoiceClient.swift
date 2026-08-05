import AVFoundation
import Foundation

/// A cloned voice already stored by the OmniVoice backend.
struct EvieClonedVoice: Identifiable, Hashable, Sendable {
  var id: String
  var name: String
  var language: String
}

/// Talks to the local OmniVoice backend.
///
/// The backend holds a 2.4 GB model and is deliberately not started by Evie. It
/// is a separate, explicitly controlled process — `Scripts/evie-voice` — for the
/// same reason the inference server is: a heavy resident worker that starts
/// itself is a resource decision taken away from the user.
struct EvieOmniVoiceClient: Sendable {
  /// Chosen by the backend's own default, not by Evie.
  static let defaultEndpoint = URL(string: "http://127.0.0.1:3900")!

  /// Diffusion steps. Measured on this Mac with a warm model: eight steps
  /// produced 2.12 s of audio in 2.99 s, sixteen took 4.03 s for the same words.
  /// Eight is the setting that keeps a conversation moving.
  static let defaultSteps = 8

  var endpoint: URL
  var steps: Int
  var timeout: TimeInterval

  init(
    endpoint: URL = EvieOmniVoiceClient.defaultEndpoint,
    steps: Int = EvieOmniVoiceClient.defaultSteps,
    timeout: TimeInterval = 180
  ) {
    self.endpoint = endpoint
    self.steps = steps
    self.timeout = timeout
  }

  enum ClientError: LocalizedError, Equatable {
    case unavailable
    case rejected(Int)
    case emptyAudio
    case undecodableAudio

    var errorDescription: String? {
      switch self {
      case .unavailable:
        "O motor de voz clonada não está no ar. Rode Scripts/evie-voice start."
      case .rejected(let status):
        "O motor de voz recusou o pedido (HTTP \(status))."
      case .emptyAudio:
        "O motor de voz respondeu sem áudio."
      case .undecodableAudio:
        "Não consegui ler o áudio que o motor de voz devolveu."
      }
    }
  }

  /// True when the backend answers and has its model loaded.
  func isHealthy() async -> Bool {
    var request = URLRequest(url: endpoint.appendingPathComponent("health"))
    request.timeoutInterval = 3
    guard
      let (data, response) = try? await URLSession.shared.data(for: request),
      (response as? HTTPURLResponse)?.statusCode == 200,
      let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
    else {
      return false
    }
    return object["status"] as? String == "ok"
  }

  func voices() async -> [EvieClonedVoice] {
    var request = URLRequest(url: endpoint.appendingPathComponent("profiles"))
    request.timeoutInterval = 5
    guard
      let (data, response) = try? await URLSession.shared.data(for: request),
      (response as? HTTPURLResponse)?.statusCode == 200
    else {
      return []
    }

    // The backend has returned both a bare array and an envelope across
    // versions, so both shapes are accepted rather than assumed.
    let objects: [[String: Any]]
    if let array = try? JSONSerialization.jsonObject(with: data) as? [[String: Any]] {
      objects = array
    } else if let envelope = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
      let array = envelope["profiles"] as? [[String: Any]]
    {
      objects = array
    } else {
      return []
    }

    return objects.compactMap { object in
      guard let id = object["id"] as? String else {
        return nil
      }
      return EvieClonedVoice(
        id: id,
        name: object["name"] as? String ?? id,
        language: object["language"] as? String ?? ""
      )
    }
  }

  /// Synthesises one block of text and returns it ready to play.
  func synthesise(
    _ text: String,
    profileID: String,
    language: String = "Portuguese"
  ) async throws -> AVAudioPCMBuffer {
    var request = URLRequest(url: endpoint.appendingPathComponent("generate"))
    request.httpMethod = "POST"
    request.timeoutInterval = timeout

    let boundary = "evie-\(UUID().uuidString)"
    request.setValue(
      "multipart/form-data; boundary=\(boundary)",
      forHTTPHeaderField: "Content-Type"
    )
    request.httpBody = Self.multipartBody(
      boundary: boundary,
      fields: [
        "text": text,
        "profile_id": profileID,
        "language": language,
        "num_step": String(steps),
      ]
    )

    let data: Data
    let response: URLResponse
    do {
      (data, response) = try await URLSession.shared.data(for: request)
    } catch {
      throw ClientError.unavailable
    }
    guard let status = (response as? HTTPURLResponse)?.statusCode else {
      throw ClientError.unavailable
    }
    guard status == 200 else {
      throw ClientError.rejected(status)
    }

    guard let wav = Self.extractWave(from: data) else {
      throw ClientError.emptyAudio
    }
    guard let buffer = Self.decode(wav) else {
      throw ClientError.undecodableAudio
    }
    return buffer
  }
}

extension EvieOmniVoiceClient {
  fileprivate static func multipartBody(
    boundary: String,
    fields: [String: String]
  ) -> Data {
    var body = Data()
    for (name, value) in fields {
      body.append(Data("--\(boundary)\r\n".utf8))
      body.append(
        Data("Content-Disposition: form-data; name=\"\(name)\"\r\n\r\n".utf8)
      )
      body.append(Data("\(value)\r\n".utf8))
    }
    body.append(Data("--\(boundary)--\r\n".utf8))
    return body
  }

  /// The backend answers either with the WAV itself or with JSON carrying it in
  /// base64, depending on the route and version.
  fileprivate static func extractWave(from data: Data) -> Data? {
    if data.count > 4, data.prefix(4) == Data("RIFF".utf8) {
      return data
    }
    guard
      let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
    else {
      return nil
    }
    for key in ["wav_base64", "audio_base64", "audio"] {
      if let encoded = object[key] as? String,
        let decoded = Data(base64Encoded: encoded),
        decoded.count > 4
      {
        return decoded
      }
    }
    return nil
  }

  /// Decodes through `AVAudioFile` rather than parsing the header by hand: it
  /// handles whatever bit depth and rate the backend chose, and returns the
  /// buffer in the float format the playback engine wants.
  fileprivate static func decode(_ wav: Data) -> AVAudioPCMBuffer? {
    let url = FileManager.default.temporaryDirectory
      .appendingPathComponent("evie-tts-\(UUID().uuidString).wav")
    defer { try? FileManager.default.removeItem(at: url) }

    guard (try? wav.write(to: url, options: .atomic)) != nil,
      let file = try? AVAudioFile(forReading: url)
    else {
      return nil
    }
    let frames = AVAudioFrameCount(file.length)
    guard frames > 0,
      let buffer = AVAudioPCMBuffer(pcmFormat: file.processingFormat, frameCapacity: frames),
      (try? file.read(into: buffer)) != nil
    else {
      return nil
    }
    return buffer
  }
}
