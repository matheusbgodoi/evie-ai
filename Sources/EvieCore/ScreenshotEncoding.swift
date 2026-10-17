import CoreGraphics
import Foundation
import ImageIO
import UniformTypeIdentifiers

/// Turns a captured screen or a pasted picture into the JPEG a model is sent.
///
/// Everything happens in memory. A screen capture holds whatever was on the
/// screen — a bank page, a message, a password manager — so the bytes go from
/// the capture to the request and nowhere else: no temporary file, no cache,
/// no log. The result is an `EvieImagePart`, which `ChatMessage` never encodes.
///
/// Re-encoding also drops what a pasted photo carries besides its pixels:
/// EXIF, GPS position, the camera. Only the pixels are written.
public enum ScreenshotEncoding {
  /// The JPEG quality every capture is encoded at. At 0.8 small interface text
  /// keeps its edges and a 1280-pixel screen stays a few hundred kilobytes.
  public static let jpegQuality = 0.8

  public enum EncodingError: Error, Equatable, Sendable {
    /// The bytes are not a picture ImageIO can open, or it has no pixels.
    case unreadableImage
    /// ImageIO could not write the JPEG.
    case encodingFailed
  }

  /// `image`, downscaled so its longer edge is at most `maxLongEdge` (never
  /// enlarged), as an in-memory JPEG.
  public static func imagePart(
    from image: CGImage,
    maxLongEdge: Int,
    quality: Double = jpegQuality,
    origin: EvieImagePart.Origin
  ) throws -> EvieImagePart {
    let source = CGSize(width: image.width, height: image.height)
    let size = ScreenGeometry.downscaledSize(source, maxLongEdge: maxLongEdge)
    guard size != .zero else {
      throw EncodingError.unreadableImage
    }
    let scaled = size == source ? image : try redraw(image, at: size)
    return EvieImagePart(
      mimeType: "image/jpeg",
      data: try jpeg(scaled, quality: quality),
      pixelSize: size,
      origin: origin
    )
  }

  /// A picture given as file bytes — a pasted PNG, a dropped photo — read with
  /// its orientation applied, downscaled and re-encoded the same way.
  public static func imagePart(
    fromImageData data: Data,
    maxLongEdge: Int,
    quality: Double = jpegQuality,
    origin: EvieImagePart.Origin
  ) throws -> EvieImagePart {
    guard let source = CGImageSourceCreateWithData(data as CFData, nil),
      CGImageSourceGetCount(source) > 0,
      let image = orientedImage(from: source)
    else {
      throw EncodingError.unreadableImage
    }
    return try imagePart(from: image, maxLongEdge: maxLongEdge, quality: quality, origin: origin)
  }

  /// The first frame with its EXIF orientation applied, at full size. ImageIO
  /// applies the orientation only when it makes a thumbnail, so this asks for
  /// a "thumbnail" as large as the picture itself.
  static func orientedImage(from source: CGImageSource) -> CGImage? {
    guard
      let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any],
      let width = properties[kCGImagePropertyPixelWidth] as? Int,
      let height = properties[kCGImagePropertyPixelHeight] as? Int,
      width > 0, height > 0
    else {
      return nil
    }
    let options: [CFString: Any] = [
      kCGImageSourceCreateThumbnailFromImageAlways: true,
      kCGImageSourceCreateThumbnailWithTransform: true,
      kCGImageSourceThumbnailMaxPixelSize: max(width, height),
      kCGImageSourceShouldCacheImmediately: true,
    ]
    return CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary)
  }

  /// Redrawn with high-quality interpolation into an opaque sRGB bitmap: a
  /// screen has no transparency worth keeping, and JPEG would flatten it anyway.
  private static func redraw(_ image: CGImage, at size: CGSize) throws -> CGImage {
    guard
      let space = CGColorSpace(name: CGColorSpace.sRGB),
      let context = CGContext(
        data: nil,
        width: Int(size.width),
        height: Int(size.height),
        bitsPerComponent: 8,
        bytesPerRow: 0,
        space: space,
        bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue
      )
    else {
      throw EncodingError.encodingFailed
    }
    context.interpolationQuality = .high
    context.draw(image, in: CGRect(origin: .zero, size: size))
    guard let scaled = context.makeImage() else {
      throw EncodingError.encodingFailed
    }
    return scaled
  }

  /// How many pixels of an encoded capture are close to pure magenta
  /// (#FF00FF). The `presence-excluded` diagnostic draws a 4×4 magenta marker
  /// in one of Evie's own windows and expects none in a capture that leaves
  /// her application out. The tolerance absorbs JPEG's chroma smoothing; no
  /// interface colour Evie draws comes near it.
  public static func magentaPixelCount(inJPEG data: Data) throws -> Int {
    guard let source = CGImageSourceCreateWithData(data as CFData, nil),
      let image = CGImageSourceCreateImageAtIndex(source, 0, nil),
      let space = CGColorSpace(name: CGColorSpace.sRGB),
      let context = CGContext(
        data: nil,
        width: image.width,
        height: image.height,
        bitsPerComponent: 8,
        bytesPerRow: image.width * 4,
        space: space,
        bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue
      )
    else {
      throw EncodingError.unreadableImage
    }
    context.draw(image, in: CGRect(x: 0, y: 0, width: image.width, height: image.height))
    guard let pixels = context.data else {
      throw EncodingError.unreadableImage
    }
    let bytes = pixels.bindMemory(to: UInt8.self, capacity: image.width * image.height * 4)
    var count = 0
    for offset in stride(from: 0, to: image.width * image.height * 4, by: 4)
    where bytes[offset] > 190 && bytes[offset + 1] < 90 && bytes[offset + 2] > 190 {
      count += 1
    }
    return count
  }

  private static func jpeg(_ image: CGImage, quality: Double) throws -> Data {
    let data = NSMutableData()
    guard
      let destination = CGImageDestinationCreateWithData(
        data, UTType.jpeg.identifier as CFString, 1, nil
      )
    else {
      throw EncodingError.encodingFailed
    }
    CGImageDestinationAddImage(
      destination,
      image,
      [kCGImageDestinationLossyCompressionQuality: quality] as CFDictionary
    )
    guard CGImageDestinationFinalize(destination) else {
      throw EncodingError.encodingFailed
    }
    return data as Data
  }
}
