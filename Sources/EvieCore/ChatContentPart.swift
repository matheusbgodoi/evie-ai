import Foundation

/// An image carried by a message for this request only.
///
/// It lives on `ChatMessage.images`, which is left out of the message's coding
/// keys: a screenshot is sent to the model and then forgotten, never written to
/// a conversation file, an export or a log. Equality and hashing look at the
/// identifier alone, because SwiftUI and the conversation diff compare messages
/// often and comparing megabytes of JPEG each time would cost more than the
/// comparison is worth.
public struct EvieImagePart: Sendable, Hashable {
  public enum Origin: String, Sendable {
    /// Evie captured the screen because the user asked her to look.
    case screenshot
    /// The user pasted or attached the picture.
    case attachment
  }

  public let id: UUID
  public let mimeType: String
  public let data: Data
  public let pixelSize: CGSize
  public let origin: Origin

  public init(
    id: UUID = UUID(),
    mimeType: String,
    data: Data,
    pixelSize: CGSize,
    origin: Origin
  ) {
    self.id = id
    self.mimeType = mimeType
    self.data = data
    self.pixelSize = pixelSize
    self.origin = origin
  }

  public static func == (lhs: EvieImagePart, rhs: EvieImagePart) -> Bool {
    lhs.id == rhs.id
  }

  public func hash(into hasher: inout Hasher) {
    hasher.combine(id)
  }

  /// The inline form every OpenAI-compatible server here accepts. The gateway
  /// rejects remote image URLs, and an inline image never leaves the request.
  var dataURL: String {
    "data:\(mimeType);base64,\(data.base64EncodedString())"
  }
}
