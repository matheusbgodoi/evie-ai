import CoreGraphics
import Foundation
import ImageIO
import Testing
import UniformTypeIdentifiers

@testable import EvieCore

@Suite("Screenshot encoding")
struct ScreenshotEncodingTests {
  /// A 3024×1964 picture — a 14-inch MacBook Pro's native capture — with a
  /// white field and a dark band, so the encoder has edges to keep.
  private static func retinaScreen(width: Int = 3_024, height: Int = 1_964) -> CGImage {
    let context = CGContext(
      data: nil,
      width: width,
      height: height,
      bitsPerComponent: 8,
      bytesPerRow: 0,
      space: CGColorSpace(name: CGColorSpace.sRGB)!,
      bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
    )!
    context.setFillColor(CGColor(red: 1, green: 1, blue: 1, alpha: 1))
    context.fill(CGRect(x: 0, y: 0, width: width, height: height))
    context.setFillColor(CGColor(red: 0.1, green: 0.1, blue: 0.4, alpha: 1))
    context.fill(CGRect(x: 0, y: height / 2, width: width, height: 40))
    return context.makeImage()!
  }

  private static func decoded(_ data: Data) -> (type: String?, width: Int, height: Int)? {
    guard let source = CGImageSourceCreateWithData(data as CFData, nil),
      let image = CGImageSourceCreateImageAtIndex(source, 0, nil)
    else {
      return nil
    }
    return (CGImageSourceGetType(source) as String?, image.width, image.height)
  }

  @Test("a 3024×1964 screen becomes a 1280-pixel JPEG with its aspect ratio")
  func retinaCaptureIsDownscaled() throws {
    let part = try ScreenshotEncoding.imagePart(
      from: Self.retinaScreen(),
      maxLongEdge: 1_280,
      origin: .screenshot
    )

    #expect(part.mimeType == "image/jpeg")
    #expect(part.origin == .screenshot)
    #expect(part.pixelSize == CGSize(width: 1_280, height: 831))
    let image = try #require(Self.decoded(part.data))
    #expect(image.type == UTType.jpeg.identifier)
    #expect(image.width == 1_280)
    #expect(image.height == 831)
    // 3024/1964 = 1.540; 1280/831 = 1.540.
    #expect(abs(Double(image.width) / Double(image.height) - 3_024.0 / 1_964.0) < 0.002)
  }

  @Test("a picture already smaller than the edge is not enlarged")
  func smallPictureKeepsItsSize() throws {
    let part = try ScreenshotEncoding.imagePart(
      from: Self.retinaScreen(width: 640, height: 400),
      maxLongEdge: 1_280,
      origin: .attachment
    )

    #expect(part.pixelSize == CGSize(width: 640, height: 400))
    #expect(Self.decoded(part.data)?.width == 640)
  }

  @Test("pasted image bytes are re-encoded as a downscaled JPEG")
  func pastedBytesAreReencoded() throws {
    let png = NSMutableData()
    let destination = try #require(
      CGImageDestinationCreateWithData(png, UTType.png.identifier as CFString, 1, nil)
    )
    CGImageDestinationAddImage(destination, Self.retinaScreen(), nil)
    #expect(CGImageDestinationFinalize(destination))

    let part = try ScreenshotEncoding.imagePart(
      fromImageData: png as Data,
      maxLongEdge: 1_024,
      origin: .attachment
    )

    #expect(part.mimeType == "image/jpeg")
    #expect(part.pixelSize == CGSize(width: 1_024, height: 665))
    #expect(Self.decoded(part.data)?.type == UTType.jpeg.identifier)
  }

  @Test("bytes that are not a picture are refused")
  func garbageIsRefused() {
    #expect(throws: ScreenshotEncoding.EncodingError.unreadableImage) {
      try ScreenshotEncoding.imagePart(
        fromImageData: Data("not a picture".utf8),
        maxLongEdge: 1_024,
        origin: .attachment
      )
    }
  }

  // MARK: - The presence-excluded diagnostic

  private static func field(markerSide: Int) -> CGImage {
    let context = CGContext(
      data: nil, width: 48, height: 48, bitsPerComponent: 8, bytesPerRow: 0,
      space: CGColorSpace(name: CGColorSpace.sRGB)!,
      bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
    )!
    context.setFillColor(CGColor(red: 0.85, green: 0.87, blue: 0.9, alpha: 1))
    context.fill(CGRect(x: 0, y: 0, width: 48, height: 48))
    if markerSide > 0 {
      context.setFillColor(CGColor(red: 1, green: 0, blue: 1, alpha: 1))
      context.fill(CGRect(x: 20, y: 20, width: markerSide, height: markerSide))
    }
    return context.makeImage()!
  }

  @Test("a 4×4 magenta marker is still found after the JPEG round trip")
  func markerSurvivesEncoding() throws {
    let part = try ScreenshotEncoding.imagePart(
      from: Self.field(markerSide: 4), maxLongEdge: 1_280, origin: .screenshot)

    #expect(try ScreenshotEncoding.magentaPixelCount(inJPEG: part.data) >= 4)
  }

  @Test("a capture without the marker has no magenta pixel")
  func noMarkerNoMagenta() throws {
    let part = try ScreenshotEncoding.imagePart(
      from: Self.field(markerSide: 0), maxLongEdge: 1_280, origin: .screenshot)

    #expect(try ScreenshotEncoding.magentaPixelCount(inJPEG: part.data) == 0)
  }
}
