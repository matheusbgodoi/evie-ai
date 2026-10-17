import CoreGraphics
import Foundation
import ImageIO
import UniformTypeIdentifiers

/// Gives small Lens inputs enough visual patches to read text. This is a
/// request-local copy: source images, provenance and conversation stay intact.
public enum EvieLensImagePreparation {
  private static let minimumPixelArea: Double = 589_824
  private static let maximumLongEdge: Double = 4_096
  private static let maximumDecodedPixels: Double = 16_777_216
  private static let maximumImageBytes = 20 * 1_024 * 1_024

  public static func prepare(
    _ messages: [ChatMessage], configuration: EvieConfiguration
  ) throws -> [ChatMessage] {
    guard configuration.model == "mlx-community/LensVLM-9B-OptiQ-4bit",
      configuration.thinkingStyle == .topLevel,
      ["http", "https"].contains(configuration.endpoint.scheme ?? ""),
      ["127.0.0.1", "::1", "[::1]"].contains(configuration.endpoint.host ?? "")
    else { return messages }
    return try messages.map { message in
      guard let images = message.images, !images.isEmpty else { return message }
      try Task.checkCancellation()
      var prepared = message
      prepared.images = try images.map(prepareImage)
      return prepared
    }
  }

  private static func prepareImage(_ part: EvieImagePart) throws -> EvieImagePart {
    try Task.checkCancellation()
    guard part.data.count <= maximumImageBytes else { throw ModelClientError.requestTooLarge }
    guard
      let source = CGImageSourceCreateWithData(
        part.data as CFData, [kCGImageSourceShouldCache: false] as CFDictionary),
      let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any],
      let width = properties[kCGImagePropertyPixelWidth] as? Int,
      let height = properties[kCGImagePropertyPixelHeight] as? Int,
      width > 0, height > 0
    else {
      throw ModelClientError.requestEncoding("A imagem para o LensVLM não pôde ser lida.")
    }
    let area = Double(width) * Double(height)
    guard area <= maximumDecodedPixels else { throw ModelClientError.requestTooLarge }
    guard area < minimumPixelArea else { return part }
    guard let image = ScreenshotEncoding.orientedImage(from: source) else {
      throw ModelClientError.requestEncoding("A imagem para o LensVLM não pôde ser decodificada.")
    }
    let requiredScale = sqrt(minimumPixelArea / area)
    let edgeScale = maximumLongEdge / Double(max(image.width, image.height))
    let scale = min(requiredScale, edgeScale)
    guard scale > 1 else { return part }
    let rounding: FloatingPointRoundingRule =
      requiredScale <= edgeScale ? .up : .toNearestOrAwayFromZero
    let targetWidth = max(1, min(4_096, Int((Double(image.width) * scale).rounded(rounding))))
    let targetHeight = max(1, min(4_096, Int((Double(image.height) * scale).rounded(rounding))))
    guard let colorSpace = CGColorSpace(name: CGColorSpace.sRGB),
      let context = CGContext(
        data: nil, width: targetWidth, height: targetHeight, bitsPerComponent: 8, bytesPerRow: 0,
        space: colorSpace,
        bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)
    else { throw ModelClientError.requestEncoding("Não consegui ampliar a imagem para o LensVLM.") }
    context.interpolationQuality = .none
    context.draw(image, in: CGRect(x: 0, y: 0, width: targetWidth, height: targetHeight))
    guard let enlarged = context.makeImage() else {
      throw ModelClientError.requestEncoding("Não consegui ampliar a imagem para o LensVLM.")
    }
    try Task.checkCancellation()
    let bytes = NSMutableData()
    guard
      let destination = CGImageDestinationCreateWithData(
        bytes, UTType.png.identifier as CFString, 1, nil)
    else {
      throw ModelClientError.requestEncoding("Não consegui codificar a imagem para o LensVLM.")
    }
    CGImageDestinationAddImage(destination, enlarged, nil)
    guard CGImageDestinationFinalize(destination) else {
      throw ModelClientError.requestEncoding("Não consegui codificar a imagem para o LensVLM.")
    }
    guard bytes.length <= maximumImageBytes else { throw ModelClientError.requestTooLarge }
    return EvieImagePart(
      id: part.id, mimeType: "image/png", data: bytes as Data,
      pixelSize: CGSize(width: targetWidth, height: targetHeight), origin: part.origin)
  }
}
