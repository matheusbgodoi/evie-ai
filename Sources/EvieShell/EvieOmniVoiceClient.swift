import AVFoundation
import Foundation

/// A cloned voice already stored by the OmniVoice backend.
struct EvieClonedVoice: Identifiable, Hashable, Sendable {
  var id: String
  var name: String
  var language: String
  /// A cloned voice whose reference recording has never been transcribed.
  ///
  /// Costs about eighteen seconds on every phrase until it is, so it is worth
  /// knowing about rather than living with.
  var needsReferenceText = false
}

/// Talks to the local OmniVoice backend.
///
/// The backend holds a 2.4 GB model and stays a separate process, for the same
/// reason the inference server does: a heavy resident worker is a resource
/// decision that belongs to the person whose machine it is.
///
/// It is started on demand by `EvieVoiceEngineLauncher`, and only when a trained
/// voice is actually asked to speak — never at login, never for a system voice.
/// `Scripts/evie-voice` manages the same process by hand and releases its memory.
struct EvieOmniVoiceClient: Sendable {
  /// Chosen by the backend's own default, not by Evie.
  static let defaultPort = 3900
  static let defaultEndpoint = URL(string: "http://127.0.0.1:\(defaultPort)")!

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
    case unreadableAudio
    case unexpectedResponse

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
      case .unreadableAudio:
        "Não consegui abrir esse arquivo de áudio."
      case .unexpectedResponse:
        "O motor de voz respondeu de um jeito que eu não reconheço."
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
      let referenceText = (object["ref_text"] as? String) ?? ""
      let isClone = (object["kind"] as? String) != "design"
      return EvieClonedVoice(
        id: id,
        name: object["name"] as? String ?? id,
        language: object["language"] as? String ?? "",
        needsReferenceText: isClone && referenceText.isEmpty
          && (object["ref_audio_path"] as? String)?.isEmpty == false
      )
    }
  }

  /// Fills in the reference transcript of any cloned voice that is missing one.
  ///
  /// This is the difference between a voice engine that is unusable and one that
  /// is faster than real time, and it was measured on this Mac rather than
  /// guessed. A cloned profile whose `ref_text` is empty makes the backend
  /// transcribe its reference recording with Whisper **on every phrase** — not
  /// once, every time:
  ///
  /// | profile                              | one short phrase |
  /// | ------------------------------------ | ---------------- |
  /// | designed voice, no reference audio   | 1.5 s            |
  /// | cloned voice, `ref_text` empty       | 19.1 s           |
  /// | the same cloned voice, `ref_text` set| 1.7 s            |
  ///
  /// Twelve seconds of speech went from 20.4 s to 3.4 s — from four times slower
  /// than real time to three times faster. A voice trained through Evie carries
  /// its transcript already; one made in the engine's own application, which is
  /// where this profile came from, does not. Repairing it costs one transcription
  /// of a ten-second clip, measured at 7 s, once ever.
  ///
  /// Returns the names of the voices it repaired, so the interface can say what
  /// happened instead of a voice silently becoming quick.
  func repairMissingReferenceText() async -> [String] {
    var repaired: [String] = []
    for profile in await voices() where profile.needsReferenceText {
      guard let audio = await referenceAudio(for: profile.id),
        let text = await transcribe(audio),
        !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
        await setReferenceText(text, name: profile.name, for: profile.id)
      else {
        continue
      }
      repaired.append(profile.name)
    }
    return repaired
  }

  private func referenceAudio(for profileID: String) async -> Data? {
    let url =
      endpoint
      .appendingPathComponent("profiles")
      .appendingPathComponent(profileID)
      .appendingPathComponent("audio")
    var request = URLRequest(url: url)
    request.timeoutInterval = 60
    guard let (data, response) = try? await URLSession.shared.data(for: request),
      (response as? HTTPURLResponse)?.statusCode == 200, !data.isEmpty
    else {
      return nil
    }
    return data
  }

  private func transcribe(_ audio: Data) async -> String? {
    var request = URLRequest(url: endpoint.appendingPathComponent("transcribe"))
    request.httpMethod = "POST"
    // Generous: this is a Whisper pass, and it happens once per voice ever.
    request.timeoutInterval = 300
    let boundary = "evie-\(UUID().uuidString)"
    request.setValue(
      "multipart/form-data; boundary=\(boundary)",
      forHTTPHeaderField: "Content-Type"
    )
    var body = Data()
    body.append(Data("--\(boundary)\r\n".utf8))
    body.append(
      Data(
        "Content-Disposition: form-data; name=\"audio\"; filename=\"reference.mp3\"\r\n".utf8
      )
    )
    body.append(Data("Content-Type: audio/mpeg\r\n\r\n".utf8))
    body.append(audio)
    body.append(Data("\r\n--\(boundary)--\r\n".utf8))
    request.httpBody = body

    guard let (data, response) = try? await URLSession.shared.data(for: request),
      (response as? HTTPURLResponse)?.statusCode == 200,
      let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
    else {
      return nil
    }
    return (object["text"] ?? object["transcript"]) as? String
  }

  private func setReferenceText(_ text: String, name: String, for profileID: String) async -> Bool {
    let url =
      endpoint.appendingPathComponent("profiles").appendingPathComponent(profileID)
    var request = URLRequest(url: url)
    request.httpMethod = "PUT"
    request.timeoutInterval = 30
    // JSON, not the multipart the other endpoints take. The backend rejects a
    // multipart body here with 422; measured rather than assumed from the shape
    // of its neighbours.
    request.setValue("application/json", forHTTPHeaderField: "Content-Type")
    request.httpBody = try? JSONSerialization.data(
      withJSONObject: ["name": name, "ref_text": text]
    )
    guard let (_, response) = try? await URLSession.shared.data(for: request) else {
      return false
    }
    return (response as? HTTPURLResponse)?.statusCode == 200
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
  /// Trains a new voice from a recording.
  ///
  /// `referenceText` is what the recording actually says. It is optional to the
  /// engine and worth insisting on: without it the first use of the voice pays a
  /// one-off transcription pass, measured on this Mac at 23 seconds, in the
  /// middle of whatever conversation happens to trigger it.
  func createProfile(
    name: String,
    audioURL: URL,
    referenceText: String,
    language: String = "Portuguese"
  ) async throws -> String {
    let audio: Data
    do {
      audio = try Data(contentsOf: audioURL)
    } catch {
      throw ClientError.unreadableAudio
    }

    var request = URLRequest(url: endpoint.appendingPathComponent("profiles"))
    request.httpMethod = "POST"
    request.timeoutInterval = timeout

    let boundary = "evie-\(UUID().uuidString)"
    request.setValue(
      "multipart/form-data; boundary=\(boundary)",
      forHTTPHeaderField: "Content-Type"
    )
    var fields = ["name": name, "language": language]
    if !referenceText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
      fields["ref_text"] = referenceText
    }
    request.httpBody = Self.multipartBody(
      boundary: boundary,
      fields: fields,
      file: (name: "ref_audio", filename: audioURL.lastPathComponent, data: audio)
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
    guard (200...299).contains(status) else {
      throw ClientError.rejected(status)
    }
    guard
      let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
      let identifier = (object["id"] ?? object["profile_id"]) as? String
    else {
      throw ClientError.unexpectedResponse
    }
    return identifier
  }

  /// Removes a voice from the engine for good.
  func deleteProfile(id: String) async throws {
    var request = URLRequest(
      url: endpoint.appendingPathComponent("profiles").appendingPathComponent(id)
    )
    request.httpMethod = "DELETE"
    request.timeoutInterval = 15

    let response: URLResponse
    do {
      (_, response) = try await URLSession.shared.data(for: request)
    } catch {
      throw ClientError.unavailable
    }
    guard let status = (response as? HTTPURLResponse)?.statusCode else {
      throw ClientError.unavailable
    }
    // A voice that is already gone is the outcome that was asked for.
    guard (200...299).contains(status) || status == 404 else {
      throw ClientError.rejected(status)
    }
  }
}

extension EvieOmniVoiceClient {
  fileprivate static func multipartBody(
    boundary: String,
    fields: [String: String],
    file: (name: String, filename: String, data: Data)
  ) -> Data {
    var body = multipartBody(boundary: boundary, fields: fields, closing: false)
    body.append(Data("--\(boundary)\r\n".utf8))
    body.append(
      Data(
        "Content-Disposition: form-data; name=\"\(file.name)\"; filename=\"\(file.filename)\"\r\n"
          .utf8
      )
    )
    body.append(Data("Content-Type: application/octet-stream\r\n\r\n".utf8))
    body.append(file.data)
    body.append(Data("\r\n--\(boundary)--\r\n".utf8))
    return body
  }

  fileprivate static func multipartBody(
    boundary: String,
    fields: [String: String],
    closing: Bool = true
  ) -> Data {
    var body = Data()
    for (name, value) in fields {
      body.append(Data("--\(boundary)\r\n".utf8))
      body.append(
        Data("Content-Disposition: form-data; name=\"\(name)\"\r\n\r\n".utf8)
      )
      body.append(Data("\(value)\r\n".utf8))
    }
    if closing {
      body.append(Data("--\(boundary)--\r\n".utf8))
    }
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
