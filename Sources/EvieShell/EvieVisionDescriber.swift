import CoreGraphics
import Foundation
import ImageIO

#if canImport(FoundationModels)
  import FoundationModels
#endif

/// Describes what is in a picture.
///
/// The obvious way to give Evie sight is to load a vision-language model beside
/// the one already resident: two to four gigabytes, a download, a second server
/// to start and stop, and a machine with less room for everything else. That was
/// the plan until this Mac was actually asked what it already had.
///
/// macOS 26 ships an on-device language model that accepts images. Measured here:
/// it described a blue circle on a yellow field correctly in 1.52 seconds, with
/// no download, no extra process, and no memory that was not already spent —
/// the model belongs to the system and is shared with everything else using it.
/// Against loading a second model that is strictly worse on every axis, this is
/// not a close call.
///
/// It is deliberately *not* used for anything but describing images. The text
/// model Evie answers with is far larger and far better at Portuguese; this one
/// is here because it can see.
struct EvieVisionDescriber: Sendable {
  /// Whether this Mac can describe an image at all.
  ///
  /// Reported honestly rather than assumed, because the system model can be
  /// unavailable — an unsupported device, Apple Intelligence switched off, or the
  /// model still downloading — and Evie must not claim to see when she cannot.
  static var isAvailable: Bool {
    #if canImport(FoundationModels)
      if #available(macOS 27, *) {
        if case .available = SystemLanguageModel.default.availability {
          return true
        }
      }
    #endif
    return false
  }

  /// Why it is unavailable, in words worth showing someone.
  static var unavailableReason: String? {
    #if canImport(FoundationModels)
      if #available(macOS 27, *) {
        switch SystemLanguageModel.default.availability {
        case .available:
          return nil
        case .unavailable(let reason):
          switch reason {
          case .deviceNotEligible:
            return "Este Mac não tem o modelo de visão do sistema."
          case .appleIntelligenceNotEnabled:
            return "Ligue a Apple Intelligence em Ajustes do Sistema para ela enxergar."
          case .modelNotReady:
            return "O modelo de visão do sistema ainda está baixando."
          @unknown default:
            return "O modelo de visão do sistema não está disponível agora."
          }
        @unknown default:
          return "O modelo de visão do sistema não está disponível agora."
        }
      }
    #endif
    return "Este macOS é anterior ao que trouxe a visão no modelo do sistema."
  }

  enum VisionError: LocalizedError {
    case unavailable(String)
    case unreadableImage
    case refused(String)

    var errorDescription: String? {
      switch self {
      case .unavailable(let reason):
        reason
      case .unreadableImage:
        "Não consegui abrir essa imagem."
      case .refused(let reason):
        "Não consegui descrever essa imagem: \(reason)"
      }
    }
  }

  /// One paragraph about what the picture shows.
  ///
  /// Asked for in English because the system model answers English prompts more
  /// reliably; the description is translated by the model that writes the actual
  /// answer, which is better at Portuguese than this one is.
  func describe(imageAt url: URL) async throws -> String {
    guard Self.isAvailable else {
      throw VisionError.unavailable(Self.unavailableReason ?? "indisponível")
    }
    guard let image = Self.loadImage(at: url) else {
      throw VisionError.unreadableImage
    }
    return try await describe(image)
  }

  func describe(_ image: CGImage) async throws -> String {
    #if canImport(FoundationModels)
      if #available(macOS 27, *) {
        do {
          let session = LanguageModelSession()
          let response = try await session.respond {
            """
            Describe this image factually and specifically, in at most four \
            sentences of plain prose. Say what kind of image it is, what it \
            shows, and any numbers, labels or structure visible. Do not \
            speculate about intent. Reply with the description only: no JSON, \
            no code fence, no list, no preamble.
            """
            Attachment(image)
          }
          return Self.tidy(response.content)
        } catch {
          throw VisionError.refused(error.localizedDescription)
        }
      }
    #endif
    throw VisionError.unavailable(Self.unavailableReason ?? "indisponível")
  }

  /// Gets the description out of whatever the model wrapped it in.
  ///
  /// Two things observed rather than anticipated. It sometimes opens by
  /// introducing itself, which is not a description and would arrive in Evie's
  /// context as though it were. And asked for four sentences about an icon it
  /// returned a fenced JSON object with a `description` field beside an invented
  /// `tool_calls` array — so the prompt now forbids that, and this unwraps it
  /// anyway, because a prompt is a request and this is a guarantee.
  static func tidy(_ description: String) -> String {
    var text = description.trimmingCharacters(in: .whitespacesAndNewlines)

    if let fenced = fencedBody(of: text) {
      text = fenced
    }
    if let field = jsonDescription(in: text) {
      text = field
    }

    let preambles = [
      "I am a foundation model developed by Apple.",
      "I'm a foundation model developed by Apple.",
      "As a foundation model developed by Apple,",
    ]
    for preamble in preambles where text.hasPrefix(preamble) {
      text = String(text.dropFirst(preamble.count)).trimmingCharacters(
        in: .whitespacesAndNewlines
      )
    }
    return text.trimmingCharacters(in: .whitespacesAndNewlines)
  }

  /// The inside of a ```fence```, if the whole answer is one.
  static func fencedBody(of text: String) -> String? {
    guard text.hasPrefix("```") else {
      return nil
    }
    guard let firstBreak = text.firstIndex(of: "\n") else {
      return nil
    }
    let body = text[text.index(after: firstBreak)...]
    guard let close = body.range(of: "```", options: .backwards) else {
      return String(body)
    }
    return String(body[..<close.lowerBound])
  }

  /// The `description` field, when the answer turned out to be an object.
  static func jsonDescription(in text: String) -> String? {
    guard text.hasPrefix("{"),
      let data = text.data(using: .utf8),
      let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
    else {
      return nil
    }
    for key in ["description", "Description", "text", "caption"] {
      if let value = object[key] as? String, !value.isEmpty {
        return value
      }
    }
    return nil
  }

  static func loadImage(at url: URL) -> CGImage? {
    guard let source = CGImageSourceCreateWithURL(url as CFURL, nil) else {
      return nil
    }
    return CGImageSourceCreateImageAtIndex(source, 0, nil)
  }
}
