import AppKit
import EvieCore
import Foundation
import ImageIO
import UniformTypeIdentifiers

/// Keeps the files that were attached, so a conversation can be read back whole.
///
/// A picture is re-encoded on the way in; a PDF is copied as it is.
///
/// The re-encoding is HEIC, which is the format the rest of this Mac already
/// uses and roughly half the size of JPEG at the same quality. A screenshot is
/// also scaled down first: it arrives at the display's full resolution because
/// that is what a screenshot is, and nothing about looking at it again needs
/// twelve megapixels. Measured with `--media-check` on this Mac: a full-screen
/// capture went from 1050 KB to 211 KB, and a small JPEG from 29 KB to 4 KB —
/// a fifth and a seventh of what arrived.
///
/// PDFs are copied byte for byte. They are already compressed, and re-encoding
/// one risks losing a font, a form field or a layer for a saving that is not
/// there.
///
/// Everything here belongs to the conversation that attached it. Deleting the
/// conversation deletes the files; `collectGarbage(keeping:)` removes anything
/// left behind by a crash, so the folder cannot grow without bound.
@MainActor
final class EvieMediaStore {
  /// The longest side a stored picture may have.
  ///
  /// 2048 is comfortably more than any window will show it at, and about a
  /// sixth of the pixels of a full-resolution screenshot from this display.
  static let maximumPixels: CGFloat = 2048
  /// HEIC quality. 0.72 is where the artefacts stop being findable by eye on
  /// text-heavy screenshots, which are the hardest case.
  static let quality: CGFloat = 0.72

  let directoryURL: URL

  init(directoryURL: URL = EvieMediaStore.defaultDirectoryURL) {
    self.directoryURL = directoryURL
  }

  static var defaultDirectoryURL: URL {
    EvieConfigurationLoader.defaultFileURL
      .deletingLastPathComponent()
      .appendingPathComponent("Media", isDirectory: true)
  }

  /// Copies a file in, compressing it when that is safe, and describes what was
  /// kept.
  func store(_ url: URL, originalName: String, messageID: UUID?) -> EvieStoredMedia? {
    guard prepareDirectory() else {
      return nil
    }
    let id = UUID()
    let isImage = Self.isImage(url)

    if isImage, let data = compressedImage(at: url) {
      let name = "\(id.uuidString).heic"
      guard (try? data.write(to: directoryURL.appendingPathComponent(name))) != nil else {
        return nil
      }
      return EvieStoredMedia(
        id: id,
        fileName: name,
        originalName: originalName,
        byteCount: data.count,
        isImage: true,
        messageID: messageID
      )
    }

    // Anything that could not be re-encoded — a PDF, or a picture in a format
    // ImageIO declined — is copied as it stands. Keeping the original is always
    // correct; compressing is the optimisation.
    let name = "\(id.uuidString).\(url.pathExtension.isEmpty ? "bin" : url.pathExtension)"
    let destination = directoryURL.appendingPathComponent(name)
    guard (try? FileManager.default.copyItem(at: url, to: destination)) != nil else {
      return nil
    }
    let attributes = try? FileManager.default.attributesOfItem(atPath: destination.path)
    let bytes = (attributes?[.size] as? Int) ?? 0
    return EvieStoredMedia(
      id: id,
      fileName: name,
      originalName: originalName,
      byteCount: bytes,
      isImage: isImage,
      messageID: messageID
    )
  }

  /// Where a stored file lives, refusing any name that tries to leave the folder.
  func url(for media: EvieStoredMedia) -> URL? {
    // The record came off disk, so its name is not to be trusted as a path.
    let name = (media.fileName as NSString).lastPathComponent
    guard !name.isEmpty, name != ".", name != ".." else {
      return nil
    }
    let url = directoryURL.appendingPathComponent(name)
    guard url.standardizedFileURL.path.hasPrefix(directoryURL.standardizedFileURL.path),
      FileManager.default.fileExists(atPath: url.path)
    else {
      return nil
    }
    return url
  }

  func delete(_ media: [EvieStoredMedia]) {
    for item in media {
      guard let url = url(for: item) else {
        continue
      }
      try? FileManager.default.removeItem(at: url)
    }
  }

  /// Removes every file no surviving conversation refers to.
  ///
  /// A crash between writing a file and saving the conversation that names it
  /// leaves an orphan, and an orphan nobody can see is exactly the kind of thing
  /// that quietly fills a disk.
  func collectGarbage(keeping media: [EvieStoredMedia]) {
    let kept = Set(media.map { ($0.fileName as NSString).lastPathComponent })
    let contents =
      (try? FileManager.default.contentsOfDirectory(atPath: directoryURL.path)) ?? []
    for name in contents where !name.hasPrefix(".") && !kept.contains(name) {
      try? FileManager.default.removeItem(at: directoryURL.appendingPathComponent(name))
    }
  }

  /// How much room the stored files take, for the sentence in settings.
  func totalBytes() -> Int {
    let contents =
      (try? FileManager.default.contentsOfDirectory(
        at: directoryURL,
        includingPropertiesForKeys: [.fileSizeKey]
      )) ?? []
    return contents.reduce(0) { total, url in
      total + ((try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0)
    }
  }

  // MARK: - Compressing

  private func compressedImage(at url: URL) -> Data? {
    guard let source = CGImageSourceCreateWithURL(url as CFURL, nil),
      let original = CGImageSourceCreateImageAtIndex(source, 0, nil)
    else {
      return nil
    }
    let image = Self.scaled(original) ?? original
    let output = NSMutableData()
    guard
      let destination = CGImageDestinationCreateWithData(
        output,
        UTType.heic.identifier as CFString,
        1,
        nil
      )
    else {
      return nil
    }
    CGImageDestinationAddImage(
      destination,
      image,
      [kCGImageDestinationLossyCompressionQuality: Self.quality] as CFDictionary
    )
    guard CGImageDestinationFinalize(destination) else {
      return nil
    }
    return output as Data
  }

  private static func scaled(_ image: CGImage) -> CGImage? {
    let longest = CGFloat(max(image.width, image.height))
    guard longest > maximumPixels else {
      return nil
    }
    let factor = maximumPixels / longest
    let width = Int((CGFloat(image.width) * factor).rounded())
    let height = Int((CGFloat(image.height) * factor).rounded())
    guard
      let context = CGContext(
        data: nil,
        width: width,
        height: height,
        bitsPerComponent: 8,
        bytesPerRow: 0,
        space: image.colorSpace ?? CGColorSpaceCreateDeviceRGB(),
        bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
      )
    else {
      return nil
    }
    context.interpolationQuality = .high
    context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
    return context.makeImage()
  }

  static func isImage(_ url: URL) -> Bool {
    ["png", "jpg", "jpeg", "heic", "heif", "gif", "tiff", "bmp", "webp"]
      .contains(url.pathExtension.lowercased())
  }

  @discardableResult
  private func prepareDirectory() -> Bool {
    (try? FileManager.default.createDirectory(
      at: directoryURL,
      withIntermediateDirectories: true,
      attributes: [.posixPermissions: 0o700]
    )) != nil
  }
}
